BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    $script:fixtureRoot = Join-Path $PSScriptRoot 'fixtures/worker'
    $script:scoopHome = if ($env:SCOOP_HOME) { $env:SCOOP_HOME } else { Join-Path $HOME 'scoop/apps/scoop/current' }
    Import-Module (Join-Path $script:repoRoot 'bin/update-worker.psm1') -Force -ErrorAction Stop
    $script:writeStockUpgrade = {
        param($Path, $Code)
        & {
            param($ManifestPath, $TrustedCode)
            Set-StrictMode -Off
            . (Join-Path $TrustedCode 'lib/core.ps1')
            . (Join-Path $TrustedCode 'lib/autoupdate.ps1')
            . (Join-Path $TrustedCode 'lib/manifest.ps1')
            . (Join-Path $TrustedCode 'lib/json.ps1')
            $manifest = [IO.File]::ReadAllText($ManifestPath) | ConvertFrom-Json
            $substitutions = Get-VersionSubstitution '2.0.0'
            $null = Update-ManifestProperty -Manifest $manifest -Property @('url', 'extract_dir', 'bin', 'shortcuts') -Version '2.0.0' -Substitutions $substitutions
            if ($manifest.hash) { $manifest.hash = 'b' * 64 }
            else { $manifest.architecture.PSObject.Properties | ForEach-Object { $_.Value.hash = 'b' * 64 } }
            [IO.File]::WriteAllLines($ManifestPath, (ConvertToPrettyJson $manifest))
        } $Path $Code
    }
}

Describe 'Pinned Scoop discovery evidence' {
    It 'requires exact positive source evidence before reporting the observed version' {
        $evidence = ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput "widget: 1.0.0`r`n"
        $evidence.Status | Should -Be 'resolved'
        $evidence.Version | Should -BeExactly '1.0.0'
        $evidence.SourceResolved | Should -BeTrue
    }

    It 'parses the pinned changed-version line' {
        $evidence = ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput "widget: 2.0.0 (scoop version is 1.0.0) autoupdate available`n"
        $evidence.Status | Should -Be 'resolved'
        $evidence.Version | Should -BeExactly '2.0.0'
    }

    It 'does not confuse exit-zero errors with current' -TestCases @(
        @{ Text = "widget: couldn't match '([\\d.]+)' in https://example.com`n"; Status = 'failed' },
        @{ Text = "widget: couldn't find '$.tag_name' in https://example.com`n"; Status = 'failed' },
        @{ Text = "widget: couldn't find new version in https://example.com`n"; Status = 'failed' },
        @{ Text = "widget: The remote server returned an error: (404) Not Found.`nURL https://example.com is not valid`n"; Status = 'unavailable' },
        @{ Text = "widget: The remote server returned an error: (429) Too Many Requests.`nURL https://example.com is not valid`n"; Status = 'unavailable' },
        @{ Text = "widget: API rate limit exceeded`n"; Status = 'unavailable' },
        @{ Text = "widget: couldn't retrieve content from https://example.com`n"; Status = 'unavailable' }
    ) {
        param($Text, $Status)
        $evidence = ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput $Text
        $evidence.Status | Should -Be $Status
        $evidence.SourceResolved | Should -BeFalse
    }

    It 'fails closed on empty, partial, other-app, and ambiguous output' -TestCases @(
        @{ Text = '' },
        @{ Text = 'widget: ' },
        @{ Text = 'widget: 2.0.0 (scoop version is' },
        @{ Text = "other: 1.0.0`n" },
        @{ Text = "widget: 1.0.0`nwidget: 2.0.0 (scoop version is 1.0.0) autoupdate available`n" },
        @{ Text = "widget: 1.0.0`nunknown diagnostic`n" },
        @{ Text = "widget: 2.0.0 (scoop version is 0.9.0) autoupdate available`n" },
        @{ Text = "widget: 2.0.0`n" },
        @{ Text = "widget: 1.0.0 (scoop version is 1.0.0) autoupdate available`n" },
        @{ Text = "widget: ../../payload`n" }
    ) {
        param($Text)
        $evidence = ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput $Text
        $evidence.Status | Should -Be 'failed'
    }

    It 'does not accept an unterminated or explicitly truncated success line' {
        (ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput 'widget: 1.0.0').Status | Should -Be 'failed'
        (ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput "widget: 1.0.0`n" -OutputTruncated).Status | Should -Be 'failed'
    }

    It 'preserves timeout and nonzero-exit failures' {
        (ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput '' -TimedOut).Status | Should -Be 'unavailable'
        (ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput "widget: 1.0.0`n" -ExitCode 7).Status | Should -Be 'failed'
        (ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput "widget: 1.0.0`n" -StandardError 'failure').Status | Should -Be 'failed'
    }

    It 'accepts only ANSI styling, not additional source-controlled lines' {
        $text = "`e[32mwidget: 1.0.0`e[0m`r`n"
        (ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput $text).Status | Should -Be 'resolved'
        $text = "widget: 1.0.0`nwidget: HTTP 403 forbidden`n"
        (ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput $text).Status | Should -Not -Be 'resolved'
    }

    It 'bounds and redacts diagnostics without evaluating source strings' {
        $previous = $env:GH_TOKEN
        try {
            $env:GH_TOKEN = 'offline-fixture-token'
            $text = "widget: source failed https://example.com/?token=secret offline-fixture-token `$(throw 'inert')`n" + ('x' * 6000)
            $evidence = ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput $text
            $evidence.Status | Should -Be 'failed'
            $evidence.Diagnostics | Should -Not -Match 'offline-fixture-token|token=secret'
            $evidence.Diagnostics | Should -Match '\[redacted\]'
            $evidence.Diagnostics.Length | Should -BeLessThan 4200
        } finally { $env:GH_TOKEN = $previous }
    }
}

