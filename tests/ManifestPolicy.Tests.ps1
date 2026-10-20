#Requires -Version 7.2

BeforeAll {
    $script:PolicyModule = Join-Path $PSScriptRoot '../bin/manifest-policy.psm1'
    $script:PolicyFixtures = Join-Path $PSScriptRoot 'fixtures/policy'
    $script:PolicyScoopHome = if ($env:SCOOP_TEST_HOME) { $env:SCOOP_TEST_HOME } elseif ($env:SCOOP_HOME) { $env:SCOOP_HOME } else { Join-Path $env:USERPROFILE 'scoop/apps/scoop/current' }
    Import-Module $script:PolicyModule -Force -ErrorAction Stop

    function Get-PolicyFixture([string] $Name) {
        Read-StrictJsonFile -Path (Join-Path $script:PolicyFixtures "$Name.json")
    }

    function Get-PolicyFixtureDecision($Before, $After) {
        Get-ManifestUpdateDecision -Before $Before -After $After -ScoopHome $script:PolicyScoopHome
    }
}

Describe 'Public policy API' {
    It 'exports the singular asset enumeration command' {
        (Get-Module manifest-policy).ExportedFunctions.Keys | Should -Contain 'Get-ManifestAsset'
    }
}

Describe 'Read-StrictJsonFile' {
    It 'returns a dictionary without losing Unicode, booleans, nulls or array shape' {
        $path = Join-Path $TestDrive 'literal[1].json'
        $expectedName = -join @([char] 0x5DE5, [char] 0x5177, ' ', [char] 0xE9)
        $json = @{ name = $expectedName; enabled = $false; empty = $null; single = @('one'); nested = @{ value = 1 } } | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText($path, $json)
        $actual = Read-StrictJsonFile -Path $path
        $actual | Should -BeOfType ([Collections.IDictionary])
        $actual.name | Should -BeExactly $expectedName
        $actual.enabled | Should -BeFalse
        $actual.Contains('empty') | Should -BeTrue
        $actual.empty | Should -BeNullOrEmpty
        ($actual.single -is [array]) | Should -BeTrue
        $actual.single.Count | Should -Be 1
        $actual.nested.value | Should -Be 1
    }

    It 'rejects invalid JSON or an invalid root: <Name>' -ForEach @(
        @{ Name = 'duplicate'; Json = '{"version":"1","version":"2"}' }
        @{ Name = 'case collision'; Json = '{"version":"1","Version":"2"}' }
        @{ Name = 'nested collision'; Json = '{"x":[{"url":1,"URL":2}]}' }
        @{ Name = 'escaped duplicate'; Json = '{"a":1,"\u0061":2}' }
        @{ Name = 'trailing comma'; Json = '{"version":"1",}' }
        @{ Name = 'comment'; Json = '{/* nope */"version":"1"}' }
        @{ Name = 'trailing JSON'; Json = '{"version":"1"} {}' }
        @{ Name = 'malformed'; Json = '{"version":' }
        @{ Name = 'array'; Json = '[]' }
        @{ Name = 'null'; Json = 'null' }
        @{ Name = 'string'; Json = '"manifest"' }
        @{ Name = 'empty'; Json = '' }
    ) {
        $path = Join-Path $TestDrive 'invalid.json'
        [IO.File]::WriteAllText($path, $Json)
        { Read-StrictJsonFile -Path $path } | Should -Throw
    }

    It 'rejects missing files and directories' {
        { Read-StrictJsonFile -Path (Join-Path $TestDrive 'missing.json') } | Should -Throw
        { Read-StrictJsonFile -Path $TestDrive } | Should -Throw
        { Read-StrictJsonFile -Path "${TestDrive}/value.json:stream" } | Should -Throw
    }

    It 'rejects a manifest reached through a junction' {
        $target = New-Item -Path (Join-Path $TestDrive 'target') -ItemType Directory
        [IO.File]::WriteAllText((Join-Path $target.FullName 'app.json'), '{}')
        $link = New-Item -Path (Join-Path $TestDrive 'junction') -ItemType Junction -Target $target.FullName
        { Read-StrictJsonFile -Path (Join-Path $link.FullName 'app.json') } | Should -Throw '*reparse*'
    }

    It 'handles ten thousand data items without changing their order' {
        $path = Join-Path $TestDrive 'large.json'
        [IO.File]::WriteAllText($path, (@{ values = @(0..9999) } | ConvertTo-Json -Compress))
        $actual = Read-StrictJsonFile -Path $path
        $actual.values.Count | Should -Be 10000
        $actual.values[0] | Should -Be 0
        $actual.values[9999] | Should -Be 9999
    }
}

