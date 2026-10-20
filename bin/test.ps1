#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot '../tests'),
    [string]$ScoopHome = $env:SCOOP_HOME,
    [string]$ModulesDirectory = $env:SCOOP_TEST_MODULES,
    [string]$ManifestPathsJson = '[]',
    [string]$ResultDirectory = (Join-Path $PSScriptRoot '../TestResults'),
    [switch]$Coverage,
    [switch]$Analyze
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$ScoopHome) {
    if (!(Get-Command scoop -ErrorAction SilentlyContinue)) { throw 'Set SCOOP_HOME or pass -ScoopHome.' }
    $ScoopHome = & scoop prefix scoop
}
$env:SCOOP_HOME = (Resolve-Path -LiteralPath $ScoopHome).Path
if (!$ModulesDirectory) { $ModulesDirectory = Join-Path $PSScriptRoot '../.devtools/modules' }
$env:PSModulePath = $ModulesDirectory + [IO.Path]::PathSeparator + $env:PSModulePath
Import-Module Pester -RequiredVersion '5.7.1' -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'manifest-policy.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'maintenance-report.psm1') -Force

function Get-CanonicalManifestText([string]$Raw) {
    & {
        param([string]$Content, [string]$Core)
        Set-StrictMode -Off
        . (Join-Path $Core 'lib/core.ps1')
        . (Join-Path $Core 'lib/json.ps1')
        $parseOptions = @{ InputObject = $Content }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $parseOptions.DateKind = 'String' }
        $formatObject = ConvertFrom-Json @parseOptions
        ($formatObject | ConvertToPrettyJson) + "`r`n"
    } $Raw $env:SCOOP_HOME
}

function Assert-ChangedManifest([string]$PathsJson) {
    $paths = ConvertFrom-Json -InputObject $PathsJson -NoEnumerate
    if ($paths -isnot [Array]) { throw 'Manifest paths must be a JSON array.' }
    $exceptionPath = Join-Path $PSScriptRoot '../.github/maintenance-exceptions.json'
    $manualApps = if (Test-Path -LiteralPath $exceptionPath) {
        $null = Get-MaintenanceReport -BucketPath (Join-Path $PSScriptRoot '../bucket') -ExceptionPath $exceptionPath
        @((Read-StrictJsonFile -Path $exceptionPath)['manual'] | ForEach-Object { $_['app'] })
    } else { @() }
    foreach ($relativePath in $paths) {
        if ($relativePath -isnot [string] -or $relativePath -cnotmatch '^bucket/[a-zA-Z0-9][a-zA-Z0-9._+-]*\.json$') {
            throw 'Only regular bucket manifest paths may be validated.'
        }
        $manifestPath = Join-Path (Join-Path $PSScriptRoot '..') $relativePath
        $manifest = Read-StrictJsonFile -Path $manifestPath
        Assert-ManifestSchema -Path $manifestPath -ScoopHome $env:SCOOP_HOME
        $raw = [IO.File]::ReadAllText($manifestPath)
        $canonical = Get-CanonicalManifestText -Raw $raw
        if ($raw -cne $canonical -or ([IO.File]::ReadAllBytes($manifestPath)[0] -eq 0xEF)) {
            throw "Manifest is not canonical UTF-8 without BOM: $relativePath"
        }
        $app = [IO.Path]::GetFileNameWithoutExtension($relativePath)
        if ((Get-ManifestMaintenanceState -Manifest $manifest) -ne 'configured' -and $app -cnotin $manualApps) {
            throw "Add paired checkver/autoupdate rules or an explained maintenance exception: $app"
        }
    }
}

Assert-ChangedManifest -PathsJson $ManifestPathsJson
$testPaths = @(if (Test-Path -LiteralPath $Path -PathType Container) {
    Get-ChildItem -LiteralPath $Path -Filter '*.Tests.ps1' -File | ForEach-Object FullName
} else { (Resolve-Path -LiteralPath $Path).Path })
if (!$testPaths.Count) { throw 'No tests were discovered.' }
New-Item -ItemType Directory -Path $ResultDirectory -Force | Out-Null
$config = New-PesterConfiguration
$config.Run.Path = $testPaths
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.Output.StackTraceVerbosity = 'None'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = Join-Path $ResultDirectory 'tests.xml'
$config.TestResult.OutputFormat = 'NUnitXml'
if ($Coverage) {
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.Path = @(Get-ChildItem -LiteralPath $PSScriptRoot -File |
        Where-Object { $_.Extension -in @('.ps1', '.psm1') -and $_.Name -notin @('test.ps1', 'install-test-tools.ps1') } |
        ForEach-Object FullName)
    $config.CodeCoverage.CoveragePercentTarget = 80
    $config.CodeCoverage.OutputPath = Join-Path $ResultDirectory 'coverage.xml'
    $config.CodeCoverage.OutputFormat = 'JaCoCo'
}
$result = Invoke-Pester -Configuration $config
if ($result.TotalCount -eq 0 -or $result.FailedCount -or $result.FailedContainersCount -or $result.SkippedCount) {
    throw 'Tests failed, were skipped, or discovered no required cases.'
}
if ($Coverage -and $result.CodeCoverage.CoveragePercent -lt 80) { throw 'Production automation coverage is below 80%.' }
if ($Analyze) {
    Import-Module PSScriptAnalyzer -RequiredVersion '1.24.0' -Force -ErrorAction Stop
    $diagnostics = @(Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -Severity Error, Warning)
    if ($diagnostics.Count) {
        $diagnostics | Format-Table RuleName, ScriptName, Line, Message -AutoSize | Out-Host
        throw 'PowerShell static analysis reported findings.'
    }
}
Write-Information 'All requested checks passed. No upstream source checks or GitHub writes were performed.' -InformationAction Continue