Describe 'Bounded trusted worker process' {
    BeforeAll {
        $script:processFixture = Join-Path $script:fixtureRoot 'process.ps1'
        $script:pwshPath = Join-Path $PSHOME 'pwsh.exe'
    }

    It 'captures output and explicitly checks native exit codes' {
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:processFixture, '-Mode', 'success')
        $run = Invoke-WorkerProcess -FilePath $script:pwshPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -TimeoutSeconds 10
        $run.ExitCode | Should -Be 0
        $run.StandardOutput | Should -Match 'widget: 1.0.0'
        $run.TimedOut | Should -BeFalse
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:processFixture, '-Mode', 'error')
        $run = Invoke-WorkerProcess -FilePath $script:pwshPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -TimeoutSeconds 10
        $run.ExitCode | Should -Be 7
        $run.StandardError | Should -Match 'simulated child failure'
    }

    It 'retains the native launch error rather than a cleanup exception' {
        $failure = try {
            Invoke-WorkerProcess -FilePath (Join-Path $TestDrive 'missing-pwsh.exe') -ArgumentList @() -WorkingDirectory $PSScriptRoot -TimeoutSeconds 1
        } catch { $_.Exception.GetBaseException() }
        $failure | Should -BeOfType ([ComponentModel.Win32Exception])
    }

    It 'bounds captured output and stops an output-flooding child' {
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:processFixture, '-Mode', 'flood')
        $run = Invoke-WorkerProcess -FilePath $script:pwshPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -TimeoutSeconds 5 -MaxOutputChars 8192
        $run.OutputTruncated | Should -BeTrue
        $run.StandardOutput.Length | Should -BeLessOrEqual 8192
    }

    It 'kills the timed-out process tree and keeps diagnostics' {
        $marker = Join-Path $TestDrive 'child.pid'
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:processFixture, '-Mode', 'tree', '-MarkerPath', $marker)
        $run = Invoke-WorkerProcess -FilePath $script:pwshPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -TimeoutSeconds 3
        $run.TimedOut | Should -BeTrue
        $marker | Should -Exist
        $childId = [int] [IO.File]::ReadAllText($marker)
        Get-Process -Id $childId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'passes environment and paths as data and never loads a planted profile' {
        $cache = Join-Path $TestDrive 'download-cache'
        $null = New-Item -ItemType Directory -Path $cache
        Set-Content -LiteralPath (Join-Path $cache 'profile.ps1') -Value '$global:WorkerProfileLoaded = $true'
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:processFixture, '-Mode', 'environment')
        $environment = @{ SCOOP_CACHE = $cache; WORKER_TEST_MARKER = '$(throw "never execute")'; PSModulePath = '' }
        $run = Invoke-WorkerProcess -FilePath $script:pwshPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -Environment $environment -TimeoutSeconds 10
        $observed = $run.StandardOutput | ConvertFrom-Json
        $observed.cwd | Should -Be ([IO.Path]::GetFullPath($PSScriptRoot))
        $observed.cache | Should -Be $cache
        $observed.marker | Should -BeExactly '$(throw "never execute")'
        $observed.profileLoaded | Should -BeFalse
    }
}

