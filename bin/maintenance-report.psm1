#Requires -Version 7.2
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'manifest-policy.psm1') -ErrorAction Stop

function Test-ProtocolSchema([object]$Value) {
    ($Value -is [int] -or $Value -is [long]) -and $Value -eq 1
}

function Get-ManualMaintenanceReason {
    param([string]$ExceptionPath)

    $reasons = @{}
    if (!$ExceptionPath) { return $reasons }
    $configuration = Read-StrictJsonFile -Path $ExceptionPath
    if (!(Test-ProtocolSchema -Value $configuration['schema']) -or !$configuration.Contains('manual') -or
        $configuration['manual'] -isnot [Array]) {
        throw 'Maintenance exceptions must declare integer schema 1 and a manual array.'
    }
    foreach ($entry in @($configuration['manual'])) {
        if ($entry -isnot [Collections.IDictionary]) { throw 'A maintenance exception must be an object.' }
        foreach ($field in @('app', 'reason', 'source')) {
            if (!$entry.Contains($field) -or $entry[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($entry[$field])) {
                throw 'Maintenance exceptions require an app, reason, and source.'
            }
        }
        $source = $null
        if (![Uri]::TryCreate($entry['source'], [UriKind]::Absolute, [ref]$source) -or
            $source.Scheme -notin @('https', 'http') -or $source.UserInfo) {
            throw 'Maintenance exception sources must be public HTTP(S) references without credentials.'
        }
        $app = [string]$entry['app']
        $null = Assert-SafeAppName -App $app
        if ($reasons.ContainsKey($app) -or [string]::IsNullOrWhiteSpace($entry['reason'])) {
            throw "Duplicate or unexplained maintenance exception: $app"
        }
        $reasons[$app] = [string]$entry['reason']
    }
    return $reasons
}

function Get-ManifestMetadataIssue {
    param([System.Collections.IDictionary]$Manifest)

    foreach ($name in @('version', 'description', 'homepage', 'license')) {
        if (!$Manifest.Contains($name)) {
            "Missing $name"
            continue
        }
        $value = $Manifest[$name]
        if ($name -eq 'license' -and $value -is [System.Collections.IDictionary]) {
            if (!$value.Contains('identifier') -or [string]::IsNullOrWhiteSpace($value['identifier'])) {
                'Missing license identifier'
            }
        } elseif ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            "Missing or invalid $name"
        }
    }
}

function Get-ManifestReportEntry {
    param([IO.FileInfo]$File, [hashtable]$ManualReasons)

    try {
        $app = $File.BaseName
        $null = Assert-SafeAppName -App $app
        $manifest = Read-StrictJsonFile -Path $File.FullName
        $ruleState = Get-ManifestMaintenanceState -Manifest $manifest
        $issues = @(Get-ManifestMetadataIssue -Manifest $manifest)
        $isManual = $ManualReasons.ContainsKey($app)
        $reason = if ($isManual) {
            $ManualReasons[$app]
        } elseif ($issues.Count) {
            $issues -join '; '
        } elseif ($ruleState -ne 'configured') {
            "Update rules: $ruleState"
        } else {
            'Update rules configured; upstream availability has not been checked.'
        }
        [pscustomobject]@{
            App = $app
            State = $(if ($isManual) { 'manual' } else { $ruleState })
            RuleState = $ruleState
            Eligible = ($ruleState -eq 'configured' -and !$isManual -and !$issues.Count)
            Reason = $reason
            Issues = $issues
        }
    } catch {
        [pscustomobject]@{
            App = $File.BaseName
            State = 'invalid'
            RuleState = 'invalid'
            Eligible = $false
            Reason = $_.Exception.Message
            Issues = @($_.Exception.Message)
        }
    }
}

function Get-MaintenanceReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BucketPath,
        [string]$ExceptionPath
    )

    if (!(Test-Path -LiteralPath $BucketPath -PathType Container)) {
        throw "Bucket directory does not exist: $BucketPath"
    }
    $manualReasons = Get-ManualMaintenanceReason -ExceptionPath $ExceptionPath
    $files = @(Get-ChildItem -LiteralPath $BucketPath -Filter '*.json' -File | Sort-Object Name)
    $apps = @($files | ForEach-Object { Get-ManifestReportEntry -File $_ -ManualReasons $manualReasons })
    foreach ($app in $manualReasons.Keys) {
        if ($app -cnotin $files.BaseName) { throw "Maintenance exception refers to an unknown app: $app" }
    }
    [pscustomobject]@{
        Total = $apps.Count
        EligibleCount = @($apps | Where-Object Eligible).Count
        Configured = @($apps | Where-Object RuleState -EQ 'configured').Count
        MissingCheckver = @($apps | Where-Object RuleState -EQ 'missing-checkver').Count
        MissingAutoupdate = @($apps | Where-Object RuleState -EQ 'missing-autoupdate').Count
        Manual = @($apps | Where-Object State -EQ 'manual').Count
        Invalid = @($apps | Where-Object State -EQ 'invalid').Count
        Apps = $apps
    }
}

