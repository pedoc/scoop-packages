#Requires -Version 7.2

Import-Module (Join-Path $PSScriptRoot 'manifest-policy.psm1') -ErrorAction Stop

$script:CHECKVER_SHA256 = '45ae0cc4d1a72074b480a0860c93e10e78c7876162cad97449ec099806fc0601'
$script:MAX_MANIFEST_BYTES = 1048576
$script:MAX_DIAGNOSTIC_CHARS = 4096

function Get-WorkerDiagnostic {
    param([AllowEmptyString()][string] $Text)
    $clean = $Text -replace '\x1b\[[0-9;]*m', ''
    foreach ($name in @('SCOOP_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
        $token = [Environment]::GetEnvironmentVariable($name)
        if ($token) { $clean = $clean.Replace($token, '[redacted]') }
    }
    $clean = $clean -replace '(?i)(Authorization\s*[:=]\s*)[^\r\n]+', '$1[redacted]'
    $clean = $clean -replace '(https?://[^\s?]+)\?[^\s]+', '$1?[redacted]'
    $clean = $clean -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', ''
    if ($clean.Length -gt $script:MAX_DIAGNOSTIC_CHARS) {
        return $clean.Substring(0, $script:MAX_DIAGNOSTIC_CHARS) + ' [truncated]'
    }
    return $clean.Trim()
}

function ConvertFrom-ScoopCheckverOutput {
    [CmdletBinding()]
    param(
        [string] $App, [string] $OldVersion,
        [AllowEmptyString()][string] $StandardOutput,
        [AllowEmptyString()][string] $StandardError = '',
        [int] $ExitCode = 0, [switch] $TimedOut, [switch] $OutputTruncated,
        [switch] $AllowUpdateLogs
    )
    # Scoop e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f, bin/checkver.ps1:422-438.
    $text = $StandardOutput -replace '\x1b\[[0-9;]*m', ''
    $prefix = [regex]::Escape($App) + ': '
    $versionPattern = '[A-Za-z0-9_][A-Za-z0-9_.+\-]{0,255}'
    $pattern = '^' + $prefix + '(?<version>' + $versionPattern + ')(?: \(scoop version is ' + [regex]::Escape($OldVersion) + '\) autoupdate available)?$'
    $lines = @($text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $positive = @($lines | Where-Object { $_ -cmatch $pattern })
    $version = if ($positive.Count -eq 1) { [regex]::Match($positive[0], $pattern).Groups['version'].Value } else { $null }
    $reason = 'source-evidence-missing'
    $status = 'failed'
    $diagnostic = Get-WorkerDiagnostic ($StandardOutput + "`n" + $StandardError)
    $networkError = $diagnostic -match "(?i)URL .+ is not valid|couldn't retrieve content|\bHTTP\s*(?:401|403|404|408|429|5\d\d)\b|\((?:401|403|404|408|429|5\d\d)\)|rate[ -]?limit|too many requests|timed?\s*out|unable to connect|could not resolve|no such host|connection.*(?:refused|closed)"
    if ($TimedOut) { $status = 'unavailable'; $reason = 'source-timeout' }
    elseif ($OutputTruncated) { $reason = 'checkver-output-truncated' }
    elseif ($networkError) { $status = 'unavailable'; $reason = 'source-unavailable' }
    elseif ($ExitCode -ne 0) { $reason = 'checkver-exit-nonzero' }
    elseif (-not [string]::IsNullOrWhiteSpace($StandardError)) { $reason = 'checkver-error-output' }
    elseif ($positive.Count -ne 1 -or -not $text.EndsWith("`n")) { $reason = 'source-evidence-missing' }
    elseif (($version -ceq $OldVersion) -ne ($positive[0] -ceq ($App + ': ' + $version))) { $reason = 'checkver-unexpected-output' }
    elseif (-not $AllowUpdateLogs -and $lines.Count -ne 1) { $reason = 'checkver-unexpected-output' }
    elseif ($AllowUpdateLogs -and @($lines | Where-Object { $_.StartsWith($App + ': ') }).Count -ne 1) { $reason = 'checkver-unexpected-output' }
    elseif ($diagnostic -match "(?i)couldn't (?:match|find)|could not (?:find hash|update)|\bERROR\b|\bException\b") { $reason = 'source-discovery-failed' }
    else { $status = 'resolved'; $reason = 'source-resolved' }
    return [pscustomobject]@{
        Status = $status; Reason = $reason; Version = $version
        SourceResolved = ($status -eq 'resolved'); Diagnostics = $diagnostic
    }
}

function Read-WorkerStreamState {
    param([IO.StreamReader] $Reader)
    $buffer = [char[]]::new(4096)
    return [pscustomobject]@{
        Reader = $Reader; Buffer = $buffer; Pending = $Reader.ReadAsync($buffer, 0, $buffer.Length)
        Text = ''; Complete = $false; Truncated = $false
    }
}

function Receive-WorkerStream {
    param($State, [int] $MaxChars)
    if ($State.Complete -or $State.Truncated -or -not $State.Pending.IsCompleted) { return $State }
    $count = $State.Pending.GetAwaiter().GetResult()
    $remaining = $MaxChars - $State.Text.Length
    $text = $State.Text + [string]::new($State.Buffer, 0, [Math]::Min($count, $remaining))
    $complete = $count -eq 0
    $truncated = $count -gt $remaining
    $pending = if (-not $complete -and -not $truncated) { $State.Reader.ReadAsync($State.Buffer, 0, $State.Buffer.Length) } else { $null }
    return [pscustomobject]@{
        Reader = $State.Reader; Buffer = $State.Buffer; Pending = $pending
        Text = $text; Complete = $complete; Truncated = $truncated
    }
}

function Invoke-WorkerProcessTermination {
    param([Diagnostics.Process] $Process)
    if (-not $Process.HasExited) { $Process.Kill($true) }
    if (-not $Process.WaitForExit(5000)) { throw 'The checkver process tree did not terminate.' }
}

function Wait-WorkerProcess {
    param([Diagnostics.Process] $Process, [int] $TimeoutSeconds, [int] $MaxOutputChars)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $streams = @(Read-WorkerStreamState $Process.StandardOutput; Read-WorkerStreamState $Process.StandardError)
    $timedOut = $false
    $truncated = $false
    while ($true) {
        $streams = @($streams | ForEach-Object { Receive-WorkerStream $_ $MaxOutputChars })
        $truncated = @($streams | Where-Object Truncated).Count -gt 0
        if ($truncated -or $clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $timedOut = -not $truncated
            Invoke-WorkerProcessTermination $Process
            break
        }
        if ($Process.HasExited -and @($streams | Where-Object { -not $_.Complete }).Count -eq 0) { break }
        [Threading.Thread]::Sleep(10)
    }
    # Drain already buffered diagnostics after terminating a timed-out process.
    for ($i = 0; $i -lt 50 -and @($streams | Where-Object { -not $_.Complete -and -not $_.Truncated }).Count -gt 0; $i++) {
        $streams = @($streams | ForEach-Object { Receive-WorkerStream $_ $MaxOutputChars })
        [Threading.Thread]::Sleep(10)
    }
    return [pscustomobject]@{
        ExitCode = $Process.ExitCode; StandardOutput = $streams[0].Text; StandardError = $streams[1].Text
        TimedOut = $timedOut; OutputTruncated = $truncated
    }
}

function Invoke-WorkerProcess {
    [CmdletBinding()]
    param(
        [string] $FilePath, [string[]] $ArgumentList, [string] $WorkingDirectory,
        [System.Collections.IDictionary] $Environment = @{},
        [ValidateRange(1, 3600)][int] $TimeoutSeconds = 600,
        [ValidateRange(1024, 1048576)][int] $MaxOutputChars = 65536
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $ArgumentList) { $info.ArgumentList.Add($argument) }
    foreach ($key in $Environment.Keys) { $info.Environment[$key] = [string] $Environment[$key] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Could not start the checkver process.' }
        return Wait-WorkerProcess $process $TimeoutSeconds $MaxOutputChars
    } finally {
        if ($started -and -not $process.HasExited) { Invoke-WorkerProcessTermination $process }
        $process.Dispose()
    }
}

function Initialize-WorkerOutputDirectory {
    param([string] $Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'OutputDirectory must be an absolute path to a new or empty directory.' }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or @(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) {
            throw 'OutputDirectory must be a new or empty ordinary directory; existing files will not be overwritten.'
        }
    } else { $null = New-Item -ItemType Directory -Path $Path -ErrorAction Stop }
}

function Get-WorkerFileHash {
    param([string] $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The manifest must be an ordinary file.' }
    if ($item.Length -gt $script:MAX_MANIFEST_BYTES) { throw 'The manifest exceeds the worker size limit.' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-WorkerResult {
    param(
        [System.Collections.IDictionary] $Context, [string] $Status, [string] $Reason,
        [bool] $SourceResolved = $false, [AllowNull()][string] $NewVersion,
        [AllowEmptyString()][string] $Diagnostics = '', [AllowNull()][string] $CandidateSha256
    )
    $diagnostic = Get-WorkerDiagnostic $Diagnostics
    $result = [ordered]@{
        schema = 1; app = $Context.app; status = $Status
        reason = $(if ($diagnostic) { $Reason + ': ' + $diagnostic } else { $Reason })
        baseSha = $Context.baseSha; runId = $Context.runId; runAttempt = $Context.runAttempt
        originalSha256 = $Context.originalSha256; oldVersion = $Context.oldVersion
        newVersion = $(if ($NewVersion) { $NewVersion } else { $null }); sourceResolved = $SourceResolved
    }
    if ($Status -eq 'updated') { $result.candidateSha256 = $CandidateSha256 }
    return $result
}

function Get-WorkerAutoupdateProblem {
    param([System.Collections.IDictionary] $Manifest)
    $architectures = if ($Manifest.architecture) { @($Manifest.architecture.Keys) } else { @('root') }
    foreach ($architecture in $architectures) {
        $scope = if ($architecture -eq 'root') { $Manifest } else { $Manifest.architecture[$architecture] }
        $oldUrls = if ($scope.url) { @($scope.url) } else { @($Manifest.url) }
        $updateScope = if ($architecture -ne 'root' -and $Manifest.autoupdate.architecture) { $Manifest.autoupdate.architecture[$architecture] } else { $null }
        $urls = if ($updateScope -and $updateScope.url) { @($updateScope.url) } else { @($Manifest.autoupdate.url) }
        if (-not $urls.Count -or $urls.Count -ne $oldUrls.Count) { return 'invalid-autoupdate-rule' }
        foreach ($url in $urls) {
            if ($url -isnot [string] -or [string]::IsNullOrWhiteSpace($url)) { return 'invalid-autoupdate-rule' }
        }
    }
    return $null
}

function Get-WorkerRuleProblem {
    param([System.Collections.IDictionary] $Manifest)
    $state = Get-ManifestMaintenanceState -Manifest $Manifest
    if ($state -ne 'configured') { return [string] $state }
    $updateProblem = Get-WorkerAutoupdateProblem $Manifest
    if ($updateProblem) { return $updateProblem }
    $check = $Manifest.checkver
    if ($check -is [System.Collections.IDictionary] -and $check.Contains('script')) { return 'executable-checkver-script' }
    $templates = $Manifest.autoupdate | ConvertTo-Json -Depth 100 -Compress
    $customMatches = [regex]::Matches($templates, '\$match[A-Za-z0-9_]+') | ForEach-Object Value
    if (@($customMatches | Where-Object { $_ -cnotin @('$matchHead', '$matchTail') }).Count -gt 0) { return 'custom-source-captures' }
    if ($check -is [System.Collections.IDictionary]) {
        $hasSelector = @('github', 'sourceforge', 're', 'regex', 'jp', 'jsonpath', 'xpath') | Where-Object { $check[$_] }
        if (-not $hasSelector) { return 'invalid-source-rule' }
    } elseif ([string]::IsNullOrWhiteSpace([string] $check)) { return 'invalid-source-rule' }
    $source = if ($check -is [System.Collections.IDictionary] -and $check.github) { $check.github }
    elseif ($check -is [System.Collections.IDictionary] -and $check.url) { $check.url } else { $Manifest.homepage }
    $uri = $null
    if (-not [Uri]::TryCreate([string] $source, [UriKind]::Absolute, [ref] $uri) -or $uri.Scheme -notin @('https', 'http') -or $uri.UserInfo) { return 'invalid-source-rule' }
    $isGithub = $check -eq 'github' -or ($check -is [System.Collections.IDictionary] -and $check.github)
    if ($isGithub -and $source -notmatch '^https://((www\.)?github\.com/[\w.-]+/[\w.-]+/?|api\.github\.com/repos/[\w.-]+/[\w.-]+/.+)$') { return 'invalid-source-rule' }
    return $null
}

function Read-WorkerManifestInput {
    param([System.Collections.IDictionary] $Context, [string] $ManifestPath, [string] $ScoopHome)
    $hash = $null
    $manifest = $null
    try {
        $null = Assert-SafeAppName -App $Context.app
        if (-not [IO.Path]::IsPathFullyQualified($ManifestPath)) { throw 'ManifestPath must be absolute.' }
        if ([IO.Path]::GetFileNameWithoutExtension($ManifestPath) -cne $Context.app -or [IO.Path]::GetExtension($ManifestPath) -cne '.json') { throw 'ManifestPath must name the selected app JSON file.' }
        $hash = Get-WorkerFileHash $ManifestPath
        $manifest = Read-StrictJsonFile -Path $ManifestPath
        $null = Assert-ManifestSchema -Path $ManifestPath -ScoopHome $ScoopHome
        $problem = Get-WorkerRuleProblem $manifest
        $status = if ($problem) { 'manual' } else { 'configured' }
        $reason = if ($problem) { $problem } else { 'configured' }
        $diagnostic = ''
    } catch {
        $status = 'failed'; $reason = 'invalid-manifest'; $diagnostic = $_.Exception.Message
    }
    $updatedContext = [ordered]@{
        app = $Context.app; baseSha = $Context.baseSha; runId = $Context.runId; runAttempt = $Context.runAttempt
        originalSha256 = $hash; oldVersion = $(if ($manifest -and $manifest.version -is [string]) { $manifest.version } else { $null })
    }
    return [pscustomobject]@{ Context = $updatedContext; Manifest = $manifest; Status = $status; Reason = $reason; Diagnostics = $diagnostic }
}

function Assert-WorkerScoopContract {
    param([string] $ScoopHome)
    if (-not [IO.Path]::IsPathFullyQualified($ScoopHome)) { throw 'ScoopHome must be an absolute trusted path.' }
    $source = [IO.File]::ReadAllText((Join-Path $ScoopHome 'bin/checkver.ps1')).Replace("`r`n", "`n")
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source))).ToLowerInvariant()
    if ($hash -cne $script:CHECKVER_SHA256) { throw 'Unsupported Scoop checkver revision; the pinned output contract changed.' }
}

function Initialize-WorkerWorkspace {
    param([string] $ScoopHome, [string] $ManifestPath, [string] $App)
    Assert-WorkerScoopContract $ScoopHome
    $checkver = Join-Path $ScoopHome 'bin/checkver.ps1'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('scoop-update-' + [guid]::NewGuid().ToString('N'))
    $paths = [ordered]@{ Root = $root; Code = (Join-Path $root 'trusted-code'); Manifests = (Join-Path $root 'manifests'); Cache = (Join-Path $root 'downloads'); Config = (Join-Path $root 'config'); Temp = (Join-Path $root 'temp'); Scoop = (Join-Path $root 'scoop-root'); Global = (Join-Path $root 'scoop-global') }
    try {
        foreach ($path in $paths.Values) { $null = New-Item -ItemType Directory -Path $path -ErrorAction Stop }
        foreach ($path in @('bin', 'lib', 'supporting/validator/bin')) { $null = New-Item -ItemType Directory -Path (Join-Path $paths.Code $path) -ErrorAction Stop }
        # Copy only trusted code, before downloading data; the new path cannot select a portable config.
        Copy-Item -LiteralPath $checkver -Destination (Join-Path $paths.Code 'bin/checkver.ps1') -ErrorAction Stop
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'update-worker-extract-dir.ps1') -Destination (Join-Path $paths.Code 'bin/update-worker-extract-dir.ps1') -ErrorAction Stop
        Get-ChildItem -LiteralPath (Join-Path $ScoopHome 'lib') -Filter '*.ps1' -File | Copy-Item -Destination (Join-Path $paths.Code 'lib') -ErrorAction Stop
        Copy-Item -LiteralPath (Join-Path $ScoopHome 'supporting/validator/bin/Newtonsoft.Json.dll') -Destination (Join-Path $paths.Code 'supporting/validator/bin/Newtonsoft.Json.dll') -ErrorAction Stop
        $null = New-Item -ItemType Directory -Path (Join-Path $paths.Config 'scoop') -ErrorAction Stop
        [IO.File]::WriteAllText((Join-Path $paths.Config 'scoop/config.json'), '{"aria2-enabled":false}')
        Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $paths.Manifests ($App + '.json')) -ErrorAction Stop
        return [pscustomobject] $paths
    } catch {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
        throw
    }
}

