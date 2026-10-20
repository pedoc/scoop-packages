Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'manifest-policy.psm1') -Scope Local

function Get-GithubNativeStreamState {
    param([IO.StreamReader]$Reader, [int]$Limit)
    $buffer = [char[]]::new(4096)
    return @{ Reader = $Reader; Buffer = $buffer; Pending = $Reader.ReadAsync($buffer, 0, $buffer.Length); Text = ''; Complete = $false; Limit = $Limit }
}

function Receive-GithubNativeStream {
    param([System.Collections.IDictionary]$State)
    if ($State.Complete -or -not $State.Pending.IsCompleted) { return $State }
    $count = $State.Pending.GetAwaiter().GetResult()
    if ($State.Text.Length + $count -gt $State.Limit) { throw 'Native GitHub CLI output exceeds the bounded response limit.' }
    $text = $State.Text + [string]::new($State.Buffer, 0, $count)
    $pending = if ($count -gt 0) { $State.Reader.ReadAsync($State.Buffer, 0, $State.Buffer.Length) } else { $null }
    return @{ Reader = $State.Reader; Buffer = $State.Buffer; Pending = $pending; Text = $text; Complete = ($count -eq 0); Limit = $State.Limit }
}

function Wait-GithubNativeOutput {
    param([Diagnostics.Process]$Process, [System.Collections.IDictionary]$StandardOutput, [System.Collections.IDictionary]$StandardError)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($true) {
            $StandardOutput = Receive-GithubNativeStream -State $StandardOutput
            $StandardError = Receive-GithubNativeStream -State $StandardError
            if ($Process.HasExited -and $StandardOutput.Complete -and $StandardError.Complete) { break }
            if ($clock.ElapsedMilliseconds -gt 120000) { throw 'GitHub CLI timed out.' }
            Start-Sleep -Milliseconds 10
        }
        return @{ Output = $StandardOutput.Text; Error = $StandardError.Text }
    } catch {
        if (-not $Process.HasExited) { $Process.Kill($true); $null = $Process.WaitForExit(5000) }
        throw
    }
}

function Invoke-GithubNative {
    <#
    .SYNOPSIS
    Runs a bounded native CLI invocation with literal argv and checked exit status.
    .DESCRIPTION
    gh uses only the supplied GITHUB_TOKEN and github.com, never cached credentials or
    an alternative token. Error response bodies are deliberately omitted from logs.
    Executable is injectable for offline tests; production callers use the default gh.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$InputText, [string]$Executable = 'gh')
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    if ($Executable -ceq 'gh') {
        if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { throw 'GITHUB_TOKEN is required; cached credentials and alternative tokens are not used.' }
        $start.Environment['GH_TOKEN'] = $env:GITHUB_TOKEN
        $start.Environment['GH_HOST'] = 'github.com'
        $start.Environment.Remove('GH_ENTERPRISE_TOKEN') | Out-Null
        $start.Environment.Remove('GITHUB_ENTERPRISE_TOKEN') | Out-Null
    }
    $start.WorkingDirectory = $PSScriptRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start GitHub CLI.' }
        $stdout = Get-GithubNativeStreamState -Reader $process.StandardOutput -Limit 16777216
        $stderr = Get-GithubNativeStreamState -Reader $process.StandardError -Limit 65536
        if ($null -ne $InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        $output = Wait-GithubNativeOutput -Process $process -StandardOutput $stdout -StandardError $stderr
        $text = $output.Output
        $errorText = $output.Error
        if ($process.ExitCode -ne 0) {
            # Do not echo CLI output: API responses can contain private information or credentials.
            $exception = [InvalidOperationException]::new("GitHub CLI failed with exit code $($process.ExitCode).")
            if ($errorText -match '\bHTTP 404\b') { $exception.Data['HttpStatus'] = 404 }
            throw $exception
        }
        if ($text.Length -gt 16777216) { throw 'GitHub response exceeds the bounded response size.' }
        return $text
    } finally { $process.Dispose() }
}

