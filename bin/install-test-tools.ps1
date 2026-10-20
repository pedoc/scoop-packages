#Requires -Version 7.2
param(
    [string]$ModulesDirectory = (Join-Path $PSScriptRoot '../.devtools/modules')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (!(Get-Command Save-PSResource -ErrorAction SilentlyContinue)) {
    throw 'Save-PSResource is required. Use PowerShell 7.4 or newer, or provide the pinned test modules yourself.'
}

$dependencies = @(
    @{ Name = 'Pester'; Version = '5.7.1' },
    @{ Name = 'BuildHelpers'; Version = '2.0.16' },
    @{ Name = 'PSScriptAnalyzer'; Version = '1.24.0' }
)

New-Item -ItemType Directory -Path $ModulesDirectory -Force | Out-Null
foreach ($dependency in $dependencies) {
    $moduleDirectory = Join-Path $ModulesDirectory "$($dependency.Name)/$($dependency.Version)"
    $manifestPath = Join-Path $moduleDirectory "$($dependency.Name).psd1"
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
        if ([string]$manifest.ModuleVersion -ne $dependency.Version) {
            throw "Unexpected cached module version: $manifestPath"
        }
        continue
    }
    if (Test-Path -LiteralPath $moduleDirectory) {
        throw "Incomplete module directory; inspect it or choose a fresh destination: $moduleDirectory"
    }
    Write-Output "Saving $($dependency.Name) $($dependency.Version) from PSGallery"
    $package = Find-PSResource -Name $dependency.Name -Version $dependency.Version -Repository PSGallery
    if (!$package) { throw "Required package was not found: $($dependency.Name) $($dependency.Version)" }
    Save-PSResource -Name $dependency.Name -Version $dependency.Version -Repository PSGallery `
        -Path $ModulesDirectory -TrustRepository -AcceptLicense -Quiet
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Module installation did not produce the expected manifest: $manifestPath"
    }
}
Write-Output "Pinned test modules are available in $ModulesDirectory"