function Get-WorkerProcessEnvironment {
    param($Workspace)
    return @{
        SCOOP = $Workspace.Scoop; SCOOP_GLOBAL = $Workspace.Global; SCOOP_CACHE = $Workspace.Cache
        XDG_CONFIG_HOME = $Workspace.Config; TEMP = $Workspace.Temp; TMP = $Workspace.Temp
        PSModulePath = (Join-Path $PSHOME 'Modules'); NO_COLOR = '1'; TERM = 'dumb'
    }
}

function Invoke-ScoopCheckver {
    param([string] $App, [string] $Directory, $Workspace, [int] $TimeoutSeconds, [string] $Version)
    $executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $Workspace.Code 'bin/checkver.ps1'), '-App', $App, '-Dir', $Directory, '-ThrowError')
    if ($Version) { $arguments += @('-Update', '-Version', $Version) }
    return Invoke-WorkerProcess -FilePath $executable -ArgumentList $arguments -WorkingDirectory $Workspace.Code -Environment (Get-WorkerProcessEnvironment $Workspace) -TimeoutSeconds $TimeoutSeconds
}

function Complete-WorkerExtractionTemplate {
    param([System.Collections.IDictionary] $Before, [string] $CandidatePath, $Workspace)
    $basePath = Join-Path $Workspace.Manifests ([IO.Path]::GetFileNameWithoutExtension($CandidatePath) + '.base.json')
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Before | ConvertTo-Json -Depth 100 -Compress))
    Write-WorkerNewFile $basePath $bytes
    $executable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $Workspace.Code 'bin/update-worker-extract-dir.ps1'), '-BaseManifestPath', $basePath, '-CandidatePath', $CandidatePath, '-ScoopHome', $Workspace.Code)
    $run = Invoke-WorkerProcess -FilePath $executable -ArgumentList $arguments -WorkingDirectory $Workspace.Code -Environment (Get-WorkerProcessEnvironment $Workspace) -TimeoutSeconds 30
    if ($run.ExitCode -ne 0 -or $run.TimedOut -or $run.OutputTruncated -or $run.StandardOutput -or $run.StandardError) {
        throw ('Extraction template materialization failed: ' + (Get-WorkerDiagnostic ($run.StandardOutput + "`n" + $run.StandardError)))
    }
}