function Split-UpdateApp {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [string[]]$Apps = @(),
        [ValidateRange(1, 64)] [int]$BatchSize = 16
    )

    foreach ($app in $Apps) { $null = Assert-SafeAppName -App $app }
    if (@($Apps | Sort-Object -Unique).Count -ne $Apps.Count) {
        throw 'Selected apps must have unique names.'
    }
    $batches = [Collections.Generic.List[object]]::new()
    for ($offset = 0; $offset -lt $Apps.Count; $offset += $BatchSize) {
        $end = [Math]::Min($offset + $BatchSize, $Apps.Count) - 1
        $batches.Add([pscustomobject]@{ batch = [string]$batches.Count; apps = @($Apps[$offset..$end]) })
    }
    [pscustomobject]@{ include = @($batches.ToArray()) }
}

function Get-FailedOutcome {
    param([string]$App, [string]$Reason)
    [pscustomobject]@{ app = $App; status = 'failed'; reason = $Reason; artifact = '' }
}

function Assert-OutcomeProvenance {
    param(
        [System.Collections.IDictionary]$Record,
        [string]$App, [string]$RunId, [string]$RunAttempt, [string]$BaseSha
    )

    foreach ($name in @('schema', 'app', 'status', 'reason', 'baseSha', 'runId', 'runAttempt', 'sourceResolved')) {
        if (!$Record.Contains($name)) { throw "Worker result is missing $name" }
    }
    if (!(Test-ProtocolSchema -Value $Record['schema'])) {
        throw 'Unsupported worker result schema.'
    }
    foreach ($field in @('app', 'baseSha', 'runId', 'runAttempt')) {
        if ($Record[$field] -isnot [string]) { throw 'Worker identity fields must be strings.' }
    }
    if ($Record['app'] -cne $App -or $Record['runId'] -cne $RunId -or
        $Record['runAttempt'] -cne $RunAttempt -or $Record['baseSha'] -cne $BaseSha) {
        throw 'Worker result belongs to another app, source commit, run, or attempt.'
    }
    if ($Record['status'] -cnotin @('current', 'updated', 'unavailable', 'manual', 'failed') -or
        $Record['sourceResolved'] -isnot [bool] -or $Record['reason'] -isnot [string]) {
        throw 'Worker result contains an invalid terminal state.'
    }
    if ($Record['status'] -in @('current', 'updated')) {
        if (!$Record['sourceResolved'] -or !$Record.Contains('oldVersion') -or !$Record.Contains('newVersion') -or
            [string]::IsNullOrWhiteSpace($Record['oldVersion']) -or [string]::IsNullOrWhiteSpace($Record['newVersion'])) {
            throw 'A successful worker outcome requires positive version-discovery evidence.'
        }
        if ($Record['status'] -eq 'current' -and $Record['oldVersion'] -cne $Record['newVersion']) {
            throw 'A current outcome reports different old and discovered versions.'
        }
    }
}

function Assert-OutcomeFile {
    param([IO.DirectoryInfo]$Directory, [System.Collections.IDictionary]$Record)

    if ($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Artifact directories cannot be links.' }
    $expected = @(if ($Record['status'] -eq 'updated') { 'result.json'; 'candidate.json' } else { 'result.json' })
    $files = @(Get-ChildItem -LiteralPath $Directory.FullName -Force)
    foreach ($file in $files) {
        if ($file.PSIsContainer -or $file.Name -cnotin $expected -or
            ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Artifact contains an unexpected file, directory, or link.'
        }
    }
    if ($files.Count -ne $expected.Count) { throw 'Artifact is incomplete.' }
    if ($Record['status'] -ne 'updated') { return }
    foreach ($name in @('originalSha256', 'candidateSha256')) {
        if (!$Record.Contains($name) -or $Record[$name] -cnotmatch '^[0-9a-fA-F]{64}$') {
            throw "Artifact is missing a concrete $name"
        }
    }
    $candidate = Join-Path $Directory.FullName 'candidate.json'
    if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ine $Record['candidateSha256']) {
        throw 'Candidate bytes do not match their recorded SHA256.'
    }
    $manifest = Read-StrictJsonFile -Path $candidate
    if ($manifest['version'] -cne $Record['newVersion'] -or $Record['oldVersion'] -ceq $Record['newVersion']) {
        throw 'Candidate version does not match the update evidence.'
    }
}

