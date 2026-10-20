BeforeAll {
    $binDirectory = Join-Path $PSScriptRoot '../bin'
    $originalActionOutput = $env:GITHUB_OUTPUT
    $originalStepSummary = $env:GITHUB_STEP_SUMMARY
    $env:GITHUB_OUTPUT = $null
    $env:GITHUB_STEP_SUMMARY = $null

    function Invoke-FixtureGit([string]$Repository, [string[]]$ArgumentList) {
        $output = & git -C $Repository -c user.name=Fixture -c user.email=fixture@example.test @ArgumentList 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $output" }
        [string]::Join("`n", @($output))
    }

    function New-FixtureRepository([string]$Directory) {
        New-Item -ItemType Directory -Path (Join-Path $Directory 'bucket') -Force | Out-Null
        $null = Invoke-FixtureGit $Directory @('init', '--template=', '--initial-branch=master')
        [IO.File]::WriteAllText((Join-Path $Directory 'bucket/app.json'), '{"version":"1"}')
    }

    function New-FixtureCommit([string]$Repository, [string]$Parent) {
        $null = Invoke-FixtureGit $Repository @('add', '--all')
        $tree = Invoke-FixtureGit $Repository @('write-tree')
        $arguments = @('commit-tree', $tree, '-m', 'test fixture')
        if ($Parent) { $arguments += @('-p', $Parent) }
        $sha = Invoke-FixtureGit $Repository $arguments
        $null = Invoke-FixtureGit $Repository @('update-ref', 'refs/heads/master', $sha)
        $sha
    }
}

Describe 'Official checker adapter' {
    It 'passes explicit checkver options without installing an app' {
        $core = Join-Path $TestDrive 'fake-core'
        $bucket = Join-Path $TestDrive 'fake-bucket'
        New-Item -ItemType Directory -Path (Join-Path $core 'bin'), $bucket -Force | Out-Null
        $script = @'
param([string]$App, [string]$Dir, [switch]$Update, [switch]$SkipUpdated, [switch]$ThrowError)
[pscustomobject]@{ app = $App; dir = $Dir; update = $Update.IsPresent; skip = $SkipUpdated.IsPresent } | ConvertTo-Json -Compress
'@
        [IO.File]::WriteAllText((Join-Path $core 'bin/checkver.ps1'), $script)

        $result = & (Join-Path $binDirectory 'checkver.ps1') -ScoopHome $core -Dir $bucket -App fixture -SkipUpdated |
            ConvertFrom-Json

        $result.app | Should -Be 'fixture'
        $result.dir | Should -Be ([IO.Path]::GetFullPath($bucket))
        $result.update | Should -BeFalse
        $result.skip | Should -BeTrue
    }

    It 'fails explicitly if the requested toolchain is missing' {
        { & (Join-Path $binDirectory 'checkver.ps1') -ScoopHome (Join-Path $TestDrive 'absent') } | Should -Throw
    }
}

Describe 'Changed-manifest discovery' {
    It 'finds modified manifests but excludes unrelated files' {
        $repository = Join-Path $TestDrive 'changes'
        New-FixtureRepository $repository
        $base = New-FixtureCommit $repository
        [IO.File]::WriteAllText((Join-Path $repository 'bucket/app.json'), '{"version":"2"}')
        [IO.File]::WriteAllText((Join-Path $repository 'README.md'), 'Unrelated change')
        $head = New-FixtureCommit $repository $base

        $json = & (Join-Path $binDirectory 'get-changed-manifests.ps1') -RepositoryDirectory $repository -BaseSha $base -HeadSha $head

        $json | Should -Be '["bucket/app.json"]'
    }

    It 'preserves the empty-array contract when there are no manifest changes' {
        $repository = Join-Path $TestDrive 'no-changes'
        New-FixtureRepository $repository
        $sha = New-FixtureCommit $repository

        $json = & (Join-Path $binDirectory 'get-changed-manifests.ps1') -RepositoryDirectory $repository -BaseSha $sha -HeadSha $sha

        $json | Should -Be '[]'
    }

    It 'rejects unsafe new filenames rather than silently ignoring their contents' {
        $repository = Join-Path $TestDrive 'unsafe-name'
        New-FixtureRepository $repository
        $base = New-FixtureCommit $repository
        [IO.File]::WriteAllText((Join-Path $repository 'bucket/bad name.json'), '{}')
        $head = New-FixtureCommit $repository $base

        { & (Join-Path $binDirectory 'get-changed-manifests.ps1') -RepositoryDirectory $repository -BaseSha $base -HeadSha $head } |
            Should -Throw
    }

    It 'rejects injected or nonexistent source refs instead of returning no changes' {
        $repository = Join-Path $TestDrive 'invalid-ref'
        New-FixtureRepository $repository
        $head = New-FixtureCommit $repository

        { & (Join-Path $binDirectory 'get-changed-manifests.ps1') -RepositoryDirectory $repository -BaseSha '--invalid' -HeadSha $head } |
            Should -Throw
    }
}