Describe 'Isolated manifest update result' {
    BeforeEach {
        $script:caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:caseRoot
        $script:inputPath = Join-Path $script:caseRoot 'widget.json'
        $script:outputPath = Join-Path $script:caseRoot 'output'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'current.json') -Destination $script:inputPath
        $script:originalBytes = [IO.File]::ReadAllBytes($script:inputPath)
        $script:workerParameters = @{
            App = 'widget'; ManifestPath = $script:inputPath; OutputDirectory = $script:outputPath
            ScoopHome = $script:scoopHome; BaseSha = ('1' * 40); RunId = 'offline-run'; RunAttempt = '1'
        }
        Mock Invoke-ScoopCheckver -ModuleName update-worker {
            [pscustomobject]@{ ExitCode = 0; StandardOutput = "widget: 1.0.0`n"; StandardError = ''; TimedOut = $false; OutputTruncated = $false }
        }
    }

    It 'emits current only after source discovery and preserves the original bytes' {
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'current'
        $result.schema | Should -Be 1
        $result.sourceResolved | Should -BeTrue
        $result.oldVersion | Should -Be '1.0.0'
        $result.newVersion | Should -Be '1.0.0'
        $result.baseSha | Should -Be ('1' * 40)
        $result.runId | Should -Be 'offline-run'
        $result.runAttempt | Should -Be '1'
        @($result.Keys | Sort-Object) | Should -Be @('app', 'baseSha', 'newVersion', 'oldVersion', 'originalSha256', 'reason', 'runAttempt', 'runId', 'schema', 'sourceResolved', 'status')
        $result.originalSha256 | Should -Match '^[a-f0-9]{64}$'
        [Convert]::ToHexString([IO.File]::ReadAllBytes($script:inputPath)) | Should -Be ([Convert]::ToHexString($script:originalBytes))
        @(Get-ChildItem -LiteralPath $script:outputPath).Name | Should -Be @('result.json')
        (Get-Content -LiteralPath (Join-Path $script:outputPath 'result.json') -Raw | ConvertFrom-Json).status | Should -Be 'current'
        Should -Invoke Invoke-ScoopCheckver -ModuleName update-worker -Times 1
    }

    It 'emits an independently policy-validated candidate for a proven upgrade' {
        Mock Invoke-ScoopCheckver -ModuleName update-worker {
            param($Directory, $Version)
            if ($Version) {
                Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'updated.json') -Destination (Join-Path $Directory 'widget.json')
                $text = "widget: 2.0.0 (scoop version is 1.0.0) autoupdate available`nAutoupdating widget`nWriting updated widget manifest`n"
            } else {
                $text = "widget: 2.0.0 (scoop version is 1.0.0) autoupdate available`n"
            }
            [pscustomobject]@{ ExitCode = 0; StandardOutput = $text; StandardError = ''; TimedOut = $false; OutputTruncated = $false }
        }
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'updated'
        $result.sourceResolved | Should -BeTrue
        $result.newVersion | Should -Be '2.0.0'
        $result.candidateSha256 | Should -Be ((Get-FileHash -LiteralPath (Join-Path $script:outputPath 'candidate.json') -Algorithm SHA256).Hash.ToLowerInvariant())
        @($result.Keys | Sort-Object) | Should -Be @('app', 'baseSha', 'candidateSha256', 'newVersion', 'oldVersion', 'originalSha256', 'reason', 'runAttempt', 'runId', 'schema', 'sourceResolved', 'status')
        $savedResult = Get-Content -LiteralPath (Join-Path $script:outputPath 'result.json') -Raw | ConvertFrom-Json
        $savedResult.runId | Should -BeOfType ([string])
        $savedResult.runAttempt | Should -BeOfType ([string])
        @(Get-ChildItem -LiteralPath $script:outputPath).Name | Should -Be @('candidate.json', 'result.json')
        (Get-FileHash -LiteralPath $script:inputPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $result.originalSha256
        Should -Invoke Invoke-ScoopCheckver -ModuleName update-worker -Times 1 -ParameterFilter { $Version -eq '2.0.0' }
    }

    It 'persists an unavailable result for HTTP errors and process timeouts' -TestCases @(
        @{ Text = "widget: (403) Forbidden`nURL https://example.com is not valid`n"; Timeout = $false },
        @{ Text = ''; Timeout = $true }
    ) {
        param($Text, $Timeout)
        $mockResult = [pscustomobject]@{ ExitCode = 0; StandardOutput = $Text; StandardError = ''; TimedOut = $Timeout; OutputTruncated = $false }
        Mock Invoke-ScoopCheckver -ModuleName update-worker { $mockResult }
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'unavailable'
        $result.sourceResolved | Should -BeFalse
        (Join-Path $script:outputPath 'result.json') | Should -Exist
        (Join-Path $script:outputPath 'candidate.json') | Should -Not -Exist
    }

    It 'does not publish a candidate for no-evidence or malformed child output' -TestCases @(
        @{ Text = '' }, @{ Text = "widget: couldn't match 'version' in https://example.com`n" }, @{ Text = 'widget: 1.0.0' }
    ) {
        param($Text)
        $mockResult = [pscustomobject]@{ ExitCode = 0; StandardOutput = $Text; StandardError = ''; TimedOut = $false; OutputTruncated = $false }
        Mock Invoke-ScoopCheckver -ModuleName update-worker { $mockResult }
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'failed'
        $result.sourceResolved | Should -BeFalse
        (Join-Path $script:outputPath 'candidate.json') | Should -Not -Exist
    }

    It 'validates malformed JSON and schema errors before checking eligibility' -TestCases @(
        @{ Content = '{"version":"1.0.0",}' },
        @{ Content = '{"version":1,"homepage":"https://example.com"}' },
        @{ Content = '{"version":"1.0.0","version":"2.0.0"}' }
    ) {
        param($Content)
        [IO.File]::WriteAllText($script:inputPath, $Content)
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'failed'
        $result.sourceResolved | Should -BeFalse
        (Join-Path $script:outputPath 'result.json') | Should -Exist
        Should -Invoke Invoke-ScoopCheckver -ModuleName update-worker -Times 0
    }

    It 'reports missing rules and executable version scripts as manual without executing them' -TestCases @(
        @{ Field = 'checkver' }, @{ Field = 'autoupdate' }, @{ Field = 'script' }
    ) {
        param($Field)
        $manifest = Get-Content -LiteralPath $script:inputPath -Raw | ConvertFrom-Json -AsHashtable
        if ($Field -eq 'script') { $manifest.checkver = @{ script = 'throw "MUST NOT EXECUTE"'; regex = '([\\d.]+)' } }
        else { $manifest.Remove($Field) }
        [IO.File]::WriteAllText($script:inputPath, ($manifest | ConvertTo-Json -Depth 20))
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'manual'
        $result.sourceResolved | Should -BeFalse
        Should -Invoke Invoke-ScoopCheckver -ModuleName update-worker -Times 0
    }

    It 'does not call the <Rule> rule current' -TestCases @(
        @{ Rule = 'empty-checkver'; Status = 'manual' }, @{ Rule = 'empty-autoupdate'; Status = 'manual' },
        @{ Rule = 'note-only-autoupdate'; Status = 'failed' }, @{ Rule = 'custom-capture'; Status = 'manual' },
        @{ Rule = 'wrong-github-source'; Status = 'manual' }, @{ Rule = 'missing-architecture-template'; Status = 'manual' }
    ) {
        param($Rule, $Status)
        $manifest = Get-Content -LiteralPath $script:inputPath -Raw | ConvertFrom-Json -AsHashtable
        switch ($Rule) {
            'empty-checkver' { $manifest.checkver = @{} }
            'empty-autoupdate' { $manifest.autoupdate = @{} }
            'note-only-autoupdate' { $manifest.autoupdate = @{ note = 'No URL template' } }
            'custom-capture' { $manifest.autoupdate.url = 'https://example.com/widget-$match1.zip' }
            'wrong-github-source' { $manifest.checkver = 'github' }
            'missing-architecture-template' {
                $manifest.architecture = @{ '64bit' = @{ url = $manifest.url; hash = $manifest.hash } }
                $manifest.Remove('url')
                $manifest.Remove('hash')
                $manifest.autoupdate = @{ architecture = @{ '32bit' = @{ url = 'https://example.com/widget-$version.zip' } } }
            }
        }
        [IO.File]::WriteAllText($script:inputPath, ($manifest | ConvertTo-Json -Depth 20))
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be $Status
        $result.sourceResolved | Should -BeFalse
        Should -Invoke Invoke-ScoopCheckver -ModuleName update-worker -Times 0
    }

    It 'retains source evidence if the update subprocess logs an exit-zero hash error' {
        Mock Invoke-ScoopCheckver -ModuleName update-worker {
            param($Version)
            $text = "widget: 2.0.0 (scoop version is 1.0.0) autoupdate available`n"
            if ($Version) { $text += "Autoupdating widget`nURL https://example.com/widget-2.0.0.zip is not valid`n" }
            [pscustomobject]@{ ExitCode = 0; StandardOutput = $text; StandardError = ''; TimedOut = $false; OutputTruncated = $false }
        }
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'unavailable'
        $result.sourceResolved | Should -BeTrue
        $result.newVersion | Should -Be '2.0.0'
        (Join-Path $script:outputPath 'candidate.json') | Should -Not -Exist
    }

    It 'rejects a discovered downgrade before any update generation' {
        Mock Invoke-ScoopCheckver -ModuleName update-worker {
            [pscustomobject]@{ ExitCode = 0; StandardOutput = "widget: 0.9.0 (scoop version is 1.0.0) autoupdate available`n"; StandardError = ''; TimedOut = $false; OutputTruncated = $false }
        }
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'failed'
        $result.sourceResolved | Should -BeTrue
        $result.reason | Should -Be 'version-not-newer'
        Should -Invoke Invoke-ScoopCheckver -ModuleName update-worker -Times 0 -ParameterFilter { $Version }
    }

    It 'does not call a same-version hash mutation current' {
        Mock Invoke-ScoopCheckver -ModuleName update-worker {
            param($Directory)
            $path = Join-Path $Directory 'widget.json'
            [IO.File]::WriteAllText($path, ([IO.File]::ReadAllText($path).Replace(('a' * 64), ('b' * 64))))
            [pscustomobject]@{ ExitCode = 0; StandardOutput = "widget: 1.0.0`n"; StandardError = ''; TimedOut = $false; OutputTruncated = $false }
        }
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'failed'
        $result.reason | Should -Be 'discovery-modified-manifest'
        (Join-Path $script:outputPath 'candidate.json') | Should -Not -Exist
    }

    It 'rejects candidates that change policy or do not match the proven source version' -TestCases @(
        @{ Change = 'description' }, @{ Change = 'version' }, @{ Change = 'invalid-json' }
    ) {
        param($Change)
        $candidateChange = $Change
        Mock Invoke-ScoopCheckver -ModuleName update-worker {
            param($Directory, $Version)
            if ($Version) {
                $candidate = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'updated.json') -Raw | ConvertFrom-Json -AsHashtable
                if ($candidateChange -eq 'description') { $candidate.description = 'unexpected metadata change' }
                if ($candidateChange -eq 'version') { $candidate.version = '3.0.0' }
                $content = if ($candidateChange -eq 'invalid-json') { '{' } else { $candidate | ConvertTo-Json -Depth 20 }
                [IO.File]::WriteAllText((Join-Path $Directory 'widget.json'), $content)
                $text = "widget: 2.0.0 (scoop version is 1.0.0) autoupdate available`nAutoupdating widget`nWriting updated widget manifest`n"
            } else { $text = "widget: 2.0.0 (scoop version is 1.0.0) autoupdate available`n" }
            [pscustomobject]@{ ExitCode = 0; StandardOutput = $text; StandardError = ''; TimedOut = $false; OutputTruncated = $false }
        }
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'failed'
        $result.sourceResolved | Should -BeTrue
        (Join-Path $script:outputPath 'candidate.json') | Should -Not -Exist
    }

    It 'treats an invocation exception as a per-app failure and retains source data only as text' {
        Mock Invoke-ScoopCheckver -ModuleName update-worker { throw '$(throw "inert diagnostics")' }
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'failed'
        $result.reason | Should -Match 'inert diagnostics'
        (Join-Path $script:outputPath 'result.json') | Should -Exist
    }

    It 'preserves known source evidence when upgrade generation fails' {
        Mock Invoke-ScoopCheckver -ModuleName update-worker {
            param($Version)
            if ($Version) { throw 'simulated update invocation failure' }
            [pscustomobject]@{ ExitCode = 0; StandardOutput = "widget: 2.0.0 (scoop version is 1.0.0) autoupdate available`n"; StandardError = ''; TimedOut = $false; OutputTruncated = $false }
        }
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'failed'
        $result.sourceResolved | Should -BeTrue
        $result.newVersion | Should -Be '2.0.0'
        (Join-Path $script:outputPath 'candidate.json') | Should -Not -Exist
    }

    It 'retains evidence but refuses a stale original manifest' {
        Mock Invoke-ScoopCheckver -ModuleName update-worker {
            [IO.File]::AppendAllText($script:inputPath, "`n")
            [pscustomobject]@{ ExitCode = 0; StandardOutput = "widget: 1.0.0`n"; StandardError = ''; TimedOut = $false; OutputTruncated = $false }
        }
        $result = Invoke-ManifestUpdateWorker @script:workerParameters
        $result.status | Should -Be 'failed'
        $result.reason | Should -BeLike 'original-manifest-changed*'
        $result.sourceResolved | Should -BeTrue
        $result.newVersion | Should -Be '1.0.0'
    }

    It 'does not overwrite an occupied output directory' {
        $null = New-Item -ItemType Directory -Path $script:outputPath
        $marker = Join-Path $script:outputPath 'result.json'
        [IO.File]::WriteAllText($marker, 'existing content')
        { Invoke-ManifestUpdateWorker @script:workerParameters } | Should -Throw '*empty*'
        [IO.File]::ReadAllText($marker) | Should -BeExactly 'existing content'
    }
}