function Compare-WorkerVersion {
    param([string] $OldVersion, [string] $NewVersion, [string] $ScoopHome)
    . (Join-Path $ScoopHome 'lib/versions.ps1')
    return Compare-Version -ReferenceVersion $OldVersion -DifferenceVersion $NewVersion -ErrorAction Stop
}

function Get-WorkerOutcome {
    param([System.Collections.IDictionary] $Result, [AllowNull()][byte[]] $CandidateBytes)
    return [pscustomobject]@{ Result = $Result; CandidateBytes = $CandidateBytes }
}

function Get-WorkerCandidateOutcome {
    param($InputState, $Workspace, [string] $ScoopHome, [string] $NewVersion, $Run)
    $context = $InputState.Context
    $evidence = ConvertFrom-ScoopCheckverOutput -App $context.app -OldVersion $context.oldVersion -AllowUpdateLogs -StandardOutput $Run.StandardOutput -StandardError $Run.StandardError -ExitCode $Run.ExitCode -TimedOut:$Run.TimedOut -OutputTruncated:$Run.OutputTruncated
    if ($evidence.Status -ne 'resolved') { return Get-WorkerOutcome (Get-WorkerResult $context $evidence.Status $evidence.Reason -SourceResolved $true -NewVersion $NewVersion -Diagnostics $evidence.Diagnostics) }
    try {
        $path = Join-Path $Workspace.Manifests ($context.app + '.json')
        $null = Get-WorkerFileHash $path
        $candidate = Read-StrictJsonFile -Path $path
        if ($candidate.version -cne $NewVersion -or $evidence.Version -cne $NewVersion) { throw 'Candidate version does not match the proven source version.' }
        Complete-WorkerExtractionTemplate -Before $InputState.Manifest -CandidatePath $path -Workspace $Workspace
        $candidate = Read-StrictJsonFile -Path $path
        $null = Assert-ManifestSchema -Path $path -ScoopHome $ScoopHome
        $decision = Get-ManifestUpdateDecision -Before $InputState.Manifest -After $candidate -ScoopHome $ScoopHome
        if (-not $decision.Allowed) {
            return Get-WorkerOutcome (Get-WorkerResult $context 'failed' 'candidate-policy-rejected' -SourceResolved $true -NewVersion $NewVersion -Diagnostics $decision.Reason)
        }
        $hash = Get-WorkerFileHash $path
        $bytes = [IO.File]::ReadAllBytes($path)
        return Get-WorkerOutcome (Get-WorkerResult $context 'updated' 'upgrade-generated' -SourceResolved $true -NewVersion $NewVersion -CandidateSha256 $hash) $bytes
    } catch {
        return Get-WorkerOutcome (Get-WorkerResult $context 'failed' 'candidate-invalid' -SourceResolved $true -NewVersion $NewVersion -Diagnostics $_.Exception.Message)
    }
}