Describe 'Assert-SafeAppName' {
    It 'accepts supported names without changing their case: <App>' -ForEach @(
        @{ App = 'DesktopOK' }, @{ App = 'cpa-manager-plus' }, @{ App = 'app_1.2+test' }
    ) {
        @(Assert-SafeAppName -App $App).Count | Should -Be 0
    }

    It 'rejects an unsafe basename: <Name>' -ForEach @(
        @{ Name = 'empty'; App = '' }, @{ Name = 'null'; App = $null }
        @{ Name = 'slash'; App = 'a/b' }, @{ Name = 'backslash'; App = 'a\b' }
        @{ Name = 'parent'; App = '..' }, @{ Name = 'dot'; App = '.' }
        @{ Name = 'traversal'; App = '../app' }, @{ Name = 'drive'; App = 'C:app' }
        @{ Name = 'UNC'; App = '\\server\app' }, @{ Name = 'space'; App = 'app name' }
        @{ Name = 'newline'; App = "app`nname" }, @{ Name = 'stream'; App = 'app:stream' }
        @{ Name = 'trailing dot'; App = 'app.' }, @{ Name = 'device'; App = 'CON' }
        @{ Name = 'invalid type'; App = @('app', 'other') }
    ) {
        { Assert-SafeAppName -App $App } | Should -Throw
    }
}

Describe 'Get-ManifestMaintenanceState' {
    It 'reports field coverage without claiming live correctness: <Expected>' -ForEach @(
        @{ Manifest = @{}; Expected = 'manual' }
        @{ Manifest = @{ checkver = 'github' }; Expected = 'missing-autoupdate' }
        @{ Manifest = @{ autoupdate = @{} }; Expected = 'missing-checkver' }
        @{ Manifest = @{ checkver = ''; autoupdate = @{} }; Expected = 'configured' }
        @{ Manifest = @{ checkver = @{ url = 'https://example.com' }; autoupdate = @{ url = 'https://example.com/$version.zip' } }; Expected = 'configured' }
    ) {
        Get-ManifestMaintenanceState -Manifest $Manifest | Should -BeExactly $Expected
    }

    It 'fails explicitly on wrongly typed fields: <Name>' -ForEach @(
        @{ Name = 'null checkver'; Manifest = @{ checkver = $null } }
        @{ Name = 'numeric checkver'; Manifest = @{ checkver = 12 } }
        @{ Name = 'array checkver'; Manifest = @{ checkver = @('github') } }
        @{ Name = 'null autoupdate'; Manifest = @{ autoupdate = $null } }
        @{ Name = 'string autoupdate'; Manifest = @{ autoupdate = 'url' } }
    ) {
        { Get-ManifestMaintenanceState -Manifest $Manifest } | Should -Throw
    }
}