Describe 'Trusted forward extraction candidate generation' {
    BeforeEach {
        $script:caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:caseRoot
        $script:inputPath = Join-Path $script:caseRoot 'widget.json'
        $script:outputPath = Join-Path $script:caseRoot 'output'
        $script:layoutManifest = [IO.File]::ReadAllText((Join-Path $script:fixtureRoot 'current.json')) | ConvertFrom-Json -AsHashtable
        $script:layoutManifest.autoupdate.extract_dir = 'widget-$version'
        $script:layoutMutation = ''
        $script:stockCandidateBytes = $null
        $script:workerParameters = @{
            App = 'widget'; ManifestPath = $script:inputPath; OutputDirectory = $script:outputPath
            ScoopHome = $script:scoopHome; BaseSha = ('1' * 40); RunId = 'offline-layout'; RunAttempt = '1'
        }
        $script:invokeLayoutWorker = {
            [IO.File]::WriteAllText($script:inputPath, ($script:layoutManifest | ConvertTo-Json -Depth 20))
            $script:layoutOriginalBytes = [IO.File]::ReadAllBytes($script:inputPath)
            Invoke-ManifestUpdateWorker @script:workerParameters
        }
        Mock Invoke-ScoopCheckver -ModuleName update-worker {
            param($App, $Directory, $Version, $Workspace)
            if ($Version) {
                $path = Join-Path $Directory ($App + '.json')
                & $script:writeStockUpgrade $path $Workspace.Code
                $candidate = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
                switch ($script:layoutMutation) {
                    'wrong-extract' { $candidate.extract_dir = 'unexpected' }
                    'changed-template' { $candidate.autoupdate.extract_dir = 'changed-$version' }
                    'deleted-extract' { $candidate.Remove('extract_dir') }
                    'wrong-arch-extract' { $candidate.architecture['64bit'].extract_dir = 'wrong-2.0.0' }
                }
                if ($script:layoutMutation) { [IO.File]::WriteAllText($path, ($candidate | ConvertTo-Json -Depth 20)) }
                $script:stockCandidateBytes = [IO.File]::ReadAllBytes($path)
            }
            $text = "${App}: 2.0.0 (scoop version is 1.0.0) autoupdate available`n"
            if ($Version) { $text += "Autoupdating widget`nWriting updated widget manifest`n" }
            [pscustomobject]@{ ExitCode = 0; StandardOutput = $text; StandardError = ''; TimedOut = $false; OutputTruncated = $false }
        }
    }

    It 'materializes a missing root field after the stock Scoop helper omits it' {
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'updated' -Because $result.reason
        $stock = [Text.Encoding]::UTF8.GetString($script:stockCandidateBytes) | ConvertFrom-Json -AsHashtable
        $stock.Contains('extract_dir') | Should -BeFalse
        $path = Join-Path $script:outputPath 'candidate.json'
        $candidate = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
        $candidate.extract_dir | Should -BeExactly 'widget-2.0.0'
        $candidate.autoupdate.extract_dir | Should -BeExactly 'widget-$version'
        $result.sourceResolved | Should -BeTrue
        $result.candidateSha256 | Should -Be ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant())
        [Convert]::ToHexString([IO.File]::ReadAllBytes($script:inputPath)) | Should -Be ([Convert]::ToHexString($script:layoutOriginalBytes))
        @(Get-ChildItem -LiteralPath $script:outputPath).Name | Should -Be @('candidate.json', 'result.json')
        $canonical = & {
            param($Raw, $Core)
            Set-StrictMode -Off
            . (Join-Path $Core 'lib/core.ps1')
            . (Join-Path $Core 'lib/json.ps1')
            (($Raw | ConvertFrom-Json) | ConvertToPrettyJson) + "`r`n"
        } ([IO.File]::ReadAllText($path)) $script:scoopHome
        [IO.File]::ReadAllText($path) | Should -BeExactly $canonical
        [IO.File]::ReadAllBytes($path)[0] | Should -Not -Be 0xEF
    }

    It 'adds only an existing architecture field using its explicit scalar template' {
        $script:layoutManifest.architecture = @{ '64bit' = @{ url = $script:layoutManifest.url; hash = $script:layoutManifest.hash } }
        $script:layoutManifest.Remove('url')
        $script:layoutManifest.Remove('hash')
        $script:layoutManifest.autoupdate.Remove('extract_dir')
        $script:layoutManifest.autoupdate.architecture = @{ '64bit' = @{ extract_dir = 'widget-$underscoreVersion/amd64' } }
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'updated' -Because $result.reason
        $candidate = [IO.File]::ReadAllText((Join-Path $script:outputPath 'candidate.json')) | ConvertFrom-Json -AsHashtable
        $candidate.architecture['64bit'].extract_dir | Should -BeExactly 'widget-2_0_0/amd64'
        @($candidate.architecture.Keys) | Should -Be @('64bit')
        $candidate.Contains('extract_dir') | Should -BeFalse
    }

    It 'prefers an architecture override and inherits the root template for another existing architecture' {
        $asset = @{ url = $script:layoutManifest.url; hash = $script:layoutManifest.hash }
        $script:layoutManifest.architecture = @{ '64bit' = $asset.Clone(); '32bit' = $asset.Clone() }
        $script:layoutManifest.Remove('url')
        $script:layoutManifest.Remove('hash')
        $script:layoutManifest.autoupdate.architecture = @{ '64bit' = @{ extract_dir = 'widget-$version-x64' } }
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'updated' -Because $result.reason
        $candidate = [IO.File]::ReadAllText((Join-Path $script:outputPath 'candidate.json')) | ConvertFrom-Json -AsHashtable
        $candidate.architecture['64bit'].extract_dir | Should -BeExactly 'widget-2.0.0-x64'
        $candidate.architecture['32bit'].extract_dir | Should -BeExactly 'widget-2.0.0'
        $candidate.Contains('extract_dir') | Should -BeFalse
    }

    It 'preserves inherited root extraction without adding redundant architecture fields' {
        $script:layoutManifest.extract_dir = 'widget-1.0.0'
        $script:layoutManifest.architecture = @{ '64bit' = @{ url = $script:layoutManifest.url; hash = $script:layoutManifest.hash } }
        $script:layoutManifest.Remove('url')
        $script:layoutManifest.Remove('hash')
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'updated' -Because $result.reason
        $candidate = [IO.File]::ReadAllText((Join-Path $script:outputPath 'candidate.json')) | ConvertFrom-Json -AsHashtable
        $candidate.extract_dir | Should -BeExactly 'widget-2.0.0'
        $candidate.architecture['64bit'].Contains('extract_dir') | Should -BeFalse
    }

    It 'adds an explicit architecture override even when a root extraction field is inherited' {
        $script:layoutManifest.extract_dir = 'widget-1.0.0'
        $script:layoutManifest.architecture = @{ '64bit' = @{ url = $script:layoutManifest.url; hash = $script:layoutManifest.hash } }
        $script:layoutManifest.Remove('url')
        $script:layoutManifest.Remove('hash')
        $script:layoutManifest.autoupdate.architecture = @{ '64bit' = @{ extract_dir = 'widget-$version-x64' } }
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'updated' -Because $result.reason
        $candidate = [IO.File]::ReadAllText((Join-Path $script:outputPath 'candidate.json')) | ConvertFrom-Json -AsHashtable
        $candidate.extract_dir | Should -BeExactly 'widget-2.0.0'
        $candidate.architecture['64bit'].extract_dir | Should -BeExactly 'widget-2.0.0-x64'
    }

    It 'uses the real Scoop version substitutions for Unicode and built-in capture templates' -TestCases @(
        @{ Template = '3proxy'; Expected = '3proxy' },
        @{ Template = ("`u{8d44}`u{6e90}-" + '$dashVersion/' + "`u{e9}"); Expected = "`u{8d44}`u{6e90}-2-0-0/`u{e9}" },
        @{ Template = '$matchHead$matchTail'; Expected = '2.0.0' }
    ) {
        param($Template, $Expected)
        $script:layoutManifest.autoupdate.extract_dir = $Template
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'updated' -Because $result.reason
        $candidate = [IO.File]::ReadAllText((Join-Path $script:outputPath 'candidate.json')) | ConvertFrom-Json -AsHashtable
        $candidate.extract_dir | Should -BeExactly $Expected
    }

    It 'leaves current inputs untouched even with a missing templated extraction field' {
        Mock Invoke-ScoopCheckver -ModuleName update-worker {
            [pscustomobject]@{ ExitCode = 0; StandardOutput = "widget: 1.0.0`n"; StandardError = ''; TimedOut = $false; OutputTruncated = $false }
        }
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'current'
        $result.oldVersion | Should -BeExactly '1.0.0'
        $result.newVersion | Should -BeExactly '1.0.0'
        [Convert]::ToHexString([IO.File]::ReadAllBytes($script:inputPath)) | Should -Be ([Convert]::ToHexString($script:layoutOriginalBytes))
        @(Get-ChildItem -LiteralPath $script:outputPath).Name | Should -Be @('result.json')
        Should -Invoke Invoke-ScoopCheckver -ModuleName update-worker -Times 0 -ParameterFilter { $Version }
    }

    It 'keeps an app named base separate from the immutable snapshot file' {
        $script:inputPath = Join-Path $script:caseRoot 'base.json'
        $script:workerParameters.App = 'base'
        $script:workerParameters.ManifestPath = $script:inputPath
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'updated' -Because $result.reason
        $candidate = [IO.File]::ReadAllText((Join-Path $script:outputPath 'candidate.json')) | ConvertFrom-Json -AsHashtable
        $candidate.extract_dir | Should -BeExactly 'widget-2.0.0'
    }

    It 'preserves stock candidate bytes when no extraction field is templated' {
        $script:layoutManifest.autoupdate.Remove('extract_dir')
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'updated' -Because $result.reason
        $path = Join-Path $script:outputPath 'candidate.json'
        $candidate = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
        $candidate.Contains('extract_dir') | Should -BeFalse
        [Convert]::ToHexString([IO.File]::ReadAllBytes($path)) | Should -Be ([Convert]::ToHexString($script:stockCandidateBytes))
    }

    It 'does not materialize absent bins or shortcuts while adding extract_dir' {
        $script:layoutManifest.autoupdate.bin = 'widget-$version.exe'
        $script:layoutManifest.autoupdate.shortcuts = ,@('widget-$version.exe', 'Widget')
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'updated' -Because $result.reason
        $candidate = [IO.File]::ReadAllText((Join-Path $script:outputPath 'candidate.json')) | ConvertFrom-Json -AsHashtable
        $candidate.extract_dir | Should -BeExactly 'widget-2.0.0'
        $candidate.Contains('bin') | Should -BeFalse
        $candidate.Contains('shortcuts') | Should -BeFalse
    }

    It 'fails closed for the unsupported extraction template <Label>' -TestCases @(
        @{ Label = 'unknown variable'; Template = '$unknownVersion'; Status = 'failed' },
        @{ Label = 'custom capture'; Template = '$match1'; Status = 'manual' },
        @{ Label = 'traversal'; Template = '../payload'; Status = 'failed' },
        @{ Label = 'absolute path'; Template = 'C:\payload'; Status = 'failed' },
        @{ Label = 'Windows reserved path'; Template = 'payload/CON.txt'; Status = 'failed' },
        @{ Label = 'inert expression'; Template = '$(throw "must not execute")'; Status = 'failed' },
        @{ Label = 'empty scalar'; Template = ''; Status = 'failed' },
        @{ Label = 'array'; Template = @('one', 'two'); Status = 'failed' }
    ) {
        param($Template, $Status)
        $script:layoutManifest.autoupdate.extract_dir = $Template
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be $Status -Because $result.reason
        @(Get-ChildItem -LiteralPath $script:outputPath).Name | Should -Be @('result.json')
        [Convert]::ToHexString([IO.File]::ReadAllBytes($script:inputPath)) | Should -Be ([Convert]::ToHexString($script:layoutOriginalBytes))
    }

    It 'does not repair candidate deletions, wrong values, or mutated template authority' -TestCases @(
        @{ Mutation = 'deleted-extract' }, @{ Mutation = 'wrong-extract' }, @{ Mutation = 'changed-template' }
    ) {
        param($Mutation)
        if ($Mutation -eq 'deleted-extract') { $script:layoutManifest.extract_dir = 'widget-1.0.0' }
        $script:layoutMutation = $Mutation
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'failed'
        $result.reason | Should -BeLike 'candidate-policy-rejected*'
        $result.sourceResolved | Should -BeTrue
        (Join-Path $script:outputPath 'candidate.json') | Should -Not -Exist
    }

    It 'does not grant extraction authority from a sibling architecture template' {
        $script:layoutManifest.architecture = @{ '64bit' = @{ url = $script:layoutManifest.url; hash = $script:layoutManifest.hash } }
        $script:layoutManifest.Remove('url')
        $script:layoutManifest.Remove('hash')
        $script:layoutManifest.autoupdate.Remove('extract_dir')
        $script:layoutManifest.autoupdate.architecture = @{ '32bit' = @{ extract_dir = 'wrong-$version' } }
        $script:layoutMutation = 'wrong-arch-extract'
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'failed'
        $result.reason | Should -BeLike 'candidate-policy-rejected*'
        (Join-Path $script:outputPath 'candidate.json') | Should -Not -Exist
    }

    It 'checks the materialized candidate with the schema before emitting it' {
        Mock Assert-ManifestSchema -ModuleName update-worker { throw 'schema rejected materialized candidate' } -ParameterFilter {
            $value = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
            $value.Contains('extract_dir')
        }
        $result = & $script:invokeLayoutWorker
        $result.status | Should -Be 'failed'
        $result.reason | Should -BeLike '*schema rejected materialized candidate*'
        (Join-Path $script:outputPath 'candidate.json') | Should -Not -Exist
    }
}