function Invoke-WorkerDiscovery {
    param($InputState, $Workspace, [string] $ScoopHome, [int] $TimeoutSeconds)
    $context = $InputState.Context
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-ScoopCheckver -App $context.app -Directory $Workspace.Manifests -Workspace $Workspace -TimeoutSeconds $TimeoutSeconds
    $evidence = ConvertFrom-ScoopCheckverOutput -App $context.app -OldVersion $context.oldVersion -StandardOutput $run.StandardOutput -StandardError $run.StandardError -ExitCode $run.ExitCode -TimedOut:$run.TimedOut -OutputTruncated:$run.OutputTruncated
    if ($evidence.Status -ne 'resolved') { return Get-WorkerOutcome (Get-WorkerResult $context $evidence.Status $evidence.Reason -Diagnostics $evidence.Diagnostics) }
    $path = Join-Path $Workspace.Manifests ($context.app + '.json')
    if ((Get-WorkerFileHash $path) -cne $context.originalSha256) { return Get-WorkerOutcome (Get-WorkerResult $context 'failed' 'discovery-modified-manifest' -SourceResolved $true -NewVersion $evidence.Version) }
    if ($evidence.Version -ceq $context.oldVersion) { return Get-WorkerOutcome (Get-WorkerResult $context 'current' 'source-version-equal' -SourceResolved $true -NewVersion $evidence.Version) }
    if ((Compare-WorkerVersion $context.oldVersion $evidence.Version $ScoopHome) -le 0) { return Get-WorkerOutcome (Get-WorkerResult $context 'failed' 'version-not-newer' -SourceResolved $true -NewVersion $evidence.Version) }
    $remaining = [int] [Math]::Floor($TimeoutSeconds - $clock.Elapsed.TotalSeconds)
    if ($remaining -lt 1) { return Get-WorkerOutcome (Get-WorkerResult $context 'unavailable' 'source-timeout' -SourceResolved $true -NewVersion $evidence.Version) }
    # Validate the discovered token before Scoop can interpolate it into cache paths or templates.
    try {
        $update = Invoke-ScoopCheckver -App $context.app -Directory $Workspace.Manifests -Workspace $Workspace -TimeoutSeconds $remaining -Version $evidence.Version
        return Get-WorkerCandidateOutcome $InputState $Workspace $ScoopHome $evidence.Version $update
    } catch {
        return Get-WorkerOutcome (Get-WorkerResult $context 'failed' 'update-invocation-failed' -SourceResolved $true -NewVersion $evidence.Version -Diagnostics $_.Exception.Message)
    }
}

