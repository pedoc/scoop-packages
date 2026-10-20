#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$RepositoryDirectory = (Join-Path $PSScriptRoot '..'),
    [string]$BaseSha,
    [string]$HeadSha
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-GitRead([string]$Repository, [string[]]$ArgumentList) {
    $output = & git -C $Repository -c core.quotepath=false @ArgumentList 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Git could not read the requested comparison; refusing an empty success result.' }
    @($output)
}

if (!$HeadSha) { $HeadSha = [string](Invoke-GitRead -Repository $RepositoryDirectory -ArgumentList @('rev-parse', 'HEAD')) }
if ($HeadSha -cnotmatch '^[a-fA-F0-9]{40}$' -or
    ($BaseSha -and $BaseSha -cnotmatch '^[a-fA-F0-9]{40}$')) {
    throw 'Comparison inputs must be concrete commit SHAs.'
}
if (!$BaseSha) {
    $parents = [string](Invoke-GitRead -Repository $RepositoryDirectory -ArgumentList @('show', '--no-patch', '--format=%P', $HeadSha))
    $BaseSha = @($parents -split ' ' | Where-Object { $_ } | Select-Object -First 1) -join ''
}
$arguments = if (!$BaseSha -or $BaseSha -match '^0{40}$') {
    @('diff-tree', '--root', '--no-commit-id', '--no-renames', '--name-only', '--diff-filter=AMT', '-r', $HeadSha)
} else {
    @('diff', '--no-ext-diff', '--no-renames', '--name-only', '--diff-filter=AMT', $BaseSha, $HeadSha)
}
$paths = @(Invoke-GitRead -Repository $RepositoryDirectory -ArgumentList ($arguments + @('--', 'bucket/*.json')) | Where-Object { $_ })
foreach ($path in $paths) {
    if ($path -cnotmatch '^bucket/[a-zA-Z0-9][a-zA-Z0-9._+-]*\.json$') {
        throw 'Changed manifests contain an unsafe or unsupported path.'
    }
}
ConvertTo-Json -InputObject @($paths) -Compress