function Invoke-GithubApi {
    <#
    .SYNOPSIS
    Reads GitHub JSON or performs a narrowly permitted, independently gated write.
    .DESCRIPTION
    Mutation support is limited to head validation status and explicit SHA-bound merge.
    JSON request bodies are sent on stdin, not interpolated into shell commands.
    #>
    param(
        [ValidateSet('GET', 'POST', 'PUT')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Endpoint,
        [System.Collections.IDictionary]$Body,
        [string]$Enabled,
        [object]$Publish = $false
    )
    if ($Endpoint -notmatch '^repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/') { throw 'Invalid GitHub API endpoint.' }
    $arguments = @('api', '--method', $Method, '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2022-11-28', $Endpoint)
    $inputText = $null
    if ($Method -ne 'GET') {
        if (-not (Test-PublishAuthorization -Enabled $Enabled -Publish $Publish)) { throw 'GitHub write is not authorized.' }
        $statusWrite = $Method -ceq 'POST' -and $Endpoint -cmatch '^repos/[^/]+/[^/]+/statuses/[a-f0-9]{40}$'
        $mergeWrite = $Method -ceq 'PUT' -and $Endpoint -cmatch '^repos/[^/]+/[^/]+/pulls/[1-9][0-9]*/merge$'
        if (-not $statusWrite -and -not $mergeWrite) { throw 'Only head validation status and SHA-bound PR merge writes are supported.' }
        $arguments += @('--input', '-')
        $inputText = ConvertTo-Json -InputObject $Body -Depth 30 -Compress
    }
    $text = Invoke-GithubNative -Arguments $arguments -InputText $inputText
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'GitHub API returned empty JSON.' }
    return ConvertFrom-Json -InputObject $text -AsHashtable -Depth 60
}

function Invoke-GithubWorkflowDispatch {
    param([string]$Repository, [string]$BaseBranch, [int]$PrNumber, [string]$ExpectedHead, [string]$App, [string]$Enabled, [object]$Publish)
    if (-not (Test-PublishAuthorization -Enabled $Enabled -Publish $Publish)) { throw 'Workflow dispatch is not authorized.' }
    $arguments = @('workflow', 'run', 'validate-update.yml', '--repo', $Repository, '--ref', $BaseBranch,
        '-f', "pr_number=$PrNumber", '-f', "expected_head=$ExpectedHead", '-f', "app=$App", '-f', 'publish=true')
    $null = Invoke-GithubNative -Arguments $arguments
}

function Get-GithubPull {
    param([string]$Repository, [int]$PrNumber)
    return Invoke-GithubApi -Endpoint "repos/$Repository/pulls/$PrNumber"
}

function Get-GithubTree {
    param([string]$Repository, [string]$Sha)
    if ($Sha -notmatch '^[a-fA-F0-9]{40}$') { throw 'Invalid Git object ID.' }
    $commit = Invoke-GithubApi -Endpoint "repos/$Repository/git/commits/$Sha"
    $tree = Invoke-GithubApi -Endpoint "repos/$Repository/git/trees/$($commit.tree.sha)?recursive=1"
    if ($tree.truncated -isnot [bool] -or $tree.truncated) { throw 'Git tree is truncated or invalid.' }
    $entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $tree.tree) {
        if ($entry.type -eq 'tree') { continue }
        if ($entries.ContainsKey($entry.path)) { throw 'Git tree contains duplicate paths.' }
        $entries.Add($entry.path, $entry)
    }
    return ,$entries
}

function Get-GithubBlobData {
    param([string]$Repository, [string]$BlobSha)
    if ($BlobSha -notmatch '^[a-fA-F0-9]{40}$') { throw 'Invalid Git blob ID.' }
    $blob = Invoke-GithubApi -Endpoint "repos/$Repository/git/blobs/$BlobSha"
    if ($blob.encoding -cne 'base64' -or $blob.size -le 0 -or $blob.size -gt 2097152) { throw 'Invalid or oversized manifest blob.' }
    $bytes = [Convert]::FromBase64String($blob.content)
    if ($bytes.Length -ne $blob.size) { throw 'Git blob size does not match its content.' }
    $null = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    return ,$bytes
}