function Write-WorkerNewFile {
    param([string] $Path, [byte[]] $Bytes)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
}

function Write-WorkerArtifact {
    param([string] $OutputDirectory, $Outcome)
    $candidatePath = Join-Path $OutputDirectory 'candidate.json'
    try {
        if ($Outcome.Result.status -eq 'updated') {
            Write-WorkerNewFile $candidatePath $Outcome.CandidateBytes
            if ((Get-WorkerFileHash $candidatePath) -cne $Outcome.Result.candidateSha256) { throw 'Candidate artifact hash changed while writing.' }
        }
        $json = ($Outcome.Result | ConvertTo-Json -Depth 20) + "`n"
        Write-WorkerNewFile (Join-Path $OutputDirectory 'result.json') ([Text.UTF8Encoding]::new($false).GetBytes($json))
    } catch {
        if (Test-Path -LiteralPath $candidatePath) { Remove-Item -LiteralPath $candidatePath -Force -ErrorAction Stop }
        throw
    }
}

function Invoke-ManifestUpdateWorker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $App,
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $OutputDirectory,
        [Parameter(Mandatory)][string] $ScoopHome,
        [Parameter(Mandatory)][string] $BaseSha,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $RunAttempt,
        [int] $TimeoutSeconds = 600
    )
    Initialize-WorkerOutputDirectory $OutputDirectory
    $context = [ordered]@{ app = $App; baseSha = $BaseSha; runId = $RunId; runAttempt = $RunAttempt; originalSha256 = $null; oldVersion = $null }
    $workspace = $null
    $outcome = Get-WorkerOutcome (Get-WorkerResult $context 'failed' 'worker-failed')
    try {
        if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 3600) { throw 'TimeoutSeconds must be between 1 and 3600.' }
        $inputState = Read-WorkerManifestInput $context $ManifestPath $ScoopHome
        $context = $inputState.Context
        if ($inputState.Status -ne 'configured') { $outcome = Get-WorkerOutcome (Get-WorkerResult $context $inputState.Status $inputState.Reason -Diagnostics $inputState.Diagnostics) }
        else {
            $workspace = Initialize-WorkerWorkspace $ScoopHome $ManifestPath $App
            $outcome = Invoke-WorkerDiscovery $inputState $workspace $ScoopHome $TimeoutSeconds
            if ((Get-WorkerFileHash $ManifestPath) -cne $context.originalSha256) { $outcome = Get-WorkerOutcome (Get-WorkerResult $context 'failed' 'original-manifest-changed' -SourceResolved $outcome.Result.sourceResolved -NewVersion $outcome.Result.newVersion -Diagnostics 'The original changed during the check; regenerate from a fresh base.') }
        }
    } catch {
        $outcome = Get-WorkerOutcome (Get-WorkerResult $context 'failed' 'worker-failed' -Diagnostics $_.Exception.Message)
    } finally {
        if ($workspace) {
            try { Remove-Item -LiteralPath $workspace.Root -Recurse -Force -ErrorAction Stop }
            catch { $outcome = Get-WorkerOutcome (Get-WorkerResult $context 'failed' 'workspace-cleanup-failed' -SourceResolved $outcome.Result.sourceResolved -NewVersion $outcome.Result.newVersion -Diagnostics $_.Exception.Message) }
        }
    }
    Write-WorkerArtifact $OutputDirectory $outcome
    return $outcome.Result
}

Export-ModuleMember -Function ConvertFrom-ScoopCheckverOutput, Invoke-WorkerProcess, Invoke-ManifestUpdateWorker
