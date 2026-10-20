#Requires -Version 7.0
<#
.SYNOPSIS
Stages, dispatches, validates, records status for, or merges one managed Scoop update.
.DESCRIPTION
Run only this trusted default-branch entry point with write credentials. PR manifests
and downloaded archives are data, never scripts. Stage copies only the exact validated
candidate file; create-pull-request remains responsible for branch and PR publication.
Validate is read-only on GitHub and checks every declared SHA256 without executing
binaries. Status and Merge consume validation evidence from this exact run/attempt.
All publication requires Enabled to be exactly 'true' and the explicit Publish switch.
The CLI uses only GITHUB_TOKEN. Check-only or disabled calls cannot publish a status,
dispatch validation, or merge. A head SHA is protected atomically by the Merge API;
relevant base-input rereads are not an atomic base-SHA compare-and-swap.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Stage', 'Dispatch', 'Validate', 'Status', 'Merge')][string]$Mode,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$App,
    [string]$BaseBranch = 'master',
    [int]$PrNumber,
    [string]$ExpectedHead,
    [string]$ScoopHome,
    [string]$OutputDirectory,
    [string]$ValidationPath,
    [string]$CandidateDirectory,
    [string]$BaseSha,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$RunAttempt,
    [AllowEmptyString()][string]$Enabled = '',
    [switch]$Publish,
    [switch]$ValidationSucceeded,
    [string]$RepositoryDirectory = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'github-update.psm1') -Force
$arguments = @{} + $PSBoundParameters
$arguments.Publish = [bool]$Publish.IsPresent
$arguments.ValidationSucceeded = [bool]$ValidationSucceeded.IsPresent
$result = Invoke-GithubUpdate @arguments
ConvertTo-Json -InputObject $result -Depth 30 -Compress