function Test-GithubPolicyPath {
    param([string]$Path)
    return $Path -cmatch '^bin/[^/]+\.ps(m)?1$' -or $Path -cmatch '^\.github/workflows/[^/]+\.ya?ml$' -or
        $Path -cmatch '^\.github/actions/.+'
}

function Get-GithubPolicyPathList {
    param([System.Collections.IDictionary]$Tree)
    $inputs = [string[]]@($Tree.Keys | Where-Object { Test-GithubPolicyPath -Path $_ })
    [Array]::Sort($inputs, [StringComparer]::Ordinal)
    if ($inputs -cnotcontains 'bin/manifest-policy.psm1' -or $inputs -cnotcontains 'bin/github-update.ps1') { throw 'Trusted policy inputs are missing from the base tree.' }
    return $inputs
}

function Assert-GithubPolicyCheckout {
    param([string]$Repository, [string]$BaseSha, [string]$RepositoryDirectory)
    $tree = Get-GithubTree -Repository $Repository -Sha $BaseSha
    $inputs = @(Get-GithubPolicyPathList -Tree $tree)
    $root = [IO.Path]::GetFullPath($RepositoryDirectory)
    $localInputs = @(foreach ($relative in @('bin', '.github/workflows', '.github/actions')) {
        $directory = Join-Path $root $relative
        if (-not [IO.Directory]::Exists($directory)) { continue }
        $options = [IO.EnumerationOptions]::new()
        $options.RecurseSubdirectories = $relative -ceq '.github/actions'
        $options.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
        foreach ($path in [IO.Directory]::EnumerateFiles($directory, '*', $options)) {
            $name = [IO.Path]::GetRelativePath($root, $path).Replace('\', '/')
            if (Test-GithubPolicyPath -Path $name) { $name }
        }
    })
    if (@(Compare-Object -ReferenceObject $inputs -DifferenceObject $localInputs -CaseSensitive).Count -ne 0) { throw 'Trusted checkout policy file set differs from the current default branch.' }
    foreach ($path in $inputs) {
        $file = Get-Item -LiteralPath (Join-Path $root $path)
        for ($item = $file; $null -ne $item; $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Trusted checkout policy path is a reparse point.' }
        }
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $header = [Text.Encoding]::UTF8.GetBytes("blob $($bytes.Length)`0")
        $blobSha = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($header + $bytes))).ToLowerInvariant()
        if ($tree[$path].type -cne 'blob' -or $tree[$path].mode -cne '100644' -or $blobSha -cne $tree[$path].sha) { throw 'Trusted checkout policy content differs from the current default branch.' }
    }
}