function Get-OutcomeDirectory {
    param([string]$ArtifactDirectory, [string]$RunAttempt)

    if (!(Test-Path -LiteralPath $ArtifactDirectory -PathType Container)) { return }
    $root = Get-Item -LiteralPath $ArtifactDirectory
    if ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Artifact root cannot be a link.' }
    $pattern = '^scoop-updates-' + [regex]::Escape($RunAttempt) + '-[0-9]+$'
    foreach ($batch in @(Get-ChildItem -LiteralPath $ArtifactDirectory -Force)) {
        if (!$batch.PSIsContainer -or $batch.Name -cnotmatch $pattern -or
            ($batch.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Artifact collection contains an unexpected batch or link.'
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $batch.FullName -Force)) {
            if (!$directory.PSIsContainer) { throw 'Expected a per-app artifact directory.' }
            $null = Assert-SafeAppName -App $directory.Name
            [pscustomobject]@{ App = $directory.Name; Directory = $directory; Artifact = $batch.Name }
        }
    }
}

function Read-AppOutcome {
    param(
        [object]$Entry, [string]$App, [string]$RunId, [string]$RunAttempt, [string]$BaseSha
    )

    try {
        $record = Read-StrictJsonFile -Path (Join-Path $Entry.Directory.FullName 'result.json')
        Assert-OutcomeProvenance -Record $record -App $App -RunId $RunId -RunAttempt $RunAttempt -BaseSha $BaseSha
        Assert-OutcomeFile -Directory $Entry.Directory -Record $record
        [pscustomobject]@{ app = $App; status = $record['status']; reason = $record['reason']; artifact = $Entry.Artifact }
    } catch {
        Get-FailedOutcome -App $App -Reason $_.Exception.Message
    }
}

function Get-SelectedOutcome {
    param(
        [object[]]$Entries, [string[]]$Apps, [string]$RunId, [string]$RunAttempt, [string]$BaseSha
    )

    foreach ($app in $Apps) {
        $matchingEntries = @($Entries | Where-Object App -CEQ $app)
        if ($matchingEntries.Count -ne 1) {
            $reason = if ($matchingEntries.Count) { 'Duplicate worker outcomes.' } else { 'No worker result was produced.' }
            Get-FailedOutcome -App $app -Reason $reason
        } else {
            Read-AppOutcome -Entry $matchingEntries[0] -App $app -RunId $RunId -RunAttempt $RunAttempt -BaseSha $BaseSha
        }
    }
}

function Select-PublishCandidate {
    param([object[]]$Results, [int]$MaxUpdates, [long]$RunNumber)

    $candidates = @($Results | Where-Object status -EQ 'updated' | Sort-Object app)
    $selected = [Collections.Generic.List[object]]::new()
    if ($candidates.Count) {
        $offset = ((($RunNumber - 1) % $candidates.Count) * $MaxUpdates) % $candidates.Count
        for ($index = 0; $index -lt [Math]::Min($MaxUpdates, $candidates.Count); $index++) {
            $candidate = $candidates[($offset + $index) % $candidates.Count]
            $selected.Add([pscustomobject]@{ app = $candidate.app; artifact = $candidate.artifact })
        }
    }
    [pscustomobject]@{ include = @($selected.ToArray()) }
}

