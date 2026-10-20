#Requires -Version 7.2
<#
.SYNOPSIS
    Generate one isolated Scoop manifest candidate without changing the bucket.
.DESCRIPTION
    Explicitly checks the configured source and downloads assets only when needed
    for an upgrade. Results are data-only artifacts; no package is installed or run.
#>
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

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'update-worker.psm1') -Force -ErrorAction Stop
Invoke-ManifestUpdateWorker @PSBoundParameters | ConvertTo-Json -Depth 20