Describe 'Offline maintenance commands' {
    It 'writes an inventory snapshot without changing the fixture manifest' {
        $bucket = Join-Path $TestDrive 'command-bucket'
        New-Item -ItemType Directory -Path $bucket | Out-Null
        $manifestPath = Join-Path $bucket 'fixture.json'
        [IO.File]::WriteAllText($manifestPath, '{"version":"1","description":"Fixture","homepage":"https://example.test","license":"MIT","url":"https://example.test/a.zip","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","checkver":"github","autoupdate":{"url":"https://example.test/a.zip"}}')
        $before = (Get-FileHash $manifestPath).Hash
        $output = Join-Path $TestDrive 'command-inventory'
        $exceptions = Join-Path $TestDrive 'empty-exceptions.json'
        [IO.File]::WriteAllText($exceptions, '{"schema":1,"manual":[]}')

        & (Join-Path $binDirectory 'maintenance.ps1') -Mode Inventory -BucketPath $bucket -ExceptionPath $exceptions `
            -OutputDirectory $output -BaseSha ('b' * 40) -RunId local -RunAttempt 1

        (Get-FileHash $manifestPath).Hash | Should -Be $before
        $selection = Get-Content (Join-Path $output 'selection.json') -Raw | ConvertFrom-Json
        @($selection.apps).Count | Should -Be 1
        $selection.apps[0] | Should -Be 'fixture'
        $selection.runId | Should -Be 'local'
    }

    It 'separates completed collection from the failed-source verdict' {
        $artifacts = Join-Path $TestDrive 'partial-artifacts'
        $appDirectory = Join-Path $artifacts 'scoop-updates-1-0/offline'
        New-Item -ItemType Directory -Path $appDirectory -Force | Out-Null
        $base = 'b' * 40
        $record = @{ schema = 1; app = 'offline'; status = 'unavailable'; reason = 'Source timeout'; baseSha = $base; runId = 'local'; runAttempt = '1'; sourceResolved = $false }
        [IO.File]::WriteAllText((Join-Path $appDirectory 'result.json'), ($record | ConvertTo-Json))
        $selection = Join-Path $TestDrive 'partial-selection.json'
        $snapshot = @{ schema = 1; baseSha = $base; runId = 'local'; runAttempt = '1'; apps = @('offline') }
        [IO.File]::WriteAllText($selection, ($snapshot | ConvertTo-Json))
        $output = Join-Path $TestDrive 'partial-report'

        & (Join-Path $binDirectory 'maintenance.ps1') -Mode Collect -ArtifactDirectory $artifacts `
            -SelectedAppsPath $selection -OutputDirectory $output -BaseSha $base -RunId local -RunAttempt 1

        $reportPath = Join-Path $output 'report.json'
        $report = Get-Content $reportPath -Raw | ConvertFrom-Json
        $report.Counts.unavailable | Should -Be 1
        { & (Join-Path $binDirectory 'maintenance.ps1') -Mode Verdict -CollectedReportPath $reportPath } | Should -Throw
    }

    It 'accepts a complete healthy source verdict without publishing anything' {
        $path = Join-Path $TestDrive 'healthy-verdict.json'
        [IO.File]::WriteAllText($path, '{"SelectedCount":1,"Counts":{"current":1,"updated":0,"unavailable":0,"manual":0,"failed":0},"Results":[{"app":"fixture","status":"current"}]}')

        { & (Join-Path $binDirectory 'maintenance.ps1') -Mode Verdict -CollectedReportPath $path } | Should -Not -Throw
    }

    It 'runs the pinned test entrypoint against a single test file' {
        $tinyTest = Join-Path $TestDrive 'single.Tests.ps1'
        [IO.File]::WriteAllText($tinyTest, "Describe 'Fixture' { It 'passes' { 1 | Should -Be 1 } }")
        $core = if ($env:SCOOP_HOME) { $env:SCOOP_HOME } else { Join-Path $env:USERPROFILE 'scoop/apps/scoop/current' }
        $results = Join-Path $TestDrive 'single-results'
        $hostPath = (Get-Process -Id $PID).Path

        $output = & $hostPath -NoLogo -NoProfile -File (Join-Path $binDirectory 'test.ps1') `
            -Path $tinyTest -ScoopHome $core -ResultDirectory $results 2>&1

        $LASTEXITCODE | Should -Be 0 -Because ([string]::Join(' ', @($output)))
        Test-Path -LiteralPath (Join-Path $results 'tests.xml') | Should -BeTrue
    }

    It 'refuses to overwrite an existing report directory' {
        $output = Join-Path $TestDrive 'existing-report'
        New-Item -ItemType Directory -Path $output | Out-Null
        [IO.File]::WriteAllText((Join-Path $output 'do-not-overwrite.json'), '{}')

        { & (Join-Path $binDirectory 'maintenance.ps1') -Mode Inventory -OutputDirectory $output -BaseSha ('b' * 40) } |
            Should -Throw
    }
}

AfterAll {
    $env:GITHUB_OUTPUT = $originalActionOutput
    $env:GITHUB_STEP_SUMMARY = $originalStepSummary
}