Describe 'Get-ManifestAsset' {
    It 'returns one concrete root asset' {
        $assets = @(Get-ManifestAsset -Manifest (Get-PolicyFixture 'root-after'))
        $assets.Count | Should -Be 1
        $assets[0].Architecture | Should -BeExactly 'root'
        $assets[0].Url | Should -BeExactly 'https://example.com/tool/v1.3.0/tool.zip#/tool.zip'
        $assets[0].Hash | Should -BeExactly ('b' * 64)
    }

    It 'covers every declared architecture and honors independent root inheritance' {
        $manifest = Get-PolicyFixture 'multi-after'
        $snapshot = $manifest | ConvertTo-Json -Depth 30 -Compress
        $assets = @(Get-ManifestAsset -Manifest $manifest)
        $assets.Count | Should -Be 6
        @($assets | Where-Object Architecture -EQ '32bit').Count | Should -Be 2
        @($assets | Where-Object Architecture -EQ '64bit').Count | Should -Be 2
        @($assets | Where-Object Architecture -EQ 'arm64').Count | Should -Be 2
        ($assets | Where-Object Architecture -EQ 'arm64')[0].Hash | Should -BeExactly ('e' * 64)
        ($manifest | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $snapshot
    }

    It 'does not emit partial assets before a later architecture fails validation' {
        $manifest = Get-PolicyFixture 'multi-after'
        $manifest.architecture.arm64.hash = @('skip', ('e' * 64))
        $emitted = [Collections.Generic.List[object]]::new()
        { Get-ManifestAsset -Manifest $manifest | ForEach-Object { $emitted.Add($_) } } | Should -Throw
        $emitted.Count | Should -Be 0
    }

    It 'accepts an explicit SHA256 prefix and keeps single-element arrays' {
        $manifest = @{ url = @('https://example.com/a.zip'); hash = @('sha256:' + ('A' * 64)) }
        $assets = @(Get-ManifestAsset -Manifest $manifest)
        $assets.Count | Should -Be 1
        $assets[0].Hash | Should -BeExactly ('sha256:' + ('A' * 64))
    }

    It 'rejects incomplete, unsafe or skipped assets: <Name>' -ForEach @(
        @{ Name = 'missing URL'; Manifest = @{ hash = ('a' * 64) } }
        @{ Name = 'missing hash'; Manifest = @{ url = 'https://example.com/a.zip' } }
        @{ Name = 'empty URLs'; Manifest = @{ url = @(); hash = @() } }
        @{ Name = 'empty string URL'; Manifest = @{ url = ''; hash = ('a' * 64) } }
        @{ Name = 'null hash'; Manifest = @{ url = 'https://example.com/a.zip'; hash = $null } }
        @{ Name = 'count mismatch'; Manifest = @{ url = @('https://example.com/a.zip', 'https://example.com/b.zip'); hash = ('a' * 64) } }
        @{ Name = 'skip'; Manifest = @{ url = 'https://example.com/a.zip'; hash = 'skip' } }
        @{ Name = 'MD5'; Manifest = @{ url = 'https://example.com/a.zip'; hash = ('a' * 32) } }
        @{ Name = 'fake SHA256 prefix'; Manifest = @{ url = 'https://example.com/a.zip'; hash = ('sha256:' + ('a' * 40)) } }
        @{ Name = 'HTTP'; Manifest = @{ url = 'http://example.com/a.zip'; hash = ('a' * 64) } }
        @{ Name = 'relative URL'; Manifest = @{ url = '/a.zip'; hash = ('a' * 64) } }
        @{ Name = 'userinfo'; Manifest = @{ url = 'https://trusted.example@evil.example/a.zip'; hash = ('a' * 64) } }
        @{ Name = 'backslash URL'; Manifest = @{ url = 'https://example.com\evil/a.zip'; hash = ('a' * 64) } }
        @{ Name = 'placeholder'; Manifest = @{ url = 'https://example.com/$version/a.zip'; hash = ('a' * 64) } }
        @{ Name = 'numeric URL'; Manifest = @{ url = 12; hash = ('a' * 64) } }
        @{ Name = 'nested URL array'; Manifest = @{ url = @(@('https://example.com/a.zip', 'https://example.com/b.zip')); hash = ('a' * 64) } }
        @{ Name = 'empty architectures'; Manifest = @{ architecture = @{}; url = 'https://example.com/a.zip'; hash = ('a' * 64) } }
        @{ Name = 'unknown architecture'; Manifest = @{ architecture = @{ x86 = @{ url = 'https://example.com/a.zip'; hash = ('a' * 64) } } } }
        @{ Name = 'reserved root architecture marker'; Manifest = @{ url = 'https://example.com/a.zip'; hash = ('a' * 64); architecture = @{ root = @{ url = 'http://example.com/unsafe.zip'; hash = 'skip' } } } }
        @{ Name = 'wrong architecture type'; Manifest = @{ architecture = @('64bit') } }
        @{ Name = 'wrong architecture block'; Manifest = @{ architecture = @{ '64bit' = 'bad' } } }
        @{ Name = 'one invalid architecture'; Manifest = @{ architecture = @{ '32bit' = @{ url = 'https://example.com/a.zip'; hash = ('a' * 64) }; arm64 = @{ url = 'https://example.com/arm.zip'; hash = 'skip' } } } }
    ) {
        { Get-ManifestAsset -Manifest $Manifest } | Should -Throw
    }
}

Describe 'Get-ManifestUpdateDecision with real Scoop helpers' {
    It 'allows an exact root update including versioned extraction, bins and shortcuts' {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        $snapshots = @($before, $after) | ConvertTo-Json -Depth 30 -Compress
        $decision = Get-PolicyFixtureDecision $before $after
        $decision.Allowed | Should -BeTrue
        $decision.Reason | Should -Not -BeNullOrEmpty
        $decision.Assets.Count | Should -Be 1
        ($decision.Assets -is [array]) | Should -BeTrue
        (@($before, $after) | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $snapshots
    }

    It 'allows all architecture/array assets with inherited templates' {
        $decision = Get-PolicyFixtureDecision (Get-PolicyFixture 'multi-before') (Get-PolicyFixture 'multi-after')
        $decision.Allowed | Should -BeTrue
        $decision.Assets.Count | Should -Be 6
    }

    It 'allows stable URLs and implicitly downloaded hashes' {
        $before = @{ version = '1.0'; url = 'https://example.com/latest.zip'; hash = ('a' * 64); checkver = 'github'; autoupdate = @{ url = 'https://example.com/latest.zip' } }
        $after = @{ version = '1.1'; url = 'https://example.com/latest.zip'; hash = ('b' * 64); checkver = 'github'; autoupdate = @{ url = 'https://example.com/latest.zip' } }
        (Get-PolicyFixtureDecision $before $after).Allowed | Should -BeTrue
    }

    It 'uses Scoop substitutions rather than ad-hoc version parsing: <Variable>' -ForEach @(
        @{ Variable = '$underscoreVersion'; Old = '1_2_3'; New = '1_3_0' }
        @{ Variable = '$dashVersion'; Old = '1-2-3'; New = '1-3-0' }
        @{ Variable = '$cleanVersion'; Old = '123'; New = '130' }
        @{ Variable = '$minorVersion'; Old = '2'; New = '3' }
        @{ Variable = '$matchHead'; Old = '1.2.3'; New = '1.3.0' }
    ) {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        $before.autoupdate.url = $after.autoupdate.url = 'https://example.com/' + $Variable + '/tool.zip'
        $before.url = "https://example.com/$Old/tool.zip"
        $after.url = "https://example.com/$New/tool.zip"
        (Get-PolicyFixtureDecision $before $after).Allowed | Should -BeTrue
    }

    It 'rejects equal versions, downgrades and untrusted version text: <Version>' -ForEach @(
        @{ Version = '1.2.3' }, @{ Version = '1.0.0' }, @{ Version = '../evil' }
        @{ Version = '1.3.0@evil.example' }, @{ Version = '1.3.0?query' }, @{ Version = '' }
        @{ Version = 42 }, @{ Version = '999999999999999999999999999999999999.0' }
    ) {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        $after.version = $Version
        $decision = Get-PolicyFixtureDecision $before $after
        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match '(?i)version|upgrade'
        $decision.Assets.Count | Should -Be 0
    }

    It 'rejects a change outside the supported version surface: <Field>' -ForEach @(
        @{ Field = 'pre_install'; Value = 'throw "never run"' }
        @{ Field = 'post_install'; Value = 'throw "never run"' }
        @{ Field = 'installer'; Value = @{ script = 'throw "never run"' } }
        @{ Field = 'depends'; Value = 'other' }
        @{ Field = 'env_set'; Value = @{ PATH = 'malicious' } }
        @{ Field = 'persist'; Value = 'data' }
        @{ Field = 'description'; Value = 'unreviewed change' }
        @{ Field = 'homepage'; Value = 'https://evil.example' }
        @{ Field = 'license'; Value = 'GPL-3.0-only' }
        @{ Field = 'checkver'; Value = @{ script = 'throw "never run"' } }
        @{ Field = 'autoupdate'; Value = @{ url = 'https://evil.example/$version.zip' } }
        @{ Field = 'unknown'; Value = 'unreviewed' }
    ) {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        $after[$Field] = $Value
        $decision = Get-PolicyFixtureDecision $before $after
        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match ([regex]::Escape($Field))
    }

    It 'rejects forbidden scope, template and structure cases: <Name>' -ForEach @(
        @{ Name = 'unexplained URL'; Change = { param($pair) $pair.After.url = 'https://example.com/unrelated.zip' }; Reason = 'url|template' }
        @{ Name = 'origin injection'; Change = { param($pair) $pair.After.url = 'https://evil.example/tool.zip' }; Reason = 'url|origin|template' }
        @{ Name = 'variable authority'; Change = { param($pair) $pair.Before.autoupdate.url = $pair.After.autoupdate.url = 'https://$majorVersion.example.com/tool.zip'; $pair.Before.url = $pair.After.url = 'https://1.example.com/tool.zip' }; Reason = 'origin|authority' }
        @{ Name = 'missing template'; Change = { param($pair) $pair.Before.autoupdate.Remove('url'); $pair.After.autoupdate.Remove('url') }; Reason = 'url|template' }
        @{ Name = 'capture unavailable'; Change = { param($pair) $pair.Before.autoupdate.url = $pair.After.autoupdate.url = 'https://example.com/$matchAsset/tool.zip' }; Reason = 'matchAsset|capture|substitution' }
        @{ Name = 'unknown substitution'; Change = { param($pair) $pair.Before.autoupdate.url = $pair.After.autoupdate.url = 'https://example.com/$unknown/tool.zip' }; Reason = 'unknown|substitution' }
        @{ Name = 'hash capture unavailable'; Change = { param($pair) $pair.Before.autoupdate.hash.url = $pair.After.autoupdate.hash.url = 'https://example.com/$matchHash/checksums.txt' }; Reason = 'matchHash|capture|substitution' }
        @{ Name = 'unsupported template field'; Change = { param($pair) $pair.Before.autoupdate.env_set = $pair.After.autoupdate.env_set = @{ TOOL = '$version' } }; Reason = 'Unsupported.*env_set' }
        @{ Name = 'unknown hash extraction field'; Change = { param($pair) $pair.Before.autoupdate.hash.bad = $pair.After.autoupdate.hash.bad = 'value' }; Reason = 'Unsupported.*hash' }
        @{ Name = 'scalar to array'; Change = { param($pair) $pair.After.url = @($pair.After.url) }; Reason = 'shape|structure|array' }
        @{ Name = 'removed key'; Change = { param($pair) $pair.After.Remove('description') }; Reason = 'description|structure' }
        @{ Name = 'array reordered'; Change = { param($pair) $pair.After.bin[0] = @('tool', 'tool-1.3.0/tool.exe') }; Reason = 'bin|template' }
        @{ Name = 'extra shortcut'; Change = { param($pair) $pair.After.shortcuts += ,@('other.exe', 'Other') }; Reason = 'shortcuts|array|shape' }
        @{ Name = 'unsafe extraction'; Change = { param($pair) $pair.Before.autoupdate.extract_dir = $pair.After.autoupdate.extract_dir = '../tool-$version'; $pair.Before.extract_dir = '../tool-1.2.3'; $pair.After.extract_dir = '../tool-1.3.0' }; Reason = 'extract_dir|safe|relative|traversal' }
        @{ Name = 'absolute executable'; Change = { param($pair) $pair.Before.autoupdate.bin = $pair.After.autoupdate.bin = 'C:\tool-$version.exe'; $pair.Before.bin = 'C:\tool-1.2.3.exe'; $pair.After.bin = 'C:\tool-1.3.0.exe' }; Reason = 'bin|safe|relative|absolute' }
        @{ Name = 'Windows-normalized traversal'; Change = { param($pair) $pair.Before.autoupdate.extract_dir = $pair.After.autoupdate.extract_dir = '.. /tool-$version'; $pair.Before.extract_dir = '.. /tool-1.2.3'; $pair.After.extract_dir = '.. /tool-1.3.0' }; Reason = 'extract_dir|safe|relative|traversal' }
        @{ Name = 'Windows device path'; Change = { param($pair) $pair.Before.autoupdate.extract_dir = $pair.After.autoupdate.extract_dir = 'CON/tool-$version'; $pair.Before.extract_dir = 'CON/tool-1.2.3'; $pair.After.extract_dir = 'CON/tool-1.3.0' }; Reason = 'extract_dir|safe|relative' }
        @{ Name = 'skip candidate'; Change = { param($pair) $pair.After.hash = 'skip' }; Reason = 'hash|SHA256' }
        @{ Name = 'empty update template'; Change = { param($pair) $pair.Before.autoupdate = $pair.After.autoupdate = @{} }; Reason = 'url|template' }
        @{ Name = 'nightly baseline'; Change = { param($pair) $pair.Before.version = 'nightly' }; Reason = 'version|nightly' }
    ) {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        & $Change ([pscustomobject]@{ Before = $before; After = $after })
        $decision = Get-PolicyFixtureDecision $before $after
        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match $Reason
        $decision.Assets.Count | Should -Be 0
    }

    It 'rejects architecture removal, addition, array reorder and partial validation: <Name>' -ForEach @(
        @{ Name = 'removed'; Change = { param($pair) $pair.After.architecture.Remove('arm64') } }
        @{ Name = 'added'; Change = { param($pair) $pair.After.architecture.mips = @{} } }
        @{ Name = 'reordered'; Change = { param($pair) $pair.After.architecture.'64bit'.url = @($pair.After.architecture.'64bit'.url[1], $pair.After.architecture.'64bit'.url[0]) } }
        @{ Name = 'invalid hash'; Change = { param($pair) $pair.After.architecture.arm64.hash = @('skip', ('e' * 64)) } }
        @{ Name = 'architecture hook'; Change = { param($pair) $pair.After.architecture.'64bit'.pre_install = 'throw "never run"' } }
    ) {
        $before = Get-PolicyFixture 'multi-before'
        $after = Get-PolicyFixture 'multi-after'
        & $Change ([pscustomobject]@{ Before = $before; After = $after })
        (Get-PolicyFixtureDecision $before $after).Allowed | Should -BeFalse
    }

    It 'does not execute unchanged install or version-discovery hooks' {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        $before.pre_install = $after.pre_install = 'throw "install hook executed"'
        $before.checkver = $after.checkver = @{ script = 'throw "checkver hook executed"' }
        (Get-PolicyFixtureDecision $before $after).Allowed | Should -BeTrue
    }

    It 'rejects environment changes hidden behind dictionary member-name collisions' {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        $before.env_set = @{ Keys = 'PATH'; Count = '3'; PATH = 'same'; TOOL = 'before' }
        $after.env_set = @{ Keys = 'PATH'; Count = '3'; PATH = 'same'; TOOL = 'after' }
        $decision = Get-PolicyFixtureDecision $before $after
        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match 'env_set'
    }

    It 'does not impose schema validity on untouched baseline metadata' {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        $before.license = $after.license = ''
        (Get-PolicyFixtureDecision $before $after).Allowed | Should -BeTrue
    }

    It 'fails closed for missing trusted Scoop libraries' {
        $decision = Get-ManifestUpdateDecision -Before (Get-PolicyFixture 'root-before') -After (Get-PolicyFixture 'root-after') -ScoopHome $TestDrive
        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match '(?i)Scoop|versions|missing|exist'
    }
}

Describe 'Trusted forward-template migrations' {
    It 'allows a reviewed historical <Field> literal to differ from the unchanged template' -ForEach @(
        @{ Field = 'url'; Change = { param($manifest) $manifest.url = 'https://example.com/legacy/tool.zip' } }
        @{ Field = 'extract_dir'; Change = { param($manifest) $manifest.extract_dir = 'legacy-tool' } }
        @{ Field = 'bin'; Change = { param($manifest) $manifest.bin[0][0] = 'legacy-tool.exe' } }
        @{ Field = 'shortcuts'; Change = { param($manifest) $manifest.shortcuts[0][0] = 'legacy-tool.exe'; $manifest.shortcuts[0][1] = 'Legacy Tool' } }
    ) {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        & $Change $before
        $snapshot = @($before, $after) | ConvertTo-Json -Depth 30 -Compress

        $decision = Get-PolicyFixtureDecision $before $after

        $decision.Allowed | Should -BeTrue -Because $decision.Reason
        $decision.Assets.Count | Should -Be 1
        (@($before, $after) | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $snapshot
    }

    It 'allows only a safely relative root extraction addition explained by the unchanged template' {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        $before.Remove('extract_dir')
        $before.autoupdate.extract_dir = $after.autoupdate.extract_dir = 'tool'
        $after.extract_dir = 'tool'

        $decision = Get-PolicyFixtureDecision $before $after

        $decision.Allowed | Should -BeTrue -Because $decision.Reason
        $before.Contains('extract_dir') | Should -BeFalse
        $after.extract_dir | Should -BeExactly 'tool'
    }

    It 'allows a templated scalar extraction addition inside an existing architecture' {
        $before = Get-PolicyFixture 'multi-before'
        $after = Get-PolicyFixture 'multi-after'
        $before.autoupdate.architecture['32bit'] = @{ extract_dir = 'bundle-$version' }
        $after.autoupdate.architecture['32bit'] = @{ extract_dir = 'bundle-$version' }
        $after.architecture['32bit'].extract_dir = "bundle-$($after.version)"

        $decision = Get-PolicyFixtureDecision $before $after

        $decision.Allowed | Should -BeTrue -Because $decision.Reason
        $decision.Assets.Count | Should -Be 6
        $before.architecture['32bit'].Contains('extract_dir') | Should -BeFalse
    }

    It 'rejects structural or untrusted changes during a forward migration: <Name>' -ForEach @(
        @{ Name = 'untemplated extraction addition'; Change = { param($pair) $pair.Before.Remove('extract_dir'); $pair.Before.autoupdate.Remove('extract_dir'); $pair.After.autoupdate.Remove('extract_dir') }; Reason = 'extract_dir|template' }
        @{ Name = 'mismatched extraction addition'; Change = { param($pair) $pair.Before.Remove('extract_dir'); $pair.After.extract_dir = 'unexplained' }; Reason = 'extract_dir|template' }
        @{ Name = 'array extraction addition'; Change = { param($pair) $pair.Before.Remove('extract_dir'); $pair.Before.autoupdate.extract_dir = $pair.After.autoupdate.extract_dir = @('tool-$version'); $pair.After.extract_dir = @('tool-1.3.0') }; Reason = 'extract_dir|structure|shape' }
        @{ Name = 'null extraction addition'; Change = { param($pair) $pair.Before.Remove('extract_dir'); $pair.After.extract_dir = $null }; Reason = 'extract_dir|structure|shape' }
        @{ Name = 'object extraction addition'; Change = { param($pair) $pair.Before.Remove('extract_dir'); $pair.After.extract_dir = @{ path = 'tool' } }; Reason = 'extract_dir|structure|shape' }
        @{ Name = 'extraction deletion'; Change = { param($pair) $pair.After.Remove('extract_dir') }; Reason = 'extract_dir|structure' }
        @{ Name = 'arbitrary metadata addition'; Change = { param($pair) $pair.After.notes = 'unreviewed' }; Reason = 'notes|structure' }
        @{ Name = 'metadata deletion'; Change = { param($pair) $pair.After.Remove('description') }; Reason = 'description|structure' }
        @{ Name = 'template tampering'; Change = { param($pair) $pair.Before.Remove('extract_dir'); $pair.After.autoupdate.extract_dir = 'unreviewed' }; Reason = 'autoupdate' }
        @{ Name = 'bin addition despite template'; Change = { param($pair) $pair.Before.Remove('bin') }; Reason = 'bin|structure' }
        @{ Name = 'shortcut addition despite template'; Change = { param($pair) $pair.Before.Remove('shortcuts') }; Reason = 'shortcuts|structure' }
        @{ Name = 'URL addition despite template'; Change = { param($pair) $pair.Before.Remove('url') }; Reason = 'url|structure' }
        @{ Name = 'hash addition'; Change = { param($pair) $pair.Before.Remove('hash') }; Reason = 'hash|structure' }
        @{ Name = 'bin shrink despite shorter trusted template'; Change = { param($pair) $pair.Before.autoupdate.bin = $pair.After.autoupdate.bin = ,@('tool-$version/tool.exe'); $pair.After.bin = ,@('tool-1.3.0/tool.exe') }; Reason = 'bin|array|shape' }
        @{ Name = 'shortcut shrink despite shorter trusted template'; Change = { param($pair) $pair.Before.autoupdate.shortcuts = $pair.After.autoupdate.shortcuts = ,@('tool-$version/tool.exe'); $pair.After.shortcuts = ,@('tool-1.3.0/tool.exe') }; Reason = 'shortcuts|array|shape' }
        @{ Name = 'metadata change with historical baseline'; Change = { param($pair) $pair.Before.url = 'https://example.com/legacy.zip'; $pair.After.description = 'unreviewed' }; Reason = 'description' }
        @{ Name = 'unexplained alias change'; Change = { param($pair) $pair.Before.bin[0][0] = 'legacy.exe'; $pair.After.bin[0][1] = 'unreviewed' }; Reason = 'bin|template' }
    ) {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        & $Change ([pscustomobject]@{ Before = $before; After = $after })

        $decision = Get-PolicyFixtureDecision $before $after

        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match $Reason
        $decision.Assets.Count | Should -Be 0
    }

    It 'rejects an extraction addition backed only by a different architecture template' {
        $before = Get-PolicyFixture 'multi-before'
        $after = Get-PolicyFixture 'multi-after'
        $after.architecture['32bit'].extract_dir = $after.architecture['64bit'].extract_dir[0]

        $decision = Get-PolicyFixtureDecision $before $after

        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match 'architecture.32bit.extract_dir|template'
        $decision.Assets.Count | Should -Be 0
    }

    It 'rejects changes to existing scripts during an otherwise trusted layout migration' {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        $before.bin[0][0] = 'legacy.exe'
        $before.pre_install = 'throw "never run baseline hook"'
        $after.pre_install = 'throw "never run candidate hook"'

        $decision = Get-PolicyFixtureDecision $before $after

        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match 'pre_install'
        $decision.Assets.Count | Should -Be 0
    }

    It 'rejects an unsafe added extraction path even when the template explains it: <Name>' -ForEach @(
        @{ Name = 'empty'; Value = '' }
        @{ Name = 'parent traversal'; Value = '../tool' }
        @{ Name = 'Windows-normalized traversal'; Value = '.. /tool' }
        @{ Name = 'Windows device'; Value = 'CON/tool' }
        @{ Name = 'absolute drive'; Value = 'C:\tool' }
        @{ Name = 'UNC'; Value = '\\server\tool' }
        @{ Name = 'root relative'; Value = '/tool' }
        @{ Name = 'trailing dot'; Value = 'tool.' }
        @{ Name = 'alternate stream'; Value = 'tool:stream' }
        @{ Name = 'unresolved capture'; Value = 'tool-$matchAsset' }
        @{ Name = 'expression injection'; Value = 'tool-$(throw "never execute")' }
    ) {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        $before.Remove('extract_dir')
        $before.autoupdate.extract_dir = $after.autoupdate.extract_dir = $Value
        $after.extract_dir = $Value

        $decision = Get-PolicyFixtureDecision $before $after

        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match 'extract_dir|safe|relative|substitution'
        $decision.Assets.Count | Should -Be 0
    }

    It 'still requires the exact new-version template output for <Field>' -ForEach @(
        @{ Field = 'url'; Change = { param($pair) $pair.Before.url = 'https://example.com/legacy.zip'; $pair.After.url = 'https://example.com/unexplained.zip' } }
        @{ Field = 'extract_dir'; Change = { param($pair) $pair.Before.extract_dir = 'legacy'; $pair.After.extract_dir = 'unexplained' } }
        @{ Field = 'bin'; Change = { param($pair) $pair.Before.bin[0][0] = 'legacy.exe'; $pair.After.bin[0][0] = 'unexplained.exe' } }
        @{ Field = 'shortcuts'; Change = { param($pair) $pair.Before.shortcuts[0][0] = 'legacy.exe'; $pair.After.shortcuts[0][0] = 'unexplained.exe' } }
    ) {
        $before = Get-PolicyFixture 'root-before'
        $after = Get-PolicyFixture 'root-after'
        & $Change ([pscustomobject]@{ Before = $before; After = $after })

        $decision = Get-PolicyFixtureDecision $before $after

        $decision.Allowed | Should -BeFalse
        $decision.Reason | Should -Match ([regex]::Escape($Field))
        $decision.Assets.Count | Should -Be 0
    }
}

Describe 'Assert-ManifestSchema external validator boundary' {
    BeforeEach {
        $script:FakeScoopHome = Join-Path $TestDrive 'scoop'
        $validatorDirectory = Join-Path $script:FakeScoopHome 'supporting/validator/bin'
        New-Item -Path $validatorDirectory -ItemType Directory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:FakeScoopHome 'schema.json'), '{}')
        foreach ($name in @('validator.exe', 'Scoop.Validator.dll', 'Newtonsoft.Json.dll', 'Newtonsoft.Json.Schema.dll')) {
            [IO.File]::WriteAllText((Join-Path $validatorDirectory $name), '')
        }
        Mock Invoke-PolicyValidator -ModuleName manifest-policy {
            [pscustomobject]@{ ExitCode = 0; Output = '- root-after.json validates against the schema!' }
        }
    }

    It 'accepts an affirmative zero-exit result without producing pipeline output' {
        @(Assert-ManifestSchema -Path (Join-Path $script:PolicyFixtures 'root-after.json') -ScoopHome $script:FakeScoopHome).Count | Should -Be 0
        Should -Invoke Invoke-PolicyValidator -ModuleName manifest-policy -Times 1 -Exactly -ParameterFilter {
            $Executable.EndsWith('validator.exe') -and $Schema.EndsWith('schema.json') -and $Manifest.EndsWith('root-after.json')
        }
    }

    It 'rejects external failure, quota, skip and empty evidence: <Name>' -ForEach @(
        @{ Name = 'nonzero despite text'; Code = 1; Text = '- root-after.json validates against the schema!' }
        @{ Name = 'missing evidence'; Code = 0; Text = '' }
        @{ Name = 'wrong file'; Code = 0; Text = '- other.json validates against the schema!' }
        @{ Name = 'suffix collision'; Code = 0; Text = '- untrusted-root-after.json validates against the schema!' }
        @{ Name = 'quota'; Code = 0; Text = 'The free-quota limit of 1000 schema validations per hour has been reached.' }
        @{ Name = 'skipped'; Code = 0; Text = "Skipped schema validation`n- root-after.json validates against the schema!" }
    ) {
        Mock Invoke-PolicyValidator -ModuleName manifest-policy { [pscustomobject]@{ ExitCode = $Code; Output = $Text } }
        { Assert-ManifestSchema -Path (Join-Path $script:PolicyFixtures 'root-after.json') -ScoopHome $script:FakeScoopHome } | Should -Throw
    }

    It 'propagates a validator startup failure' {
        Mock Invoke-PolicyValidator -ModuleName manifest-policy { throw 'validator startup failed' }
        { Assert-ManifestSchema -Path (Join-Path $script:PolicyFixtures 'root-after.json') -ScoopHome $script:FakeScoopHome } | Should -Throw '*startup failed*'
    }

    It 'rejects a missing schema or validator instead of skipping' {
        { Assert-ManifestSchema -Path (Join-Path $script:PolicyFixtures 'root-after.json') -ScoopHome (Join-Path $TestDrive 'absent') } | Should -Throw
        Remove-Item -LiteralPath (Join-Path $script:FakeScoopHome 'supporting/validator/bin/validator.exe')
        { Assert-ManifestSchema -Path (Join-Path $script:PolicyFixtures 'root-after.json') -ScoopHome $script:FakeScoopHome } | Should -Throw
        Should -Invoke Invoke-PolicyValidator -ModuleName manifest-policy -Times 0 -Exactly
    }
}

Describe 'Assert-ManifestSchema real installed Scoop integration' {
    It 'runs the installed validator with its schema' {
        @(Assert-ManifestSchema -Path (Join-Path $script:PolicyFixtures 'root-after.json') -ScoopHome $script:PolicyScoopHome).Count | Should -Be 0
        @(Assert-ManifestSchema -Path (Join-Path $script:PolicyFixtures 'multi-after.json') -ScoopHome $script:PolicyScoopHome).Count | Should -Be 0
    }

    It 'rejects a syntactically valid manifest that fails the real schema' {
        $path = Join-Path $TestDrive 'schema-invalid.json'
        [IO.File]::WriteAllText($path, '{"version":"1.0","url":"https://example.com/a.zip","hash":"not-a-hash","unknown":true}')
        { Assert-ManifestSchema -Path $path -ScoopHome $script:PolicyScoopHome } | Should -Throw '*validator*'
    }
}

Describe 'Test-PublishAuthorization' {
    It 'requires the exact enabled value and a real boolean: <Name>' -ForEach @(
        @{ Name = 'authorized'; Enabled = 'true'; Publish = $true; Expected = $true }
        @{ Name = 'disabled'; Enabled = 'false'; Publish = $true; Expected = $false }
        @{ Name = 'not set'; Enabled = ''; Publish = $true; Expected = $false }
        @{ Name = 'uppercase'; Enabled = 'TRUE'; Publish = $true; Expected = $false }
        @{ Name = 'whitespace'; Enabled = ' true'; Publish = $true; Expected = $false }
        @{ Name = 'check only'; Enabled = 'true'; Publish = $false; Expected = $false }
        @{ Name = 'string true'; Enabled = 'true'; Publish = 'true'; Expected = $false }
        @{ Name = 'string false'; Enabled = 'true'; Publish = 'false'; Expected = $false }
        @{ Name = 'numeric'; Enabled = 'true'; Publish = 1; Expected = $false }
        @{ Name = 'null'; Enabled = 'true'; Publish = $null; Expected = $false }
        @{ Name = 'array'; Enabled = 'true'; Publish = @($true); Expected = $false }
    ) {
        Test-PublishAuthorization -Enabled $Enabled -Publish $Publish | Should -Be $Expected
    }
}