function Get-GithubPolicyDigest {
    param([System.Collections.IDictionary]$Tree, [string]$ScoopHome)
    $inputs = @(Get-GithubPolicyPathList -Tree $Tree)
    $records = foreach ($path in $inputs) {
        $entry = $Tree[$path]
        if ($entry.type -cne 'blob' -or $entry.mode -cne '100644') { throw 'Policy input is not a regular file.' }
        "$path`0$($entry.sha)"
    }
    $scoopRecords = foreach ($path in @('schema.json', 'lib/versions.ps1', 'lib/autoupdate.ps1',
            'supporting/validator/bin/validator.exe', 'supporting/validator/bin/Scoop.Validator.dll',
            'supporting/validator/bin/Newtonsoft.Json.dll', 'supporting/validator/bin/Newtonsoft.Json.Schema.dll')) {
        $file = Get-Item -LiteralPath (Join-Path $ScoopHome $path)
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Scoop policy input is a reparse point.' }
        "$path`0$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes((@($records) + @($scoopRecords)) -join "`n")
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Assert-GithubManifestEntry {
    param([object]$Entry)
    if ($Entry.type -cne 'blob' -or $Entry.mode -cne '100644') { throw 'Manifest must be an existing regular file.' }
    if (($Entry.size -isnot [int] -and $Entry.size -isnot [long]) -or $Entry.size -le 0 -or $Entry.size -gt 2097152) { throw 'Manifest blob exceeds the bounded data size limit.' }
}

function Get-GithubBaseState {
    param([string]$Repository, [string]$BaseBranch, [string]$App, [string]$ScoopHome, [string]$CommitSha)
    $sha = $CommitSha
    if (-not $sha) {
        $reference = Invoke-GithubApi -Endpoint "repos/$Repository/git/ref/heads/$BaseBranch"
        $sha = $reference.object.sha
    }
    $tree = Get-GithubTree -Repository $Repository -Sha $sha
    $path = "bucket/$App.json"
    if (-not $tree.ContainsKey($path) -or $tree[$path].type -cne 'blob' -or $tree[$path].mode -cne '100644') { throw 'Base manifest must be an existing regular file.' }
    Assert-GithubManifestEntry -Entry $tree[$path]
    $bytes = Get-GithubBlobData -Repository $Repository -BlobSha $tree[$path].sha
    return @{
        Sha = $sha; Bytes = $bytes
        ManifestSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        PolicyDigest = Get-GithubPolicyDigest -Tree $tree -ScoopHome $ScoopHome
    }
}

function Assert-GithubSingleManifestDiff {
    param([System.Collections.IDictionary]$BeforeTree, [System.Collections.IDictionary]$AfterTree, [string]$App)
    $path = "bucket/$App.json"
    $paths = @(@($BeforeTree.Keys) + @($AfterTree.Keys) | Sort-Object -Unique -CaseSensitive)
    $changed = @($paths | Where-Object {
            -not $BeforeTree.ContainsKey($_) -or -not $AfterTree.ContainsKey($_) -or
            $BeforeTree[$_].sha -cne $AfterTree[$_].sha -or $BeforeTree[$_].mode -cne $AfterTree[$_].mode -or
            $BeforeTree[$_].type -cne $AfterTree[$_].type
        })
    if ($changed.Count -ne 1 -or $changed[0] -cne $path) { throw 'Full PR tree diff must change exactly one existing bucket manifest.' }
    foreach ($tree in @($BeforeTree, $AfterTree)) {
        if (-not $tree.ContainsKey($path)) { throw 'PR manifest must remain an existing regular file.' }
        Assert-GithubManifestEntry -Entry $tree[$path]
    }
}

function Get-GithubBranchChange {
    param([string]$Repository, [string]$BaseSha, [string]$HeadSha, [string]$App, [switch]$AllowIntegrated)
    $comparison = Invoke-GithubApi -Endpoint "repos/$Repository/compare/$BaseSha...$HeadSha"
    if ($AllowIntegrated -and $comparison.total_commits -eq 0 -and $comparison.status -cin @('behind', 'identical') -and
        $comparison.merge_base_commit.sha -ceq $HeadSha) { return @{ Integrated = $true } }
    if ($comparison.total_commits -lt 1 -or $comparison.total_commits -gt 250 -or @($comparison.commits).Count -ne $comparison.total_commits) { throw 'Managed branch commit history is empty or incomplete.' }
    foreach ($commit in $comparison.commits) {
        # GitHub-mediated signing reports web-flow as the committer of bot-authored commits.
        if ($null -eq $commit.author -or $null -eq $commit.committer -or
            $commit.author.login -cne 'github-actions[bot]' -or $commit.committer.login -cnotin @('github-actions[bot]', 'web-flow')) { throw 'Human commits on managed branch require manual review.' }
        if ($commit.commit.verification.verified -isnot [bool] -or -not $commit.commit.verification.verified -or
            $commit.commit.verification.reason -cne 'valid') { throw 'Managed branch commits must be verified bot-signed commits; unsigned bot email identities are not proof.' }
    }
    $beforeTree = Get-GithubTree -Repository $Repository -Sha $comparison.merge_base_commit.sha
    $afterTree = Get-GithubTree -Repository $Repository -Sha $HeadSha
    Assert-GithubSingleManifestDiff -BeforeTree $beforeTree -AfterTree $afterTree -App $App
    return @{ BeforeTree = $beforeTree; AfterTree = $afterTree }
}

function Get-GithubPullSnapshot {
    param([string]$Repository, [int]$PrNumber, [string]$ExpectedHead, [string]$BaseBranch, [string]$App, [string]$ScoopHome)
    $pull = Get-GithubPull -Repository $Repository -PrNumber $PrNumber
    $baseState = Get-GithubBaseState -Repository $Repository -BaseBranch $BaseBranch -App $App -ScoopHome $ScoopHome
    $change = Get-GithubBranchChange -Repository $Repository -BaseSha $baseState.Sha -HeadSha $ExpectedHead -App $App
    $path = "bucket/$App.json"
    $originalBytes = Get-GithubBlobData -Repository $Repository -BlobSha $change.BeforeTree[$path].sha
    $originalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($originalBytes)).ToLowerInvariant()
    if ($originalHash -cne $baseState.ManifestSha256) { throw 'The target manifest changed since the managed branch was generated.' }
    return @{
        Pull = $pull; BaseSha = $baseState.Sha; BaseBytes = $baseState.Bytes; PolicyDigest = $baseState.PolicyDigest
        HeadBytes = Get-GithubBlobData -Repository $Repository -BlobSha $change.AfterTree[$path].sha
    }
}

function Assert-GithubManagedBranch {
    param([string]$Repository, [string]$App, [string]$BaseBranch, [string]$BaseSha)
    $branch = "automation/update-$App"
    $owner = $Repository.Split('/')[0]
    $headQuery = [Uri]::EscapeDataString("${owner}:$branch")
    $pulls = @(Invoke-GithubApi -Endpoint "repos/$Repository/pulls?state=open&head=$headQuery&per_page=100")
    if ($pulls.Count -gt 1) { throw 'Multiple open PRs use the managed branch.' }
    $reference = $null
    try { $reference = Invoke-GithubApi -Endpoint "repos/$Repository/git/ref/heads/$branch" }
    catch {
        if ($_.Exception.Data['HttpStatus'] -ne 404) { throw }
    }
    if ($null -eq $reference) {
        if ($pulls.Count -gt 0) { throw 'Managed PR branch is missing.' }
        return @{ ExistingPr = 0; HeadSha = '' }
    }
    $null = Get-GithubBranchChange -Repository $Repository -BaseSha $BaseSha -HeadSha $reference.object.sha -App $App -AllowIntegrated:($pulls.Count -eq 0)
    if ($pulls.Count -eq 1) {
        $pull = $pulls[0]
        if ($pull.user.login -cne 'github-actions[bot]' -or $pull.head.repo.full_name -cne $Repository -or
            $pull.base.repo.full_name -cne $Repository -or $pull.head.sha -cne $reference.object.sha -or
            $pull.head.ref -cne $branch -or $pull.base.ref -cne $BaseBranch -or $pull.draft -isnot [bool] -or $pull.draft) { throw 'Existing managed PR identity is invalid.' }
        return @{ ExistingPr = $pull.number; HeadSha = $reference.object.sha }
    }
    return @{ ExistingPr = 0; HeadSha = $reference.object.sha }
}

Export-ModuleMember -Function Invoke-GithubNative, Invoke-GithubApi, Invoke-GithubWorkflowDispatch, Get-GithubPull, Get-GithubTree, Get-GithubBlobData, Assert-GithubPolicyCheckout, Get-GithubPolicyDigest, Get-GithubBaseState, Assert-GithubSingleManifestDiff, Get-GithubBranchChange, Get-GithubPullSnapshot, Assert-GithubManagedBranch