Describe 'Extraction helper unit contract' {
    It 'materializes only the eligible missing field for <Mode>' -TestCases @(
        @{ Mode = 'root' }, @{ Mode = 'architecture' }, @{ Mode = 'inherited-root' },
        @{ Mode = 'no-template' }, @{ Mode = 'existing-before' }, @{ Mode = 'existing-after' },
        @{ Mode = 'missing-architecture' }, @{ Mode = 'invalid-architecture' }, @{ Mode = 'sibling-template' }, @{ Mode = 'array' }
    ) {
        param($Mode)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        $before = [IO.File]::ReadAllText((Join-Path $script:fixtureRoot 'current.json')) | ConvertFrom-Json -AsHashtable
        $before.autoupdate.extract_dir = 'widget-$version'
        $isArchitecture = $Mode -in @('architecture', 'inherited-root', 'missing-architecture', 'invalid-architecture', 'sibling-template')
        if ($isArchitecture) {
            $before.architecture = @{ '64bit' = @{ url = $before.url; hash = $before.hash } }
            $before.Remove('url')
            $before.Remove('hash')
        }
        switch ($Mode) {
            'no-template' { $before.autoupdate.Remove('extract_dir') }
            'existing-before' { $before.extract_dir = 'widget-1.0.0' }
            'inherited-root' { $before.extract_dir = 'widget-1.0.0' }
            'architecture' { $before.autoupdate.architecture = @{ '64bit' = @{ extract_dir = 'widget-$version-x64' } } }
            'sibling-template' {
                $before.autoupdate.Remove('extract_dir')
                $before.autoupdate.architecture = @{ '32bit' = @{ extract_dir = 'wrong-$version' } }
            }
            'array' { $before.autoupdate.extract_dir = @('one', 'two') }
        }
        $after = $before | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $after.version = '2.0.0'
        if ($Mode -eq 'existing-after') { $after.extract_dir = 'already-present' }
        if ($Mode -eq 'missing-architecture') { $after.architecture = @{} }
        if ($Mode -eq 'invalid-architecture') { $after.architecture = 'inert' }
        $basePath = Join-Path $root 'before.json'
        $candidatePath = Join-Path $root 'candidate.json'
        $baseText = $before | ConvertTo-Json -Depth 20
        $candidateText = $after | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($basePath, $baseText)
        [IO.File]::WriteAllText($candidatePath, $candidateText)
        $parameters = @{ BaseManifestPath = $basePath; CandidatePath = $candidatePath; ScoopHome = $script:scoopHome }
        $helper = Join-Path $script:repoRoot 'bin/update-worker-extract-dir.ps1'
        if ($Mode -eq 'array') { { & $helper @parameters } | Should -Throw '*scalar extract_dir*' }
        else {
            & $helper @parameters
            $candidate = [IO.File]::ReadAllText($candidatePath) | ConvertFrom-Json -AsHashtable
            if ($Mode -eq 'root') { $candidate.extract_dir | Should -BeExactly 'widget-2.0.0' }
            elseif ($Mode -eq 'architecture') { $candidate.architecture['64bit'].extract_dir | Should -BeExactly 'widget-2.0.0-x64' }
            else { [IO.File]::ReadAllText($candidatePath) | Should -BeExactly $candidateText }
        }
        [IO.File]::ReadAllText($basePath) | Should -BeExactly $baseText
    }
}