function Get-UpdateCollectionReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ArtifactDirectory,
        [AllowEmptyCollection()] [string[]]$SelectedApps = @(),
        [Parameter(Mandatory)] [string]$ExpectedRunId,
        [Parameter(Mandatory)] [string]$ExpectedRunAttempt,
        [Parameter(Mandatory)] [string]$BaseSha,
        [ValidateRange(1, 256)] [int]$MaxUpdates = 32,
        [ValidateRange(1, [long]::MaxValue)] [long]$RunNumber = 1
    )

    $null = Split-UpdateApp -Apps $SelectedApps
    $entries = @(Get-OutcomeDirectory -ArtifactDirectory $ArtifactDirectory -RunAttempt $ExpectedRunAttempt)
    foreach ($entry in $entries) {
        if ($entry.App -cnotin $SelectedApps) { throw "Artifact contains an unselected app: $($entry.App)" }
    }
    $results = @(Get-SelectedOutcome -Entries $entries -Apps $SelectedApps -RunId $ExpectedRunId `
        -RunAttempt $ExpectedRunAttempt -BaseSha $BaseSha)
    $counts = [ordered]@{
        current = @($results | Where-Object status -EQ 'current').Count
        updated = @($results | Where-Object status -EQ 'updated').Count
        unavailable = @($results | Where-Object status -EQ 'unavailable').Count
        manual = @($results | Where-Object status -EQ 'manual').Count
        failed = @($results | Where-Object status -EQ 'failed').Count
    }
    $matrix = Select-PublishCandidate -Results $results -MaxUpdates $MaxUpdates -RunNumber $RunNumber
    [pscustomobject]@{
        SelectedCount = $SelectedApps.Count
        Counts = $counts
        AllCurrent = ($SelectedApps.Count -gt 0 -and $counts.current -eq $SelectedApps.Count)
        DeferredCount = $counts.updated - @($matrix.include).Count
        PublishMatrix = $matrix
        Results = $results
    }
}

function Invoke-ManifestWorkerProcess {
    param([string[]]$ArgumentList)

    $hostPath = (Get-Process -Id $PID).Path
    & $hostPath @ArgumentList *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Worker process exited with code $LASTEXITCODE."
    }
}

function Assert-SafeOutputDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    if (![IO.Path]::IsPathFullyQualified($Path)) {
        throw 'Output paths must be fully qualified filesystem paths.'
    }
    $directory = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Path))
    while ($null -ne $directory) {
        $item = $null
        try {
            $item = Get-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop
        } catch [Management.Automation.ItemNotFoundException] {
            $item = $null
        }
        if ($null -ne $item -and (!$item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
            throw 'Output directories and their ancestors must be regular, unlinked directories.'
        }
        $directory = $directory.Parent
    }
}

function Write-FailedWorkerResult {
    param([string]$Directory, [string]$App, [string]$Reason, [string]$BaseSha, [string]$RunId, [string]$RunAttempt)

    Assert-SafeOutputDirectory -Path $Directory
    $resultPath = Join-Path $Directory 'result.json'
    if ((Test-Path -LiteralPath $Directory) -and
        ((Get-Item -LiteralPath $Directory -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Cannot write results through a linked directory.'
    }
    $failureReason = $Reason
    if (Test-Path -LiteralPath $resultPath) {
        $item = Get-Item -LiteralPath $resultPath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Cannot overwrite a non-regular result file.'
        }
        try {
            $existing = Read-StrictJsonFile -Path $resultPath
            if ($existing.Contains('status') -and $existing['status'] -cin @('failed', 'manual', 'unavailable')) {
                return
            }
        } catch {
            $failureReason = "$Reason The existing result could not be validated."
        }
    }
    New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
    $result = [ordered]@{
        schema = 1; app = $App; status = 'failed'; reason = $failureReason
        baseSha = $BaseSha; runId = $RunId; runAttempt = $RunAttempt; sourceResolved = $false
    }
    [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 10))
}

function Invoke-UpdateBatch {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [string[]]$Apps = @(),
        [Parameter(Mandatory)] [string]$BucketPath,
        [Parameter(Mandatory)] [string]$OutputDirectory,
        [Parameter(Mandatory)] [string]$ScoopHome,
        [Parameter(Mandatory)] [ValidatePattern('^[a-fA-F0-9]{40}$')] [string]$BaseSha,
        [Parameter(Mandatory)] [string]$RunId,
        [Parameter(Mandatory)] [string]$RunAttempt,
        [ValidateRange(30, 1800)] [int]$TimeoutSeconds = 300
    )

    $null = Split-UpdateApp -Apps $Apps
    Assert-SafeOutputDirectory -Path $OutputDirectory
    if ((Test-Path -LiteralPath $OutputDirectory) -and @(Get-ChildItem -LiteralPath $OutputDirectory -Force -ErrorAction Stop).Count) {
        throw 'Batch execution requires a new empty output directory.'
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop | Out-Null
    foreach ($app in $Apps) {
        $appDirectory = Join-Path $OutputDirectory $app
        $arguments = @('-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot 'update-manifest.ps1'),
            '-App', $app, '-ManifestPath', (Join-Path $BucketPath "$app.json"), '-OutputDirectory', $appDirectory,
            '-ScoopHome', $ScoopHome, '-BaseSha', $BaseSha, '-RunId', $RunId, '-RunAttempt', $RunAttempt,
            '-TimeoutSeconds', [string]$TimeoutSeconds)
        try {
            Write-Information "Checking $app" -InformationAction Continue
            Invoke-ManifestWorkerProcess -ArgumentList $arguments
            if (!(Test-Path -LiteralPath (Join-Path $appDirectory 'result.json') -PathType Leaf)) {
                throw 'Worker exited without producing a result.'
            }
        } catch {
            try {
                Write-FailedWorkerResult -Directory $appDirectory -App $app -Reason $_.Exception.Message `
                    -BaseSha $BaseSha -RunId $RunId -RunAttempt $RunAttempt
            } catch {
                Write-Warning "Could not record a result for $app; aggregation will report it as failed."
            }
        }
    }
}

Export-ModuleMember -Function Get-MaintenanceReport, Split-UpdateApp, Get-UpdateCollectionReport, Invoke-UpdateBatch, Assert-SafeOutputDirectory
