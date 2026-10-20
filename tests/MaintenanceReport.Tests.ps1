BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../bin/maintenance-report.psm1') -Force

    function New-TestManifest([string]$Path, [bool]$Configured = $true, [string]$Version = '1.0.0') {
        $manifest = [ordered]@{
            version = $Version
            description = 'Test fixture'
            homepage = 'https://example.test/app'
            license = 'MIT'
            url = "https://example.test/app-$Version.zip"
            hash = ('a' * 64)
        }
        if ($Configured) {
            $manifest.checkver = 'github'
            $manifest.autoupdate = @{ url = 'https://example.test/app-$version.zip' }
        }
        [IO.File]::WriteAllText($Path, ($manifest | ConvertTo-Json -Depth 10))
    }

    function New-TestOutcome(
        [string]$Root,
        [string]$App,
        [string]$Status = 'updated',
        [string]$Batch = '0'
    ) {
        $directory = Join-Path $Root "scoop-updates-1-$Batch/$App"
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $result = [ordered]@{
            schema = 1
            app = $App
            status = $Status
            reason = 'Fixture outcome'
            baseSha = ('b' * 40)
            runId = '123'
            runAttempt = '1'
            originalSha256 = ('c' * 64)
            oldVersion = '1.0.0'
            newVersion = $(if ($Status -eq 'updated') { '1.1.0' } else { '1.0.0' })
            sourceResolved = ($Status -in @('updated', 'current'))
        }
        if ($Status -eq 'updated') {
            New-TestManifest (Join-Path $directory 'candidate.json') -Version '1.1.0'
            $result.candidateSha256 = (Get-FileHash (Join-Path $directory 'candidate.json')).Hash.ToLowerInvariant()
        }
        [IO.File]::WriteAllText((Join-Path $directory 'result.json'), ($result | ConvertTo-Json -Depth 10))
        $directory
    }

    function Get-TestCollection([string]$Root, [string[]]$Apps, [int]$Limit = 32, [long]$RunNumber = 1) {
        Get-UpdateCollectionReport -ArtifactDirectory $Root -SelectedApps $Apps -ExpectedRunId '123' `
            -ExpectedRunAttempt '1' -BaseSha ('b' * 40) -MaxUpdates $Limit -RunNumber $RunNumber
    }
}

Describe 'Maintenance inventory' {
    It 'separates configured metadata from intentional manual maintenance' {
        $bucket = Join-Path $TestDrive 'inventory'
        New-Item -ItemType Directory -Path $bucket | Out-Null
        New-TestManifest (Join-Path $bucket 'configured.json')
        New-TestManifest (Join-Path $bucket 'manual.json') $false

        $report = Get-MaintenanceReport -BucketPath $bucket

        $report.Total | Should -Be 2
        @($report.Apps | Where-Object Eligible).Count | Should -Be 1
        ($report.Apps | Where-Object App -EQ 'manual').State | Should -Be 'manual'
    }

    It 'does not hide malformed legacy files or call them configured' {
        $bucket = Join-Path $TestDrive 'invalid-inventory'
        New-Item -ItemType Directory -Path $bucket | Out-Null
        [IO.File]::WriteAllText((Join-Path $bucket 'broken.json'), '{invalid')

        $report = Get-MaintenanceReport -BucketPath $bucket

        $report.Total | Should -Be 1
        $report.Apps[0].State | Should -Be 'invalid'
        $report.Apps[0].Eligible | Should -BeFalse
        $report.Apps[0].Reason | Should -Not -BeNullOrEmpty
    }

    It 'does not schedule schema-obvious missing metadata as a healthy candidate' {
        $bucket = Join-Path $TestDrive 'missing-license'
        New-Item -ItemType Directory -Path $bucket | Out-Null
        New-TestManifest (Join-Path $bucket 'app.json')
        $path = Join-Path $bucket 'app.json'
        $manifest = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $manifest.license = ''
        [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 10))

        $report = Get-MaintenanceReport -BucketPath $bucket

        $report.Apps[0].Eligible | Should -BeFalse
        $report.Apps[0].Reason | Should -Match 'license'
    }
}

Describe 'Explicit manual exceptions' {
    It 'records intentional maintenance without calling configured fields live-verified' {
        $bucket = Join-Path $TestDrive 'exception-inventory'
        New-Item -ItemType Directory -Path $bucket | Out-Null
        New-TestManifest (Join-Path $bucket 'app.json')
        $exceptions = Join-Path $TestDrive 'exceptions.json'
        [IO.File]::WriteAllText($exceptions, '{"schema":1,"manual":[{"app":"app","reason":"Vendor no longer publishes verifiable assets","source":"https://example.test"}]}')

        $report = Get-MaintenanceReport -BucketPath $bucket -ExceptionPath $exceptions

        $report.Configured | Should -Be 1
        $report.Apps[0].State | Should -Be 'manual'
        $report.Apps[0].Eligible | Should -BeFalse
    }

    It 'rejects malformed exception protocol <Case>' -ForEach @(
        @{ Case = 'boolean schema'; Json = '{"schema":true,"manual":[]}' },
        @{ Case = 'string schema'; Json = '{"schema":"1","manual":[]}' },
        @{ Case = 'non-array manual'; Json = '{"schema":1,"manual":{"app":"app","reason":"why","source":"https://example.test"}}' },
        @{ Case = 'missing source'; Json = '{"schema":1,"manual":[{"app":"app","reason":"why"}]}' }
    ) {
        $bucket = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $bucket | Out-Null
        New-TestManifest (Join-Path $bucket 'app.json')
        $exceptions = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).json"
        [IO.File]::WriteAllText($exceptions, $Json)

        { Get-MaintenanceReport -BucketPath $bucket -ExceptionPath $exceptions } | Should -Throw
    }

    It 'rejects unexplained or duplicate exceptions' {
        $bucket = Join-Path $TestDrive 'duplicate-exceptions'
        New-Item -ItemType Directory -Path $bucket | Out-Null
        New-TestManifest (Join-Path $bucket 'app.json')
        $exceptions = Join-Path $TestDrive 'duplicate-exceptions.json'
        [IO.File]::WriteAllText($exceptions, '{"schema":1,"manual":[{"app":"app","reason":"first","source":"https://example.test"},{"app":"app","reason":"second","source":"https://example.test"}]}')

        { Get-MaintenanceReport -BucketPath $bucket -ExceptionPath $exceptions } | Should -Throw
    }
}

Describe 'Bounded update batches' {
    It 'accounts for more than the GitHub matrix limit without losing apps' {
        $apps = @(1..261 | ForEach-Object { 'app-{0:D3}' -f $_ })

        $matrix = Split-UpdateApp -Apps $apps -BatchSize 16

        @($matrix.include).Count | Should -Be 17
        @($matrix.include | ForEach-Object { $_.apps }).Count | Should -Be 261
        @($matrix.include | Where-Object { $_.apps.Count -gt 16 }).Count | Should -Be 0
    }

    It 'emits an explicit empty matrix for no eligible apps' {
        $matrix = Split-UpdateApp -Apps @() -BatchSize 16
        @($matrix.include).Count | Should -Be 0
    }

    It 'rejects invalid batching limits' {
        { Split-UpdateApp -Apps @('app') -BatchSize 0 } | Should -Throw
    }
}

Describe 'Per-app artifact aggregation' {
    BeforeEach {
        $artifactRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $artifactRoot | Out-Null
    }

    It 'publishes a healthy sibling while reporting another source failure' {
        New-TestOutcome $artifactRoot 'healthy' | Out-Null
        New-TestOutcome $artifactRoot 'offline' 'unavailable' | Out-Null

        $report = Get-TestCollection $artifactRoot @('healthy', 'offline')

        $report.Counts.updated | Should -Be 1 -Because ($report.Results | ConvertTo-Json -Compress)
        $report.Counts.unavailable | Should -Be 1 -Because ($report.Results | ConvertTo-Json -Compress)
        @($report.PublishMatrix.include).Count | Should -Be 1
        $report.PublishMatrix.include[0].app | Should -Be 'healthy'
        $report.AllCurrent | Should -BeFalse
    }

    It 'treats a missing worker result as failure instead of current' {
        $report = Get-TestCollection $artifactRoot @('lost')
        $report.Counts.failed | Should -Be 1
        $report.AllCurrent | Should -BeFalse
        @($report.PublishMatrix.include).Count | Should -Be 0
    }

    It 'rejects type-coerced worker protocol field <Field>' -ForEach @(
        @{ Field = 'schema'; Value = $true },
        @{ Field = 'runId'; Value = 123 },
        @{ Field = 'runAttempt'; Value = 1 }
    ) {
        $directory = New-TestOutcome $artifactRoot 'typed' 'current'
        $path = Join-Path $directory 'result.json'
        $record = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $record[$Field] = $Value
        [IO.File]::WriteAllText($path, ($record | ConvertTo-Json -Depth 10))

        $report = Get-TestCollection $artifactRoot @('typed')

        $report.Counts.failed | Should -Be 1
        $report.AllCurrent | Should -BeFalse
    }

    It 'requires positive resolution evidence even for current outcomes' {
        $directory = New-TestOutcome $artifactRoot 'unresolved' 'current'
        $result = Get-Content (Join-Path $directory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
        $result.sourceResolved = $false
        [IO.File]::WriteAllText((Join-Path $directory 'result.json'), ($result | ConvertTo-Json))

        $report = Get-TestCollection $artifactRoot @('unresolved')

        $report.Counts.failed | Should -Be 1
        $report.AllCurrent | Should -BeFalse
    }

    It 'rejects candidate bytes that differ from the recorded SHA256' {
        $directory = New-TestOutcome $artifactRoot 'tampered'
        [IO.File]::AppendAllText((Join-Path $directory 'candidate.json'), ' ')

        $report = Get-TestCollection $artifactRoot @('tampered')

        $report.Counts.failed | Should -Be 1
        @($report.PublishMatrix.include).Count | Should -Be 0
    }

    It 'rejects unexpected executable artifact files' {
        $directory = New-TestOutcome $artifactRoot 'extra'
        [IO.File]::WriteAllText((Join-Path $directory 'payload.ps1'), 'throw "must never execute"')

        $report = Get-TestCollection $artifactRoot @('extra')

        $report.Counts.failed | Should -Be 1
        @($report.PublishMatrix.include).Count | Should -Be 0
    }

    It 'rejects results from another producer run' {
        $directory = New-TestOutcome $artifactRoot 'stale'
        $result = Get-Content (Join-Path $directory 'result.json') -Raw | ConvertFrom-Json -AsHashtable
        $result.runId = 'different-run'
        [IO.File]::WriteAllText((Join-Path $directory 'result.json'), ($result | ConvertTo-Json))

        $report = Get-TestCollection $artifactRoot @('stale')

        $report.Counts.failed | Should -Be 1
    }

    It 'does not use last-writer-wins for duplicate app outcomes' {
        New-TestOutcome $artifactRoot 'duplicate' -Batch '0' | Out-Null
        New-TestOutcome $artifactRoot 'duplicate' -Batch '1' | Out-Null

        $report = Get-TestCollection $artifactRoot @('duplicate')

        $report.Counts.failed | Should -Be 1
        @($report.PublishMatrix.include).Count | Should -Be 0
    }

    It 'reports all-current only for complete positive evidence' {
        New-TestOutcome $artifactRoot 'current' 'current' | Out-Null

        $report = Get-TestCollection $artifactRoot @('current')

        $report.AllCurrent | Should -BeTrue -Because ($report.Results | ConvertTo-Json -Compress)
        $report.Counts.current | Should -Be 1
    }

    It 'keeps no eligible apps distinct from all-current' {
        $report = Get-TestCollection $artifactRoot @()
        $report.AllCurrent | Should -BeFalse
        @($report.PublishMatrix.include).Count | Should -Be 0
    }

    It 'rotates deferred candidates while keeping every matrix bounded' {
        1..5 | ForEach-Object { New-TestOutcome $artifactRoot "app-$_" | Out-Null }
        $apps = @(1..5 | ForEach-Object { "app-$_" })

        $first = Get-TestCollection $artifactRoot $apps -Limit 2 -RunNumber 1
        $second = Get-TestCollection $artifactRoot $apps -Limit 2 -RunNumber 2
        $third = Get-TestCollection $artifactRoot $apps -Limit 2 -RunNumber 3

        $first.DeferredCount | Should -Be 3
        @($first.PublishMatrix.include).Count | Should -Be 2
        $visited = @($first.PublishMatrix.include.app) + @($second.PublishMatrix.include.app) + @($third.PublishMatrix.include.app)
        @($visited | Sort-Object -Unique).Count | Should -Be 5
    }
}

Describe 'Batch execution failure isolation' {
    It 'continues after one child worker fails and records that failure' {
        Mock Invoke-ManifestWorkerProcess -ModuleName maintenance-report {
            param([string[]]$ArgumentList)
            $app = $ArgumentList[[Array]::IndexOf($ArgumentList, '-App') + 1]
            if ($app -eq 'bad') { throw 'Fixture process failure' }
            $output = $ArgumentList[[Array]::IndexOf($ArgumentList, '-OutputDirectory') + 1]
            New-Item -ItemType Directory -Path $output -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $output 'result.json'), '{"status":"current"}')
        }
        $output = Join-Path $TestDrive 'batch-results'

        Invoke-UpdateBatch -Apps @('bad', 'good') -BucketPath $TestDrive -OutputDirectory $output `
            -ScoopHome $TestDrive -BaseSha ('b' * 40) -RunId '123' -RunAttempt '1'

        $failure = Get-Content (Join-Path $output 'bad/result.json') -Raw | ConvertFrom-Json
        $failure.status | Should -Be 'failed'
        Test-Path -LiteralPath (Join-Path $output 'good/result.json') | Should -BeTrue
        Should -Invoke Invoke-ManifestWorkerProcess -ModuleName maintenance-report -Times 2 -Exactly
    }

    It 'records a missing result even if the child returned successfully' {
        Mock Invoke-ManifestWorkerProcess -ModuleName maintenance-report {}
        $output = Join-Path $TestDrive 'missing-batch-result'

        Invoke-UpdateBatch -Apps @('missing') -BucketPath $TestDrive -OutputDirectory $output `
            -ScoopHome $TestDrive -BaseSha ('b' * 40) -RunId '123' -RunAttempt '1'

        $failure = Get-Content (Join-Path $output 'missing/result.json') -Raw | ConvertFrom-Json
        $failure.status | Should -Be 'failed'
        $failure.sourceResolved | Should -BeFalse
    }

    It 'does not trust a successful-looking result from a nonzero worker' {
        Mock Invoke-ManifestWorkerProcess -ModuleName maintenance-report {
            param([string[]]$ArgumentList)
            $output = $ArgumentList[[Array]::IndexOf($ArgumentList, '-OutputDirectory') + 1]
            New-Item -ItemType Directory -Path $output -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $output 'result.json'), '{"status":"current"}')
            throw 'Worker failed after writing an incomplete success record'
        }
        $output = Join-Path $TestDrive 'incomplete-success'

        Invoke-UpdateBatch -Apps @('app') -BucketPath $TestDrive -OutputDirectory $output `
            -ScoopHome $TestDrive -BaseSha ('b' * 40) -RunId '123' -RunAttempt '1'

        $failure = Get-Content (Join-Path $output 'app/result.json') -Raw | ConvertFrom-Json
        $failure.status | Should -Be 'failed'
    }

    It 'rejects a linked output <Case> before launching or writing results' -ForEach @(
        @{ Case = 'root'; IsAncestor = $false },
        @{ Case = 'ancestor'; IsAncestor = $true }
    ) {
        Mock Invoke-ManifestWorkerProcess -ModuleName maintenance-report { throw 'Must never run through a link' }
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $target = Join-Path $root 'target'
        $link = Join-Path $root 'linked'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $type = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $type -Path $link -Target $target | Out-Null
        $output = if ($IsAncestor) { Join-Path $link 'new/results' } else { $link }
        try {
            { Invoke-UpdateBatch -Apps @('app') -BucketPath $TestDrive -OutputDirectory $output `
                -ScoopHome $TestDrive -BaseSha ('b' * 40) -RunId '123' -RunAttempt '1' } | Should -Throw
            Should -Invoke Invoke-ManifestWorkerProcess -ModuleName maintenance-report -Times 0 -Exactly
            @(Get-ChildItem -LiteralPath $target -Force -Recurse).Count | Should -Be 0
        } finally {
            $item = Get-Item -LiteralPath $link -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $link -Force }
        }
    }

    It 'rejects relative output paths rather than mixing process and PowerShell locations' {
        Mock Invoke-ManifestWorkerProcess -ModuleName maintenance-report { throw 'Must not launch' }
        $location = Join-Path $TestDrive 'different-location'
        New-Item -ItemType Directory -Path $location | Out-Null
        Push-Location $location
        try {
            { Invoke-UpdateBatch -Apps @('app') -BucketPath $TestDrive -OutputDirectory 'relative/results' `
                -ScoopHome $TestDrive -BaseSha ('b' * 40) -RunId '123' -RunAttempt '1' } | Should -Throw
            Should -Invoke Invoke-ManifestWorkerProcess -ModuleName maintenance-report -Times 0 -Exactly
        } finally {
            Pop-Location
        }
    }

    It 'stops before launch after nonterminating output <Operation> errors' -ForEach @(
        @{ Operation = 'listing' },
        @{ Operation = 'creation' }
    ) {
        Mock Invoke-ManifestWorkerProcess -ModuleName maintenance-report { throw 'Must not launch' }
        $output = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        if ($Operation -eq 'listing') {
            New-Item -ItemType Directory -Path $output | Out-Null
            Mock Get-ChildItem -ModuleName maintenance-report {
                param($ErrorAction)
                $action = if ($ErrorAction) { $ErrorAction } else { 'Continue' }
                Write-Error 'Fixture listing denied' -ErrorAction $action
            }
        } else {
            Mock New-Item -ModuleName maintenance-report {
                param($ErrorAction)
                $action = if ($ErrorAction) { $ErrorAction } else { 'Continue' }
                Write-Error 'Fixture creation denied' -ErrorAction $action
            }
        }

        { Invoke-UpdateBatch -Apps @('app') -BucketPath $TestDrive -OutputDirectory $output `
            -ScoopHome $TestDrive -BaseSha ('b' * 40) -RunId '123' -RunAttempt '1' } | Should -Throw
        Should -Invoke Invoke-ManifestWorkerProcess -ModuleName maintenance-report -Times 0 -Exactly
    }

    It 'rejects a reused nonempty output directory before starting children' {
        Mock Invoke-ManifestWorkerProcess -ModuleName maintenance-report {}
        $output = Join-Path $TestDrive 'reused-batch'
        New-Item -ItemType Directory -Path $output | Out-Null
        [IO.File]::WriteAllText((Join-Path $output 'existing.json'), '{}')

        { Invoke-UpdateBatch -Apps @('app') -BucketPath $TestDrive -OutputDirectory $output `
            -ScoopHome $TestDrive -BaseSha ('b' * 40) -RunId '123' -RunAttempt '1' } | Should -Throw
        Should -Invoke Invoke-ManifestWorkerProcess -ModuleName maintenance-report -Times 0 -Exactly
    }
}
