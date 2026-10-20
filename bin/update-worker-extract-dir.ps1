#Requires -Version 7.2
param(
    [Parameter(Mandatory)][string] $BaseManifestPath,
    [Parameter(Mandatory)][string] $CandidatePath,
    [Parameter(Mandatory)][string] $ScoopHome
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
. (Join-Path $ScoopHome 'lib/core.ps1')
. (Join-Path $ScoopHome 'lib/autoupdate.ps1')
. (Join-Path $ScoopHome 'lib/json.ps1')

function Copy-ExtractionProperty {
    param([Collections.IDictionary] $Scope, [string] $Name, [object] $Value)
    $copy = [ordered]@{}
    foreach ($key in $Scope.PSBase.Keys) { $copy[$key] = $Scope[$key] }
    $copy[$Name] = $Value
    return $copy
}

function Get-ExtractionTemplate {
    param([Collections.IDictionary] $Template, [string] $Architecture)
    if ($Architecture -and $Template.architecture -is [Collections.IDictionary] -and
        $Template.architecture.Contains($Architecture) -and $Template.architecture[$Architecture].Contains('extract_dir')) {
        return ,($Template.architecture[$Architecture].extract_dir)
    }
    if ($Template.Contains('extract_dir')) { return ,($Template.extract_dir) }
    return $null
}

function Get-ExtractionScope {
    param([Collections.IDictionary] $Before, [Collections.IDictionary] $After, [object] $Template, [hashtable] $Substitutions)
    # Do not repair removals, replace candidate values, or invent untemplated fields.
    if ($Before.Contains('extract_dir') -or $After.Contains('extract_dir') -or $null -eq $Template) { return $After }
    if ($Template -isnot [string]) { throw 'Only scalar extract_dir templates can be materialized.' }
    $value = substitute $Template $Substitutions
    return Copy-ExtractionProperty $After 'extract_dir' $value
}

function Get-ExtractionManifest {
    param([Collections.IDictionary] $Before, [Collections.IDictionary] $After)
    $substitutions = Get-VersionSubstitution $After.version
    if (-not $Before.Contains('architecture')) {
        return Get-ExtractionScope $Before $After (Get-ExtractionTemplate $Before.autoupdate) $substitutions
    }
    if ($After.architecture -isnot [Collections.IDictionary]) { return $After }
    $architectures = $After.architecture
    foreach ($architecture in $Before.architecture.PSBase.Keys) {
        if (-not $architectures.Contains($architecture)) { continue }
        $override = if ($Before.autoupdate.architecture -is [Collections.IDictionary] -and $Before.autoupdate.architecture.Contains($architecture)) { $Before.autoupdate.architecture[$architecture] } else { $null }
        $hasOverride = $override -is [Collections.IDictionary] -and $override.Contains('extract_dir')
        if (-not $hasOverride -and ($Before.Contains('extract_dir') -or $After.Contains('extract_dir'))) { continue }
        $scope = $architectures[$architecture]
        $expanded = Get-ExtractionScope $Before.architecture[$architecture] $scope (Get-ExtractionTemplate $Before.autoupdate $architecture) $substitutions
        if (-not [object]::ReferenceEquals($scope, $expanded)) {
            $architectures = Copy-ExtractionProperty $architectures $architecture $expanded
        }
    }
    if ([object]::ReferenceEquals($After.architecture, $architectures)) { return $After }
    return Copy-ExtractionProperty $After 'architecture' $architectures
}

$before = [IO.File]::ReadAllText($BaseManifestPath) | ConvertFrom-Json -AsHashtable
$candidate = [IO.File]::ReadAllText($CandidatePath) | ConvertFrom-Json -AsHashtable
$materialized = Get-ExtractionManifest $before $candidate
if (-not [object]::ReferenceEquals($candidate, $materialized)) {
    $parseOptions = @{ InputObject = ($materialized | ConvertTo-Json -Depth 100 -Compress) }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $parseOptions.DateKind = 'String' }
    $formatObject = ConvertFrom-Json @parseOptions
    [IO.File]::WriteAllText($CandidatePath, (ConvertToPrettyJson $formatObject) + "`r`n", [Text.UTF8Encoding]::new($false))
}
