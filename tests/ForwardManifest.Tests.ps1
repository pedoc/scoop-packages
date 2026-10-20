BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repositoryRoot 'bin/manifest-policy.psm1') -Force
    $core = if ($env:SCOOP_HOME) { $env:SCOOP_HOME } else { Join-Path $env:USERPROFILE 'scoop/apps/scoop/current' }

    function Get-ForwardManifest([string]$App) {
        Read-StrictJsonFile -Path (Join-Path $repositoryRoot "bucket/$App.json")
    }

    function Expand-ForwardTemplate([string]$Template, [string]$Version) {
        & {
            param($Text, $NewVersion, $ScoopCore)
            Set-StrictMode -Off
            . (Join-Path $ScoopCore 'lib/core.ps1')
            . (Join-Path $ScoopCore 'lib/versions.ps1')
            . (Join-Path $ScoopCore 'lib/autoupdate.ps1')
            substitute $Text (Get-VersionSubstitution $NewVersion)
        } $Template $Version $core
    }
}

Describe 'Verified forward payload layouts' {
    It 'flattens the published 3proxy archive root before resolving bin64' {
        $manifest = Get-ForwardManifest '3proxy'
        $template = $manifest['autoupdate']['architecture']['64bit']

        $template['extract_dir'] | Should -BeExactly '3proxy'
        ('3proxy/' + $manifest['bin']) | Should -BeExactly '3proxy/bin64/3proxy.exe'
    }

    It 'updates HackBrowserData binary layout without changing its command alias' {
        $manifest = Get-ForwardManifest 'HackBrowserData'

        $manifest['autoupdate']['bin'][0][0] | Should -BeExactly 'hack-browser-data.exe'
        $manifest['autoupdate']['bin'][0][1] | Should -BeExactly 'HackBrowserData'
    }

    It 'keeps the patchelf shim target aligned with the versioned download filename' {
        $manifest = Get-ForwardManifest 'patchelf'
        $version = '9999.0.0'
        $url = Expand-ForwardTemplate $manifest['autoupdate']['architecture']['64bit']['url'] $version
        $bin = Expand-ForwardTemplate $manifest['autoupdate']['bin'][0][0] $version

        $bin | Should -BeExactly ([IO.Path]::GetFileName(([Uri]$url).AbsolutePath))
        $manifest['autoupdate']['bin'][0][1] | Should -BeExactly 'patchelf'
    }

    It 'aliases future MVEL downloads to the unchanged launcher filename' {
        $manifest = Get-ForwardManifest 'mvel2'
        $launcher = @($manifest['pre_install']) -join "`n"
        $file = [regex]::Match($launcher, 'mvel2-\d+(?:\.\d+)*\.Final\.jar').Value
        $file | Should -Not -BeNullOrEmpty
        $url = Expand-ForwardTemplate $manifest['autoupdate']['architecture']['64bit']['url'] '9999.0.0'

        ([Uri]$url).Fragment | Should -BeExactly "#/$file"
        ([Uri]$url).AbsolutePath | Should -Match 'mvel2-9999\.0\.0\.Final\.jar$'
    }

    It 'accepts the reviewed <App> migration through the real update policy' -ForEach @(
        @{ App = '3proxy' },
        @{ App = 'HackBrowserData' },
        @{ App = 'patchelf' },
        @{ App = 'mvel2' }
    ) {
        $before = Get-ForwardManifest $App
        $after = $before | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        $version = '9999.0.0'
        $after['version'] = $version
        $template = $before['autoupdate']['architecture']['64bit']
        $after['architecture']['64bit']['url'] = Expand-ForwardTemplate $template['url'] $version
        $after['architecture']['64bit']['hash'] = 'a' * 64
        if ($template.Contains('extract_dir')) {
            $after['architecture']['64bit']['extract_dir'] = Expand-ForwardTemplate $template['extract_dir'] $version
        }
        if ($before['autoupdate'].Contains('bin')) {
            $target = Expand-ForwardTemplate $before['autoupdate']['bin'][0][0] $version
            $after['bin'] = ,@($target, $before['autoupdate']['bin'][0][1])
        }

        $decision = Get-ManifestUpdateDecision -Before $before -After $after -ScoopHome $core

        $decision.Allowed | Should -BeTrue -Because $decision.Reason
    }

    It 'does not silently remove the historical xk6ea command during a layout migration' {
        $manifest = Get-ForwardManifest 'xk6'
        $configuration = Read-StrictJsonFile -Path (Join-Path $repositoryRoot '.github/maintenance-exceptions.json')
        $exception = @($configuration['manual'] | Where-Object { $_['app'] -ceq 'xk6' })

        $manifest['bin'] | Should -Contain 'xk6ea.exe'
        $exception.Count | Should -Be 1
        $exception[0]['reason'] | Should -Match 'xk6ea'
    }

    It 'keeps Spotlight revision releases distinguishable and correctly ordered' {
        $manifest = Get-ForwardManifest 'Spotlight-Downloader'
        $regex = [regex]::new($manifest['checkver']['regex'])
        $release = $regex.Match('v2.0.0')
        $revision = $regex.Match('v2.0.0-r1')
        $release.Success | Should -BeTrue
        $revision.Success | Should -BeTrue
        $releaseVersion = $release.Result($manifest['checkver']['replace'])
        $revisionVersion = $revision.Result($manifest['checkver']['replace'])

        $revisionVersion | Should -BeExactly '2.0.0-r1'
        $ordering = & {
            param($OldVersion, $NewVersion, $ScoopCore)
            Set-StrictMode -Off
            . (Join-Path $ScoopCore 'lib/core.ps1')
            . (Join-Path $ScoopCore 'lib/versions.ps1')
            Compare-Version -ReferenceVersion $OldVersion -DifferenceVersion $NewVersion
        } $releaseVersion $revisionVersion $core
        $ordering | Should -BeGreaterThan 0
        $url = Expand-ForwardTemplate $manifest['autoupdate']['architecture']['64bit']['url'] $revisionVersion
        $url | Should -BeExactly 'https://github.com/ORelio/Spotlight-Downloader/releases/download/v2.0.0-r1/SpotlightDL-v2.0.0-r1.zip'
    }
}