Describe 'Actual pinned Scoop offline contract' {
    It 'accepts the same pinned checkver source with either LF or CRLF line endings' {
        $root = Join-Path $TestDrive 'lf-scoop'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'bin')
        $source = [IO.File]::ReadAllText((Join-Path $script:scoopHome 'bin/checkver.ps1')).Replace("`r`n", "`n")
        [IO.File]::WriteAllText((Join-Path $root 'bin/checkver.ps1'), $source)
        InModuleScope update-worker -Parameters @{ Root = $root } {
            param($Root)
            Assert-WorkerScoopContract -ScoopHome $Root
        }
    }

    It 'fails closed if the pinned checkver implementation changes' {
        $root = Join-Path $TestDrive 'wrong-scoop'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'bin')
        [IO.File]::WriteAllText((Join-Path $root 'bin/checkver.ps1'), 'throw "untrusted implementation"')
        InModuleScope update-worker -Parameters @{ Root = $root } {
            param($Root)
            $failure = $null
            try { Assert-WorkerScoopContract -ScoopHome $Root } catch { $failure = $_ }
            $failure | Should -Not -BeNullOrEmpty
            $failure.Exception.Message | Should -BeLike '*pinned*'
        }
    }

    It 'uses isolated trusted code and hashes a local fixture asset without executing it' {
        $inputPath = Join-Path $TestDrive 'widget.json'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'current.json') -Destination $inputPath
        InModuleScope update-worker -Parameters @{ ScoopHome = $script:scoopHome; InputPath = $inputPath; Fixtures = $script:fixtureRoot } {
            param($ScoopHome, $InputPath, $Fixtures)
            $workspace = Initialize-WorkerWorkspace $ScoopHome $InputPath 'widget'
            try {
                $path = Join-Path $workspace.Manifests 'widget.json'
                $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
                $manifest.checkver.url = ([Uri] (Join-Path $Fixtures 'version.txt')).AbsoluteUri
                $manifest.autoupdate.url = ([Uri] (Join-Path $Fixtures 'asset.ps1')).AbsoluteUri
                $manifest.autoupdate.extract_dir = 'widget-$version'
                [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 20))
                $run = Invoke-ScoopCheckver -App 'widget' -Directory $workspace.Manifests -Workspace $workspace -TimeoutSeconds 15
                $run.ExitCode | Should -Be 0
                $evidence = ConvertFrom-ScoopCheckverOutput -App 'widget' -OldVersion '1.0.0' -StandardOutput $run.StandardOutput -StandardError $run.StandardError
                $evidence.Status | Should -Be 'resolved'
                $evidence.Version | Should -Be '2.0.0'
                $run = Invoke-ScoopCheckver -App 'widget' -Directory $workspace.Manifests -Workspace $workspace -TimeoutSeconds 15 -Version '2.0.0'
                $run.ExitCode | Should -Be 0
                $candidate = [IO.File]::ReadAllText($path) | ConvertFrom-Json
                $candidate.version | Should -Be '2.0.0'
                $candidate.hash | Should -Be ((Get-FileHash -LiteralPath (Join-Path $Fixtures 'asset.ps1') -Algorithm SHA256).Hash.ToLowerInvariant())
                $candidate.PSObject.Properties.Name | Should -Not -Contain 'extract_dir'
                Complete-WorkerExtractionTemplate -Before $manifest -CandidatePath $path -Workspace $workspace
                $materialized = [IO.File]::ReadAllText($path) | ConvertFrom-Json
                $materialized.extract_dir | Should -BeExactly 'widget-2.0.0'
                $materialized.hash | Should -BeExactly $candidate.hash
                Assert-ManifestSchema -Path $path -ScoopHome $ScoopHome
                @(Get-ChildItem -LiteralPath $workspace.Cache -File).Count | Should -BeGreaterThan 0
                $workspace.Code | Should -Not -Be $workspace.Cache
            } finally { Remove-Item -LiteralPath $workspace.Root -Recurse -Force }
        }
    }
}

Describe 'Worker command entrypoint' {
    It 'writes a per-app failure artifact for malformed JSON without network access' {
        $inputPath = Join-Path $TestDrive 'widget.json'
        [IO.File]::WriteAllText($inputPath, '{')
        $output = Join-Path $TestDrive 'cli-result'
        $scriptPath = Join-Path $script:repoRoot 'bin/update-manifest.ps1'
        $text = & $scriptPath -App 'widget' -ManifestPath $inputPath -OutputDirectory $output -ScoopHome $script:scoopHome -BaseSha ('1' * 40) -RunId 'cli-offline' -RunAttempt '2'
        $result = $text | ConvertFrom-Json
        $result.status | Should -Be 'failed'
        $result.runId | Should -Be 'cli-offline'
        $result.runAttempt | Should -Be '2'
        (Join-Path $output 'result.json') | Should -Exist
        (Join-Path $output 'candidate.json') | Should -Not -Exist
        [IO.File]::ReadAllText($inputPath) | Should -BeExactly '{'
    }
}
