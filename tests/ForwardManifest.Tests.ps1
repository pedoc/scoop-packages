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

    It 'ships capa as a standalone 64-bit Windows command from official versioned releases' {
        $manifest = Get-ForwardManifest 'capa'
        $version = $manifest['version']
        $url = "https://github.com/mandiant/capa/releases/download/v$version/capa-v$version-windows.zip"

        $manifest['architecture'].Count | Should -Be 1
        $manifest['architecture'].Contains('64bit') | Should -BeTrue
        $manifest['architecture']['64bit']['url'] | Should -BeExactly $url
        @($manifest['bin']).Count | Should -Be 1
        $manifest['bin'] | Should -BeExactly 'capa.exe'
        $manifest.Contains('depends') | Should -BeFalse
        $manifest.Contains('installer') | Should -BeFalse
        $manifest['license'] | Should -BeExactly 'Apache-2.0'
        $manifest['checkver'] | Should -BeExactly 'github'
        $expandedUrl = Expand-ForwardTemplate $manifest['autoupdate']['architecture']['64bit']['url'] $version
        $expandedUrl | Should -BeExactly $manifest['architecture']['64bit']['url']
    }

    It 'ships hcli as a standalone 64bit command from the official MIT project' {
        $manifest = Get-ForwardManifest 'hcli'

        $manifest['homepage'] | Should -BeExactly 'https://github.com/HexRaysSA/ida-hcli'
        $manifest['license'] | Should -BeExactly 'MIT'
        @($manifest['bin']).Count | Should -Be 1
        $manifest['bin'] | Should -BeExactly 'hcli.exe'
        foreach ($architectures in @($manifest['architecture'], $manifest['autoupdate']['architecture'])) {
            $architectures.Count | Should -Be 1
            $architectures.Contains('64bit') | Should -BeTrue
        }
        $manifest['checkver'] | Should -BeOfType [Collections.IDictionary]
        $manifest['checkver']['url'] | Should -BeExactly 'https://api.github.com/repos/HexRaysSA/ida-hcli/releases?per_page=100'
        foreach ($scope in @($manifest, $manifest['architecture']['64bit'])) {
            foreach ($field in @('depends', 'installer', 'pre_install', 'post_install', 'env_set', 'env_add_path')) {
                $scope.Contains($field) | Should -BeFalse -Because "hcli uses a standard Scoop shim without $field"
            }
        }
    }

    It 'selects the newest stable hcli tag while excluding dev, rc and post-tag variants' {
        $manifest = Get-ForwardManifest 'hcli'
        $manifest['checkver'] | Should -BeOfType [Collections.IDictionary]
        $regex = [regex]::new($manifest['checkver']['regex'])
        $releases = '[{"tag_name": "v0.28.0.dev1"}, {"tag_name": "v0.27.1"}, {"tag_name": "v0.27.0"}]'
        $release = $regex.Match($releases)

        $release.Success | Should -BeTrue
        $release.Groups[1].Value | Should -BeExactly '0.27.1'
        foreach ($tag in @('v0.28.0.dev1', 'v0.28.0-rc1', 'v0.28.0.post1', 'v0.28.0-post1')) {
            $regex.IsMatch('{"tag_name": "' + $tag + '"}') | Should -BeFalse -Because "$tag is not a stable release"
        }
    }

    It 'keeps hcli downloads on official versioned x86_64 releases with a stable shim filename' {
        $manifest = Get-ForwardManifest 'hcli'
        $version = $manifest['version']
        $asset = $manifest['architecture']['64bit']
        $template = $manifest['autoupdate']['architecture']['64bit']['url']
        $url = "https://github.com/HexRaysSA/ida-hcli/releases/download/v$version/hcli-windows-x86_64-$version.exe#/hcli.exe"

        $asset['url'] | Should -BeExactly $url
        $asset['hash'] | Should -BeOfType [string]
        $asset['hash'] | Should -Match '^[a-fA-F0-9]{64}$'
        (Expand-ForwardTemplate $template $version) | Should -BeExactly $url
        $futureVersion = '9999.0.0'
        $futureUrl = Expand-ForwardTemplate $template $futureVersion
        $futureUrl | Should -BeExactly "https://github.com/HexRaysSA/ida-hcli/releases/download/v$futureVersion/hcli-windows-x86_64-$futureVersion.exe#/hcli.exe"
    }

    It 'accepts a future hcli 64bit update through the real update policy' {
        $before = Get-ForwardManifest 'hcli'
        $after = $before | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        $version = '9999.0.0'
        $after['version'] = $version
        $template = $before['autoupdate']['architecture']['64bit']
        $after['architecture']['64bit']['url'] = Expand-ForwardTemplate $template['url'] $version
        $after['architecture']['64bit']['hash'] = 'a' * 64

        $decision = Get-ManifestUpdateDecision -Before $before -After $after -ScoopHome $core

        $decision.Allowed | Should -BeTrue -Because $decision.Reason
        $decision.Assets.Count | Should -Be 1
    }

    It 'accepts the reviewed <App> migration through the real update policy' -ForEach @(
        @{ App = '3proxy' },
        @{ App = 'HackBrowserData' },
        @{ App = 'patchelf' },
        @{ App = 'mvel2' },
        @{ App = 'capa' }
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
