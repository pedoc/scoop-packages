#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Inventory', 'Batch', 'Collect', 'Verdict')] [string]$Mode = 'Inventory',
    [string]$BucketPath = (Join-Path $PSScriptRoot '../bucket'),
    [string]$ExceptionPath,
    [string]$OutputDirectory,
    [string]$ArtifactDirectory,
    [string]$SelectedAppsPath,
    [string]$CollectedReportPath,
    [string]$Apps = '',
    [string]$AppsJson = '[]',
    [string]$ScoopHome = $env:SCOOP_HOME,
    [string]$BaseSha = $env:GITHUB_SHA,
    [string]$RunId = $(if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { 'local' }),
    [string]$RunAttempt = $(if ($env:GITHUB_RUN_ATTEMPT) { $env:GITHUB_RUN_ATTEMPT } else { '1' }),
    [long]$RunNumber = 1,
    [ValidateRange(1, 64)] [int]$BatchSize = 16,
    [ValidateRange(1, 256)] [int]$MaxUpdates = 32,
    [ValidateRange(30, 1800)] [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'maintenance-report.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'manifest-policy.psm1') -Force

function New-ReportDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)

    if (!$Path) { $Path = Join-Path ([IO.Path]::GetTempPath()) "scoop-maintenance-$([guid]::NewGuid().ToString('N'))" }
    Assert-SafeOutputDirectory -Path $Path
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            @(Get-ChildItem -LiteralPath $Path -Force).Count) {
            throw 'Reports require a new empty, non-linked directory.'
        }
    }
    if (!$PSCmdlet.ShouldProcess($Path, 'Create a temporary report directory')) {
        throw 'Report directory creation was declined.'
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    [IO.Path]::GetFullPath($Path)
}

function Write-ReportJson([string]$Path, [object]$Value) {
    if (Test-Path -LiteralPath $Path) { throw "Refusing to overwrite an existing report: $Path" }
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 40))
}

function Write-ActionValue([string]$Name, [string]$Value) {
    if (!$env:GITHUB_OUTPUT) { return }
    if ($Name -notmatch '^[a-z_]+$' -or $Value -match '[\r\n]') { throw 'Unsafe Actions output.' }
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "$Name=$Value`n")
}

function Get-SelectedAppName([object]$Report, [string]$RequestedApps) {
    $requested = @($RequestedApps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (!$requested.Count) { return @($Report.Apps | Where-Object Eligible | ForEach-Object App) }
    foreach ($app in $requested) {
        $null = Assert-SafeAppName -App $app
        if ($app -cnotin $Report.Apps.App) { throw "Requested app was not found: $app" }
    }
    @($Report.Apps | Where-Object { $_.Eligible -and $_.App -cin $requested } | ForEach-Object App)
}

function Get-SourceSha([string]$Sha) {
    if (!$Sha) {
        $Sha = & git -C (Join-Path $PSScriptRoot '..') rev-parse HEAD
        if ($LASTEXITCODE -ne 0) { throw 'Could not determine the source commit.' }
    }
    if ($Sha -cnotmatch '^[a-f0-9]{40}$') { throw 'A concrete source commit SHA is required.' }
    $Sha
}

function Write-InventoryReport {
    param(
        [string]$BucketPath, [string]$ExceptionPath, [string]$OutputDirectory, [string]$RequestedApps,
        [string]$BaseSha, [string]$RunId, [string]$RunAttempt, [int]$BatchSize
    )

    $exceptions = $ExceptionPath
    $defaultBucket = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../bucket'))
    $defaultExceptions = Join-Path $PSScriptRoot '../.github/maintenance-exceptions.json'
    if (!$exceptions -and [IO.Path]::GetFullPath($BucketPath) -eq $defaultBucket -and (Test-Path -LiteralPath $defaultExceptions)) {
        $exceptions = $defaultExceptions
    }
    $report = Get-MaintenanceReport -BucketPath $BucketPath -ExceptionPath $exceptions
    $selected = @(Get-SelectedAppName -Report $report -RequestedApps $RequestedApps)
    $matrix = Split-UpdateApp -Apps $selected -BatchSize $BatchSize
    Write-ReportJson -Path (Join-Path $OutputDirectory 'inventory.json') -Value $report
    Write-ReportJson -Path (Join-Path $OutputDirectory 'selection.json') -Value ([ordered]@{
        schema = 1; baseSha = $BaseSha; runId = $RunId; runAttempt = $RunAttempt; apps = $selected
    })
    Write-ActionValue -Name 'matrix' -Value ($matrix | ConvertTo-Json -Depth 20 -Compress)
    Write-ActionValue -Name 'selected_count' -Value ([string]$selected.Count)
    Write-ActionValue -Name 'base_sha' -Value $BaseSha
    $summary = "Inventory: $($report.Total) manifests; $($report.Configured) paired rules; $($selected.Count) selected; $($report.Invalid) strict-JSON errors."
    Write-Information $summary -InformationAction Continue
    if ($env:GITHUB_STEP_SUMMARY) {
        [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, "## Scoop maintenance inventory`n`n$summary`n`nConfigured does not mean the upstream has been checked.`n")
    }
}

function Write-CollectedReport {
    param(
        [string]$SelectionPath, [string]$ArtifactDirectory, [string]$OutputDirectory, [string]$BaseSha,
        [string]$RunId, [string]$RunAttempt, [int]$MaxUpdates, [long]$RunNumber
    )

    if (!$SelectionPath -or !$ArtifactDirectory) { throw 'Collect requires selection and artifact paths.' }
    $selection = Read-StrictJsonFile -Path $SelectionPath
    if ($selection['schema'] -ne 1 -or $selection['baseSha'] -cne $BaseSha -or
        $selection['runId'] -cne $RunId -or $selection['runAttempt'] -cne $RunAttempt) {
        throw 'Selection metadata belongs to another source, run, or attempt.'
    }
    $report = Get-UpdateCollectionReport -ArtifactDirectory $ArtifactDirectory -SelectedApps @($selection['apps']) `
        -ExpectedRunId $RunId -ExpectedRunAttempt $RunAttempt -BaseSha $BaseSha -MaxUpdates $MaxUpdates -RunNumber $RunNumber
    Write-ReportJson -Path (Join-Path $OutputDirectory 'report.json') -Value $report
    Write-ActionValue -Name 'publish_matrix' -Value ($report.PublishMatrix | ConvertTo-Json -Depth 20 -Compress)
    Write-ActionValue -Name 'has_updates' -Value ([string](@($report.PublishMatrix.include).Count -gt 0)).ToLowerInvariant()
    $counts = $report.Counts
    $summary = "Selected $($report.SelectedCount): current=$($counts.current), updated=$($counts.updated), unavailable=$($counts.unavailable), manual=$($counts.manual), failed=$($counts.failed); deferred=$($report.DeferredCount)."
    Write-Information $summary -InformationAction Continue
    if ($env:GITHUB_STEP_SUMMARY) {
        [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, "## Scoop update results`n`n$summary`n`nPer-app source failures are reported by the independent source-verdict job. Dispatch is not a completed merge.`n")
    }
}

