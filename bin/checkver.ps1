#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$App = '*',
    [string]$Dir = (Join-Path $PSScriptRoot '../bucket'),
    [string]$ScoopHome = $env:SCOOP_HOME,
    [switch]$Update,
    [switch]$SkipUpdated,
    [switch]$ThrowError
)

$ErrorActionPreference = 'Stop'
if (!$ScoopHome) {
    if (!(Get-Command scoop -ErrorAction SilentlyContinue)) { throw 'Set SCOOP_HOME or pass -ScoopHome.' }
    $ScoopHome = & scoop prefix scoop
}
$checker = Join-Path $ScoopHome 'bin/checkver.ps1'
if (!(Test-Path -LiteralPath $checker -PathType Leaf)) { throw "Scoop version checker was not found: $checker" }
$parameters = @{
    App = $App
    Dir = (Resolve-Path -LiteralPath $Dir).Path
    Update = $Update.IsPresent
    SkipUpdated = $SkipUpdated.IsPresent
    ThrowError = $ThrowError.IsPresent
}
& $checker @parameters