function Assert-SourceVerdict([string]$Path) {
    if (!$Path) { throw 'Verdict requires a collected report path.' }
    $report = Read-StrictJsonFile -Path $Path
    foreach ($field in @('SelectedCount', 'Counts', 'Results')) {
        if (!$report.Contains($field)) { throw 'Incomplete collected report.' }
    }
    if (($report['SelectedCount'] -isnot [int] -and $report['SelectedCount'] -isnot [long]) -or $report['SelectedCount'] -lt 0) {
        throw 'Invalid selected-app count.'
    }
    $counts = $report['Counts']
    if ($counts -isnot [Collections.IDictionary]) { throw 'Invalid source outcome counters.' }
    $sum = [long]0
    foreach ($state in @('current', 'updated', 'unavailable', 'manual', 'failed')) {
        if (!$counts.Contains($state) -or ($counts[$state] -isnot [int] -and $counts[$state] -isnot [long]) -or $counts[$state] -lt 0) {
            throw 'Invalid source outcome counter.'
        }
        $sum += $counts[$state]
    }
    if ($sum -ne $report['SelectedCount'] -or @($report['Results']).Count -ne $sum) { throw 'Source outcomes are incomplete.' }
    if ($counts['failed'] -or $counts['unavailable'] -or $counts['manual']) {
        throw 'Some selected packages could not be automatically checked or updated; inspect the per-app report. Healthy siblings are not blocked.'
    }
    $message = if (!$sum) { 'No eligible packages were selected; no update or merge was attempted.' } else { 'The source outcome report is complete. Updated candidates still require their own validation.' }
    Write-Information $message -InformationAction Continue
}

if ($Mode -eq 'Verdict') { Assert-SourceVerdict -Path $CollectedReportPath; return }
$BaseSha = Get-SourceSha -Sha $BaseSha
$OutputDirectory = New-ReportDirectory -Path $OutputDirectory
switch ($Mode) {
    'Inventory' {
        Write-InventoryReport -BucketPath $BucketPath -ExceptionPath $ExceptionPath -OutputDirectory $OutputDirectory `
            -RequestedApps $Apps -BaseSha $BaseSha -RunId $RunId -RunAttempt $RunAttempt -BatchSize $BatchSize
    }
    'Batch' {
        if (!$ScoopHome) { throw 'Batch generation requires a trusted ScoopHome.' }
        $batchApps = ConvertFrom-Json -InputObject $AppsJson -NoEnumerate
        if ($batchApps -isnot [Array] -or $batchApps.Count -gt 64 -or @($batchApps | Where-Object { $_ -isnot [string] }).Count) {
            throw 'Batch apps must be a bounded JSON array of names.'
        }
        Invoke-UpdateBatch -Apps $batchApps -BucketPath $BucketPath -OutputDirectory $OutputDirectory `
            -ScoopHome $ScoopHome -BaseSha $BaseSha -RunId $RunId -RunAttempt $RunAttempt -TimeoutSeconds $TimeoutSeconds
    }
    'Collect' {
        Write-CollectedReport -SelectionPath $SelectedAppsPath -ArtifactDirectory $ArtifactDirectory -OutputDirectory $OutputDirectory `
            -BaseSha $BaseSha -RunId $RunId -RunAttempt $RunAttempt -MaxUpdates $MaxUpdates -RunNumber $RunNumber
    }
}
Write-Information "Reports: $OutputDirectory" -InformationAction Continue
