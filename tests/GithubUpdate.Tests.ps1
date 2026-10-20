BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'bin/github-update.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'bin/github-api.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'bin/github-validation.psm1') -Force
    $script:sha = 'a' * 40
    $script:base = 'b' * 40
    $script:newBase = 'c' * 40
    $script:policy = 'd' * 64
    $script:scoopHome = if ($env:SCOOP_HOME) { $env:SCOOP_HOME } else { Join-Path $env:USERPROFILE 'scoop/apps/scoop/current' }

    function New-TestManifest {
        param([string]$Version = '1.0')
        [ordered]@{
            version = $Version
            description = 'Offline fixture'
            homepage = 'https://example.com'
            license = 'MIT'
            url = "https://example.com/app-$Version.zip"
            hash = '0' * 64
            checkver = 'github'
            autoupdate = @{ url = 'https://example.com/app-$version.zip' }
        } | ConvertTo-Json -Depth 10
    }
}

Describe 'GitHub publication authorization and fresh evidence' {
    It 'honors the configured Scoop toolchain rather than a developer-specific path' {
        if ($env:SCOOP_HOME) {
            $script:scoopHome | Should -BeExactly $env:SCOOP_HOME
        } else {
            $script:scoopHome | Should -BeExactly (Join-Path $env:USERPROFILE 'scoop/apps/scoop/current')
        }
    }

    BeforeEach {
        $script:caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:caseRoot)
        $script:beforeText = New-TestManifest
        $script:afterText = New-TestManifest -Version '2.0'
        $script:beforeBytes = [Text.Encoding]::UTF8.GetBytes($script:beforeText)
        $script:afterBytes = [Text.Encoding]::UTF8.GetBytes($script:afterText)
        $script:originalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($script:beforeBytes)).ToLowerInvariant()
        $script:candidateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($script:afterBytes)).ToLowerInvariant()
        $script:pull = @{
            number = 17; state = 'open'; draft = $false
            user = @{ login = 'github-actions[bot]' }
            head = @{ sha = $script:sha; ref = 'automation/update-demo'; repo = @{ full_name = 'owner/repo' } }
            base = @{ sha = $script:base; ref = 'master'; repo = @{ full_name = 'owner/repo' } }
        }
        $script:baseState = @{ Sha = $script:base; ManifestSha256 = $script:originalHash; Bytes = $script:beforeBytes; PolicyDigest = $script:policy }
        $script:snapshot = @{ Pull = $script:pull; BaseSha = $script:base; BaseBytes = $script:beforeBytes; HeadBytes = $script:afterBytes; PolicyDigest = $script:policy }
        $script:common = @{
            Repository = 'owner/repo'; App = 'demo'; BaseBranch = 'master'
            PrNumber = 17; ExpectedHead = $script:sha; ScoopHome = $script:scoopHome
            RunId = '123'; RunAttempt = '2'; Enabled = 'true'; Publish = $true
            OutputDirectory = (Join-Path $script:caseRoot 'output')
            RepositoryDirectory = $script:caseRoot
        }
        $script:validationPath = Join-Path $script:caseRoot 'validation.json'
        $script:evidence = @{
            schema = 1; status = 'success'; repository = 'owner/repo'; prNumber = 17
            app = 'demo'; headSha = $script:sha; baseSha = $script:base
            baselineSha256 = $script:originalHash; candidateSha256 = $script:candidateHash
            policyDigest = $script:policy; runId = '123'; runAttempt = '2'
            verifiedAssetCount = 1; declaredAssetCount = 1
            assets = @(@{ url = 'https://example.com/app.zip'; sha256 = ('0' * 64); bytes = 10; layout = @{ kind = 'zip' } })
            runUrl = 'https://github.com/owner/repo/actions/runs/123/attempts/2'
        }
        $script:evidence | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:validationPath -Encoding utf8NoBOM
        Mock Get-GithubPull -ModuleName github-update { $script:pull }
        Mock Get-GithubPullSnapshot -ModuleName github-update { $script:snapshot }
        Mock Get-GithubBaseState -ModuleName github-update { $script:baseState }
        Mock Assert-GithubPolicyCheckout -ModuleName github-update { }
        Mock Assert-ManifestSchema -ModuleName github-update { }
        Mock Get-ManifestUpdateDecision -ModuleName github-update { @{ Allowed = $true; Reason = 'allowed'; Assets = @(@{ Url = 'https://example.com/app-2.0.zip'; Hash = '0' * 64 }) } }
        Mock Invoke-GithubAssetVerification -ModuleName github-update { @{ VerifiedAssetCount = 1; DeclaredAssetCount = 1; Assets = @(@{ url = 'https://example.com/app.zip'; sha256 = ('0' * 64); bytes = 10; layout = @{ kind = 'zip' } }) } }
        Mock Assert-GithubManagedBranch -ModuleName github-update { @{ ExistingPr = 17; HeadSha = $script:sha } }
        Mock Invoke-GithubApi -ModuleName github-update { throw 'Unexpected GitHub call' }
        Mock Invoke-GithubWorkflowDispatch -ModuleName github-update { }
        Mock Write-GithubActionOutput -ModuleName github-update { }
    }

    It 'performs no dispatch/status/merge writes with enabled=<Enabled> and publish=<Publish>' -ForEach @(
        @{ Enabled = 'false'; Publish = $true }
        @{ Enabled = 'TRUE'; Publish = $true }
        @{ Enabled = 'true'; Publish = $false }
        @{ Enabled = ''; Publish = $false }
    ) {
        $script:common.Enabled = $Enabled
        $script:common.Publish = $Publish
        foreach ($mode in @('Dispatch', 'Status', 'Merge')) {
            $result = Invoke-GithubUpdate -Mode $mode @script:common -ValidationPath $script:validationPath -ValidationSucceeded:$true
            $result.Published | Should -BeFalse
            foreach ($flag in @('staged', 'dispatched', 'statusPosted', 'merged', 'published')) {
                @($result.Keys) -ccontains $flag | Should -BeTrue
                $result[$flag] -is [bool] | Should -BeTrue
                $result[$flag] | Should -BeFalse
            }
        }
        Should -Invoke Invoke-GithubApi -ModuleName github-update -Times 0
        Should -Invoke Invoke-GithubWorkflowDispatch -ModuleName github-update -Times 0
    }

    It 'dispatches the trusted workflow with exact identity and retries unchanged heads' {
        1..2 | ForEach-Object {
            $result = Invoke-GithubUpdate -Mode Dispatch @script:common
            $result.dispatched | Should -BeTrue
            $result.staged | Should -BeFalse
            $result.statusPosted | Should -BeFalse
            $result.merged | Should -BeFalse
        }
        Should -Invoke Invoke-GithubWorkflowDispatch -ModuleName github-update -Times 2 -Exactly -ParameterFilter {
            $Repository -eq 'owner/repo' -and $BaseBranch -eq 'master' -and
            $PrNumber -eq 17 -and $ExpectedHead -eq ('a' * 40) -and $App -eq 'demo' -and $Publish -is [bool] -and $Publish
        }
    }

    It 'does not silently swallow a denied dispatch' {
        Mock Invoke-GithubWorkflowDispatch -ModuleName github-update { throw 'workflow dispatch denied' }
        { Invoke-GithubUpdate -Mode Dispatch @script:common } | Should -Throw '*dispatch denied*'
    }

    It 'rejects a fork, human owner, wrong branch, wrong base, draft, closed PR, or moved head' -ForEach @(
        @{ Field = 'fork' }; @{ Field = 'human' }; @{ Field = 'branch' }; @{ Field = 'base' }
        @{ Field = 'draft' }; @{ Field = 'closed' }; @{ Field = 'head' }
    ) {
        switch ($Field) {
            fork { $script:pull.head.repo.full_name = 'fork/repo' }
            human { $script:pull.user.login = 'someone' }
            branch { $script:pull.head.ref = 'human/demo' }
            base { $script:pull.base.ref = 'develop' }
            draft { $script:pull.draft = $true }
            closed { $script:pull.state = 'closed' }
            head { $script:pull.head.sha = 'f' * 40 }
        }
        { Invoke-GithubUpdate -Mode Dispatch @script:common } | Should -Throw
        Should -Invoke Invoke-GithubWorkflowDispatch -ModuleName github-update -Times 0
    }

    It 'writes successful head status only for this successful nonempty validation' {
        Mock Invoke-GithubApi -ModuleName github-update { @{ state = 'success'; context = 'scoop/update-validation'; target_url = 'https://github.com/owner/repo/actions/runs/123/attempts/2'; creator = @{ login = 'github-actions[bot]' } } }
        $result = Invoke-GithubUpdate -Mode Status @script:common -ValidationPath $script:validationPath -ValidationSucceeded:$true
        $result.Published | Should -BeTrue
        $result.statusPosted | Should -BeTrue
        $result.merged | Should -BeFalse
        Should -Invoke Invoke-GithubApi -ModuleName github-update -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq ('repos/owner/repo/statuses/' + ('a' * 40)) -and
            $Body.context -eq 'scoop/update-validation' -and $Body.state -eq 'success' -and
            $Body.target_url -eq 'https://github.com/owner/repo/actions/runs/123/attempts/2'
        }
    }

    It 'does not report statusPosted when GitHub confirms a different context, run or creator' -ForEach @(
        @{ Invalid = 'context' }; @{ Invalid = 'run' }; @{ Invalid = 'creator' }
    ) {
        $script:statusResponse = @{ state = 'success'; context = 'scoop/update-validation'; target_url = 'https://github.com/owner/repo/actions/runs/123/attempts/2'; creator = @{ login = 'github-actions[bot]' } }
        if ($Invalid -eq 'context') { $script:statusResponse.context = 'unrelated/status' }
        if ($Invalid -eq 'run') { $script:statusResponse.target_url = 'https://github.com/owner/repo/actions/runs/122/attempts/1' }
        if ($Invalid -eq 'creator') { $script:statusResponse.creator.login = 'human' }
        Mock Invoke-GithubApi -ModuleName github-update { $script:statusResponse }
        { Invoke-GithubUpdate -Mode Status @script:common -ValidationPath $script:validationPath -ValidationSucceeded:$true } | Should -Throw '*confirm*'
    }

    It 'records failure rather than green when the current validation job failed or was canceled' {
        Mock Invoke-GithubApi -ModuleName github-update { @{ state = 'failure'; context = 'scoop/update-validation'; target_url = 'https://github.com/owner/repo/actions/runs/123/attempts/2'; creator = @{ login = 'github-actions[bot]' } } }
        $result = Invoke-GithubUpdate -Mode Status @script:common -ValidationPath $script:validationPath -ValidationSucceeded:$false
        $result.statusPosted | Should -BeTrue
        $result.merged | Should -BeFalse
        Should -Invoke Invoke-GithubApi -ModuleName github-update -Times 1 -ParameterFilter { $Body.state -eq 'failure' }
        { Invoke-GithubUpdate -Mode Merge @script:common -ValidationPath $script:validationPath -ValidationSucceeded:$false } | Should -Throw
    }

    It 'rejects empty, stale-run, stale-attempt, failed or wrong-head evidence instead of reusing a green status' -ForEach @(
        @{ Invalid = 'empty' }; @{ Invalid = 'run' }; @{ Invalid = 'attempt' }; @{ Invalid = 'failure' }; @{ Invalid = 'head' }; @{ Invalid = 'noAssets' }; @{ Invalid = 'schemaType' }; @{ Invalid = 'countType' }
    ) {
        switch ($Invalid) {
            empty { $script:evidence.verifiedAssetCount = 0 }
            run { $script:evidence.runId = '122' }
            attempt { $script:evidence.runAttempt = '1' }
            failure { $script:evidence.status = 'failure' }
            head { $script:evidence.headSha = 'e' * 40 }
            noAssets { $script:evidence.assets = @() }
            schemaType { $script:evidence.schema = '1' }
            countType { $script:evidence.declaredAssetCount = $true }
        }
        $script:evidence | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:validationPath
        { Invoke-GithubUpdate -Mode Merge @script:common -ValidationPath $script:validationPath -ValidationSucceeded:$true } | Should -Throw
        Should -Invoke Invoke-GithubApi -ModuleName github-update -Times 0
    }

    It 'requires a successful status from this exact run, not historical green on the same SHA' {
        Mock Invoke-GithubApi -ModuleName github-update {
            if ($Method -eq 'GET') { return @(@{ context = 'scoop/update-validation'; state = 'success'; creator = @{ login = 'github-actions[bot]' }; target_url = 'https://github.com/owner/repo/actions/runs/122/attempts/1' }) }
            throw 'merge must not happen'
        }
        { Invoke-GithubUpdate -Mode Merge @script:common -ValidationPath $script:validationPath -ValidationSucceeded:$true } | Should -Throw '*status*'
        Should -Invoke Invoke-GithubApi -ModuleName github-update -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'merges using SHA-bound squash only after evidence, fresh inputs and current-run status' {
        Mock Invoke-GithubApi -ModuleName github-update {
            if ($Method -eq 'GET') { return @(@{ context = 'scoop/update-validation'; state = 'success'; creator = @{ login = 'github-actions[bot]' }; target_url = 'https://github.com/owner/repo/actions/runs/123/attempts/2' }) }
            return @{ merged = $true }
        }
        $result = Invoke-GithubUpdate -Mode Merge @script:common -ValidationPath $script:validationPath -ValidationSucceeded:$true
        $result.Merged | Should -BeTrue
        $result.published | Should -BeTrue
        $result.staged | Should -BeFalse
        $result.dispatched | Should -BeFalse
        $result.statusPosted | Should -BeFalse
        Should -Invoke Invoke-GithubApi -ModuleName github-update -Times 1 -ParameterFilter {
            $Method -eq 'PUT' -and $Endpoint -eq 'repos/owner/repo/pulls/17/merge' -and
            $Body.sha -eq ('a' * 40) -and $Body.merge_method -eq 'squash'
        }
    }

    It 'does not report success for HTTP 200 merged=false or denied merge' {
        Mock Invoke-GithubApi -ModuleName github-update {
            if ($Method -eq 'GET') { return @(@{ context = 'scoop/update-validation'; state = 'success'; creator = @{ login = 'github-actions[bot]' }; target_url = 'https://github.com/owner/repo/actions/runs/123/attempts/2' }) }
            return @{ merged = $false; message = 'Required review is missing' }
        }
        { Invoke-GithubUpdate -Mode Merge @script:common -ValidationPath $script:validationPath -ValidationSucceeded:$true } | Should -Throw '*not merged*'
    }

    It 'rejects relevant target or policy changes since validation' -ForEach @(@{ Change = 'target' }, @{ Change = 'policy' }) {
        if ($Change -eq 'target') { $script:baseState.ManifestSha256 = 'f' * 64 }
        else { $script:baseState.PolicyDigest = 'f' * 64 }
        { Invoke-GithubUpdate -Mode Merge @script:common -ValidationPath $script:validationPath -ValidationSucceeded:$true } | Should -Throw '*stale*'
        Should -Invoke Invoke-GithubApi -ModuleName github-update -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'does not invalidate other package merges when relevant inputs are unchanged' {
        $script:baseState.Sha = $script:newBase
        Mock Invoke-GithubApi -ModuleName github-update {
            if ($Method -eq 'GET') { return @(@{ context = 'scoop/update-validation'; state = 'success'; creator = @{ login = 'github-actions[bot]' }; target_url = 'https://github.com/owner/repo/actions/runs/123/attempts/2' }) }
            return @{ merged = $true }
        }
        (Invoke-GithubUpdate -Mode Merge @script:common -ValidationPath $script:validationPath -ValidationSucceeded:$true).Merged | Should -BeTrue
    }

    It 'validates without writes and emits complete head/run-bound evidence' {
        $script:common.Publish = $false
        $result = Invoke-GithubUpdate -Mode Validate @script:common
        foreach ($flag in @('staged', 'dispatched', 'statusPosted', 'merged', 'published')) { $result[$flag] | Should -BeFalse }
        $evidence = Get-Content -LiteralPath $result.ValidationPath -Raw | ConvertFrom-Json -AsHashtable
        $evidence.status | Should -Be 'success'
        $evidence.verifiedAssetCount | Should -Be 1
        $evidence.headSha | Should -Be $script:sha
        $evidence.runAttempt | Should -Be '2'
        $evidence.baselineSha256 | Should -Be $script:originalHash
        Should -Invoke Invoke-GithubApi -ModuleName github-update -Times 0
    }

    It 'emits failure evidence and throws for partial or empty asset validation' -ForEach @(@{ Count = 0 }, @{ Count = 1 }) {
        $script:verifiedCount = $Count
        Mock Invoke-GithubAssetVerification -ModuleName github-update { @{ VerifiedAssetCount = $script:verifiedCount; DeclaredAssetCount = 2; Assets = @() } }
        { Invoke-GithubUpdate -Mode Validate @script:common } | Should -Throw
        $evidence = Get-Content -LiteralPath (Join-Path $script:common.OutputDirectory 'validation.json') -Raw | ConvertFrom-Json
        $evidence.status | Should -Be 'failure'
        $evidence.baseSha | Should -Be $script:base
        $evidence.baselineSha256 | Should -Be $script:originalHash
        $evidence.candidateSha256 | Should -Be $script:candidateHash
        $evidence.policyDigest | Should -Be $script:policy
    }

    It 'retains failure evidence even when validation context is malformed' {
        $script:common.App = '..'
        { Invoke-GithubUpdate -Mode Validate @script:common } | Should -Throw
        $path = Join-Path $script:common.OutputDirectory 'validation.json'
        $path | Should -Exist
        $evidence = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $evidence.status | Should -Be 'failure'
        $evidence.runId | Should -Be '123'
        $evidence.headSha | Should -Be $script:sha
        Should -Invoke Get-GithubPullSnapshot -ModuleName github-update -Times 0
        Should -Invoke Invoke-GithubApi -ModuleName github-update -Times 0
    }

    It 'does not execute or accept structural changes prohibited by core policy' {
        Mock Get-ManifestUpdateDecision -ModuleName github-update { @{ Allowed = $false; Reason = 'installer changed'; Assets = @() } }
        { Invoke-GithubUpdate -Mode Validate @script:common } | Should -Throw '*installer changed*'
        Should -Invoke Invoke-GithubAssetVerification -ModuleName github-update -Times 0
    }

    It 'stages only candidate.json and does not copy with the gate closed' {
        $candidate = Join-Path $script:caseRoot 'candidate'
        [void][IO.Directory]::CreateDirectory($candidate)
        [IO.File]::WriteAllBytes((Join-Path $candidate 'candidate.json'), $script:afterBytes)
        @{
            schema = 1; app = 'demo'; status = 'updated'; reason = 'updated'; baseSha = $script:base
            runId = '123'; runAttempt = '2'; originalSha256 = $script:originalHash
            candidateSha256 = $script:candidateHash; oldVersion = '1.0'; newVersion = '2.0'; sourceResolved = $true
        } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $candidate 'result.json')
        [void][IO.Directory]::CreateDirectory((Join-Path $script:caseRoot 'bucket'))
        [IO.File]::WriteAllBytes((Join-Path $script:caseRoot 'bucket/demo.json'), $script:beforeBytes)
        $script:common.Publish = $false
        $result = Invoke-GithubUpdate -Mode Stage @script:common -CandidateDirectory $candidate -BaseSha $script:base
        $result.Staged | Should -BeFalse
        foreach ($flag in @('staged', 'dispatched', 'statusPosted', 'merged', 'published')) { $result[$flag] | Should -BeFalse }
        (Get-FileHash (Join-Path $script:caseRoot 'bucket/demo.json')).Hash.ToLowerInvariant() | Should -Be $script:originalHash
        $script:common.Publish = $true
        $result = Invoke-GithubUpdate -Mode Stage @script:common -CandidateDirectory $candidate -BaseSha $script:base
        $result.Staged | Should -BeTrue
        $result.dispatched | Should -BeFalse
        $result.statusPosted | Should -BeFalse
        $result.merged | Should -BeFalse
        $result.published | Should -BeFalse
        $result.ExistingPr | Should -Be 17
        (Get-FileHash (Join-Path $script:caseRoot 'bucket/demo.json')).Hash.ToLowerInvariant() | Should -Be $script:candidateHash
        @(Get-ChildItem (Join-Path $script:caseRoot 'bucket')).Count | Should -Be 1
    }

    It 'rejects a candidate from another run, tampered bytes, or unexpected artifact file' -ForEach @(
        @{ Tamper = 'run' }; @{ Tamper = 'hash' }; @{ Tamper = 'extra' }; @{ Tamper = 'schemaType' }
    ) {
        $candidate = Join-Path $script:caseRoot 'candidate'
        [void][IO.Directory]::CreateDirectory($candidate)
        [IO.File]::WriteAllBytes((Join-Path $candidate 'candidate.json'), $script:afterBytes)
        $result = @{
            schema = 1; app = 'demo'; status = 'updated'; reason = 'updated'; baseSha = $script:base
            runId = '123'; runAttempt = '2'; originalSha256 = $script:originalHash
            candidateSha256 = $script:candidateHash; oldVersion = '1.0'; newVersion = '2.0'; sourceResolved = $true
        }
        $script:common.Publish = $false
        if ($Tamper -eq 'schemaType') { $result.schema = '1' }
        if ($Tamper -eq 'run') { $result.runId = '122' }
        if ($Tamper -eq 'hash') { $result.candidateSha256 = '0' * 64 }
        if ($Tamper -eq 'extra') { Set-Content -LiteralPath (Join-Path $candidate 'payload.ps1') -Value 'throw "not executable"' }
        $result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $candidate 'result.json')
        { Invoke-GithubUpdate -Mode Stage @script:common -CandidateDirectory $candidate -BaseSha $script:base } | Should -Throw
    }

    It 'checks the original trusted worker base even if the current target happens to match a tampered artifact' {
        $candidate = Join-Path $script:caseRoot 'candidate'
        [void][IO.Directory]::CreateDirectory($candidate)
        [IO.File]::WriteAllBytes((Join-Path $candidate 'candidate.json'), $script:afterBytes)
        @{
            schema = 1; app = 'demo'; status = 'updated'; reason = 'updated'; baseSha = $script:base
            runId = '123'; runAttempt = '2'; originalSha256 = $script:originalHash; candidateSha256 = $script:candidateHash
            oldVersion = '1.0'; newVersion = '2.0'; sourceResolved = $true
        } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $candidate 'result.json')
        $script:baseState.Sha = $script:newBase
        $script:common.Publish = $false
        $script:sourceRequested = ''
        $script:baseReadCount = 0
        Mock Get-GithubBaseState -ModuleName github-update {
            param([string]$CommitSha = '')
            Set-StrictMode -Version Latest
            $script:baseReadCount++
            if ($CommitSha) {
                $script:sourceRequested = $CommitSha
                return @{ Sha = ('b' * 40); ManifestSha256 = ('f' * 64) }
            }
            return $script:baseState
        }
        { Invoke-GithubUpdate -Mode Stage @script:common -CandidateDirectory $candidate -BaseSha $script:base } | Should -Throw '*source base*'
        $script:sourceRequested | Should -BeExactly $script:base
        $script:baseReadCount | Should -Be 2
    }

    It 'rereads the PR head immediately before merge and refuses a moved head' {
        $script:pullReads = 0
        Mock Get-GithubPull -ModuleName github-update {
            $script:pullReads++
            if ($script:pullReads -ge 2) { $script:pull.head.sha = 'f' * 40 }
            return $script:pull
        }
        Mock Invoke-GithubApi -ModuleName github-update { @(@{ context = 'scoop/update-validation'; state = 'success'; creator = @{ login = 'github-actions[bot]' }; target_url = 'https://github.com/owner/repo/actions/runs/123/attempts/2' }) }
        { Invoke-GithubUpdate -Mode Merge @script:common -ValidationPath $script:validationPath -ValidationSucceeded:$true } | Should -Throw '*identity*'
        Should -Invoke Invoke-GithubApi -ModuleName github-update -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'refuses to overwrite an existing branch with unexpected human commits' {
        Mock Assert-GithubManagedBranch -ModuleName github-update { throw 'Human commits on managed branch' }
        { Invoke-GithubUpdate -Mode Dispatch @script:common } | Should -Throw '*Human commits*'
        Should -Invoke Invoke-GithubWorkflowDispatch -ModuleName github-update -Times 0
    }
}

Describe 'GitHub immutable tree and policy boundary' {
    BeforeEach {
        Mock Invoke-GithubApi -ModuleName github-api { throw "Unexpected offline API endpoint: $Endpoint" }
        $script:treeBefore = @{
            'bucket/demo.json' = @{ type = 'blob'; mode = '100644'; sha = ('1' * 40); size = 10 }
            'bin/tool.ps1' = @{ type = 'blob'; mode = '100644'; sha = ('2' * 40) }
        }
        $script:treeAfter = @{
            'bucket/demo.json' = @{ type = 'blob'; mode = '100644'; sha = ('3' * 40); size = 10 }
            'bin/tool.ps1' = @{ type = 'blob'; mode = '100644'; sha = ('2' * 40) }
        }
    }

    It 'proves the full tree delta is one existing regular manifest' {
        { Assert-GithubSingleManifestDiff -BeforeTree $script:treeBefore -AfterTree $script:treeAfter -App demo } | Should -Not -Throw
    }

    It 'rejects hidden extra paths, deletion, addition, symlink, or executable mode changes' -ForEach @(
        @{ Change = 'extra' }; @{ Change = 'delete' }; @{ Change = 'add' }; @{ Change = 'link' }; @{ Change = 'mode' }
    ) {
        switch ($Change) {
            extra { $script:treeAfter['bin/tool.ps1'].sha = '4' * 40 }
            delete { $script:treeAfter.Remove('bucket/demo.json') }
            add { $script:treeBefore.Remove('bucket/demo.json') }
            link { $script:treeAfter['bucket/demo.json'].mode = '120000' }
            mode { $script:treeAfter['bucket/demo.json'].mode = '100755' }
        }
        { Assert-GithubSingleManifestDiff -BeforeTree $script:treeBefore -AfterTree $script:treeAfter -App demo } | Should -Throw
    }

    It 'rejects oversized manifest blobs from tree metadata before downloading their API content' {
        $script:treeAfter['bucket/demo.json'].size = 2097153
        { Assert-GithubSingleManifestDiff -BeforeTree $script:treeBefore -AfterTree $script:treeAfter -App demo } | Should -Throw '*bounded*'
    }

    It 'reads recursive Git trees and rejects truncated or duplicate data' {
        Mock Invoke-GithubApi -ModuleName github-api {
            if ($Endpoint -match '/git/commits/') { return @{ tree = @{ sha = ('e' * 40) } } }
            return @{ truncated = $false; tree = @(@{ path = 'bucket/demo.json'; type = 'blob'; mode = '100644'; sha = ('3' * 40) }) }
        }
        (Get-GithubTree -Repository owner/repo -Sha $script:sha).Count | Should -Be 1
        Mock Invoke-GithubApi -ModuleName github-api {
            if ($Endpoint -match '/git/commits/') { return @{ tree = @{ sha = ('e' * 40) } } }
            return @{ truncated = $true; tree = @() }
        }
        { Get-GithubTree -Repository owner/repo -Sha $script:sha } | Should -Throw '*truncated*'
    }

    It 'uses the merge-base full tree diff rather than invalidating unrelated base changes' {
        Mock Invoke-GithubApi -ModuleName github-api { @{ total_commits = 1; merge_base_commit = @{ sha = ('d' * 40) }; commits = @(@{ author = @{ login = 'github-actions[bot]' }; committer = @{ login = 'github-actions[bot]' }; commit = @{ verification = @{ verified = $true; reason = 'valid' } } }) } }
        Mock Get-GithubTree -ModuleName github-api {
            if ($Sha -eq ('d' * 40)) { return $script:treeBefore }
            return $script:treeAfter
        }
        $change = Get-GithubBranchChange -Repository owner/repo -BaseSha $script:newBase -HeadSha $script:sha -App demo
        $change.AfterTree['bucket/demo.json'].sha | Should -Be ('3' * 40)
    }

    It 'allows safely resetting an integrated branch but never an empty open-PR diff' {
        Mock Invoke-GithubApi -ModuleName github-api { @{ total_commits = 0; status = 'behind'; merge_base_commit = @{ sha = ('a' * 40) }; commits = @() } }
        (Get-GithubBranchChange -Repository owner/repo -BaseSha $script:newBase -HeadSha $script:sha -App demo -AllowIntegrated).Integrated | Should -BeTrue
        { Get-GithubBranchChange -Repository owner/repo -BaseSha $script:newBase -HeadSha $script:sha -App demo } | Should -Throw '*empty*'
    }

    It 'rejects human branch commits and incomplete commit histories' -ForEach @(@{ Invalid = 'author' }, @{ Invalid = 'committer' }, @{ Invalid = 'incomplete' }, @{ Invalid = 'unsigned' }) {
        $script:comparison = @{ total_commits = 1; merge_base_commit = @{ sha = ('d' * 40) }; commits = @(@{ author = @{ login = 'github-actions[bot]' }; committer = @{ login = 'github-actions[bot]' }; commit = @{ verification = @{ verified = $true; reason = 'valid' } } }) }
        if ($Invalid -eq 'author') { $script:comparison.commits[0].author.login = 'human' }
        if ($Invalid -eq 'committer') { $script:comparison.commits[0].committer.login = 'human' }
        if ($Invalid -eq 'incomplete') { $script:comparison.total_commits = 251 }
        if ($Invalid -eq 'unsigned') { $script:comparison.commits[0].commit.verification.verified = $false }
        Mock Invoke-GithubApi -ModuleName github-api { $script:comparison }
        Mock Get-GithubTree -ModuleName github-api {
            if ($Sha -eq ('d' * 40)) { return $script:treeBefore }
            return $script:treeAfter
        }
        { Get-GithubBranchChange -Repository owner/repo -BaseSha $script:base -HeadSha $script:sha -App demo } | Should -Throw
    }

    It 'retrieves bounded UTF8 blob bytes and rejects malformed base64 or sizes' {
        $script:bytes = [Text.Encoding]::UTF8.GetBytes('{"version":"1"}')
        Mock Invoke-GithubApi -ModuleName github-api { @{ encoding = 'base64'; size = $script:bytes.Length; content = [Convert]::ToBase64String($script:bytes) } }
        [Text.Encoding]::UTF8.GetString((Get-GithubBlobData -Repository owner/repo -BlobSha $script:sha)) | Should -Be '{"version":"1"}'
        Mock Invoke-GithubApi -ModuleName github-api { @{ encoding = 'base64'; size = 2097153; content = '' } }
        { Get-GithubBlobData -Repository owner/repo -BlobSha $script:sha } | Should -Throw
    }

    It 'reads the current base manifest and policy fingerprint independently of PR data' {
        Mock Invoke-GithubApi -ModuleName github-api { @{ object = @{ sha = ('b' * 40) } } }
        Mock Get-GithubTree -ModuleName github-api { $script:treeBefore }
        Mock Get-GithubBlobData -ModuleName github-api { [Text.Encoding]::UTF8.GetBytes('base bytes') }
        Mock Get-GithubPolicyDigest -ModuleName github-api { 'd' * 64 }
        $base = Get-GithubBaseState -Repository owner/repo -BaseBranch master -App demo -ScoopHome $script:scoopHome
        $base.Sha | Should -Be $script:base
        $base.PolicyDigest | Should -Be $script:policy
        $base.ManifestSha256.Length | Should -Be 64
        $script:treeBefore.Remove('bucket/demo.json')
        { Get-GithubBaseState -Repository owner/repo -BaseBranch master -App demo -ScoopHome $script:scoopHome } | Should -Throw '*regular file*'
    }

    It 'reads candidate bytes from immutable Git blobs and rejects a relevant merge-base mismatch' {
        $script:baseBytes = [Text.Encoding]::UTF8.GetBytes('original')
        $script:headBytes = [Text.Encoding]::UTF8.GetBytes('candidate')
        $script:baseHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($script:baseBytes)).ToLowerInvariant()
        Mock Invoke-GithubApi -ModuleName github-api { @{ number = 17 } }
        Mock Get-GithubBaseState -ModuleName github-api { @{ Sha = ('b' * 40); Bytes = $script:baseBytes; ManifestSha256 = $script:baseHash; PolicyDigest = ('d' * 64) } }
        Mock Get-GithubBranchChange -ModuleName github-api { @{ BeforeTree = $script:treeBefore; AfterTree = $script:treeAfter } }
        Mock Get-GithubBlobData -ModuleName github-api {
            if ($BlobSha -eq ('1' * 40)) { return $script:baseBytes }
            return $script:headBytes
        }
        $snapshot = Get-GithubPullSnapshot -Repository owner/repo -PrNumber 17 -ExpectedHead $script:sha -BaseBranch master -App demo -ScoopHome $script:scoopHome
        [Text.Encoding]::UTF8.GetString($snapshot.HeadBytes) | Should -Be 'candidate'
        $script:baseHash = 'f' * 64
        { Get-GithubPullSnapshot -Repository owner/repo -PrNumber 17 -ExpectedHead $script:sha -BaseBranch master -App demo -ScoopHome $script:scoopHome } | Should -Throw '*target manifest changed*'
    }

    It 'fingerprints trusted policy inputs but ignores unrelated bucket manifests' {
        $tree = @{
            'bin/manifest-policy.psm1' = @{ type = 'blob'; mode = '100644'; sha = ('1' * 40); size = 10 }
            'bin/github-update.ps1' = @{ type = 'blob'; mode = '100644'; sha = ('2' * 40) }
            '.github/workflows/validate-update.yml' = @{ type = 'blob'; mode = '100644'; sha = ('3' * 40); size = 10 }
            '.github/actions/setup-scoop/action.yml' = @{ type = 'blob'; mode = '100644'; sha = ('7' * 40) }
            'bucket/other.json' = @{ type = 'blob'; mode = '100644'; sha = ('4' * 40) }
        }
        $digest = Get-GithubPolicyDigest -Tree $tree -ScoopHome $script:scoopHome
        $tree['bucket/other.json'].sha = '5' * 40
        (Get-GithubPolicyDigest -Tree $tree -ScoopHome $script:scoopHome) | Should -Be $digest
        $tree['.github/actions/setup-scoop/action.yml'].sha = '8' * 40
        $compositeDigest = Get-GithubPolicyDigest -Tree $tree -ScoopHome $script:scoopHome
        $compositeDigest | Should -Not -Be $digest
        $digest = $compositeDigest
        $tree['bin/manifest-policy.psm1'].sha = '6' * 40
        (Get-GithubPolicyDigest -Tree $tree -ScoopHome $script:scoopHome) | Should -Not -Be $digest
        $tree['bin/manifest-policy.psm1'].mode = '120000'
        { Get-GithubPolicyDigest -Tree $tree -ScoopHome $script:scoopHome } | Should -Throw '*regular file*'
    }

    It 'binds remote policy to the trusted checkout actually executed, not a newer concurrent policy' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'bin'))
        $script:checkoutTree = @{}
        foreach ($path in @('bin/manifest-policy.psm1', 'bin/github-update.ps1', '.github/actions/setup-scoop/action.yml')) {
            $bytes = [Text.Encoding]::UTF8.GetBytes("# trusted fixture`n")
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName((Join-Path $root $path)))
            [IO.File]::WriteAllBytes((Join-Path $root $path), $bytes)
            $header = [Text.Encoding]::UTF8.GetBytes("blob $($bytes.Length)`0")
            $sha = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($header + $bytes))).ToLowerInvariant()
            $script:checkoutTree[$path] = @{ type = 'blob'; mode = '100644'; sha = $sha }
        }
        Mock Get-GithubTree -ModuleName github-api { $script:checkoutTree }
        { Assert-GithubPolicyCheckout -Repository owner/repo -BaseSha $script:base -RepositoryDirectory $root } | Should -Not -Throw
        [IO.File]::WriteAllBytes((Join-Path $root 'bin/github-update.ps1'), [Text.Encoding]::UTF8.GetBytes("# trusted fixture`r`n"))
        { Assert-GithubPolicyCheckout -Repository owner/repo -BaseSha $script:base -RepositoryDirectory $root } | Should -Throw '*checkout*'
        Add-Content -LiteralPath (Join-Path $root 'bin/github-update.ps1') -Value '# not the policy recorded in evidence'
        { Assert-GithubPolicyCheckout -Repository owner/repo -BaseSha $script:base -RepositoryDirectory $root } | Should -Throw '*checkout*'
    }

    It 'handles a genuinely absent branch but rejects duplicate PRs without writing' {
        Mock Invoke-GithubApi -ModuleName github-api {
            if ($Endpoint -match '/pulls\?') { return @() }
            $error = [InvalidOperationException]::new('not found')
            $error.Data['HttpStatus'] = 404
            throw $error
        }
        (Assert-GithubManagedBranch -Repository owner/repo -App demo -BaseBranch master -BaseSha $script:base).ExistingPr | Should -Be 0
        Mock Invoke-GithubApi -ModuleName github-api { @(@{ number = 17 }, @{ number = 18 }) }
        { Assert-GithubManagedBranch -Repository owner/repo -App demo -BaseBranch master -BaseSha $script:base } | Should -Throw '*Multiple*'
    }

    It 'escapes plus signs in the managed branch query and still inspects its existing PR' {
        Mock Get-GithubBranchChange -ModuleName github-api { @{ Integrated = $false } }
        Mock Invoke-GithubApi -ModuleName github-api {
            if ($Endpoint -match '/pulls\?') {
                if (-not $Endpoint.Contains('&head=owner%3Aautomation%2Fupdate-redpanda-c%2B%2B&')) { return @() }
                return @(@{ number = 19; draft = $false; user = @{ login = 'github-actions[bot]' }; head = @{ sha = ('a' * 40); ref = 'automation/update-redpanda-c++'; repo = @{ full_name = 'owner/repo' } }; base = @{ ref = 'master'; repo = @{ full_name = 'owner/repo' } } })
            }
            return @{ object = @{ sha = ('a' * 40) } }
        }
        $managed = Assert-GithubManagedBranch -Repository owner/repo -App 'redpanda-c++' -BaseBranch master -BaseSha $script:base
        $managed.ExistingPr | Should -Be 19
        Should -Invoke Get-GithubBranchChange -ModuleName github-api -Times 1 -ParameterFilter { $App -ceq 'redpanda-c++' -and $HeadSha -ceq ('a' * 40) }
    }

    It 'does not create duplicate PRs when a managed branch and PR already exist' {
        Mock Get-GithubBranchChange -ModuleName github-api { @{ BeforeTree = $script:treeBefore; AfterTree = $script:treeAfter } }
        Mock Invoke-GithubApi -ModuleName github-api {
            if ($Endpoint -match '/pulls\?') { return @(@{ number = 17; draft = $false; user = @{ login = 'github-actions[bot]' }; head = @{ sha = ('a' * 40); ref = 'automation/update-demo'; repo = @{ full_name = 'owner/repo' } }; base = @{ ref = 'master'; repo = @{ full_name = 'owner/repo' } } }) }
            return @{ object = @{ sha = ('a' * 40) } }
        }
        (Assert-GithubManagedBranch -Repository owner/repo -App demo -BaseBranch master -BaseSha $script:base).ExistingPr | Should -Be 17
        Should -Invoke Invoke-GithubApi -ModuleName github-api -Times 1 -ParameterFilter { $Endpoint -match '/pulls\?' -and $Endpoint -notmatch '&base=' }
        Should -Invoke Invoke-GithubApi -ModuleName github-api -Times 0 -ParameterFilter { $Method -eq 'POST' -or $Method -eq 'PUT' }
    }
}

Describe 'Bounded asset verification without network or execution' {
    BeforeAll {
        function New-TestZip {
            param([string]$Path, [string[]]$Names)
            $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($name in $Names) {
                    $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::NoCompression)
                    $stream = $entry.Open()
                    try { $stream.Write([byte[]]@(1, 2, 3), 0, 3) } finally { $stream.Dispose() }
                }
            } finally { $archive.Dispose() }
        }
        Add-Type -TypeDefinition @'
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
public sealed class OfflineAssetHandler : HttpMessageHandler {
    public readonly Queue<HttpResponseMessage> Responses = new Queue<HttpResponseMessage>();
    public readonly List<string> Requests = new List<string>();
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        Requests.Add(request.RequestUri.AbsoluteUri);
        return Task.FromResult(Responses.Dequeue());
    }
}
'@
    }
    BeforeEach {
        $script:assetDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:assetDirectory)
    }

    It 'rejects non-HTTPS, credentials and loopback asset URIs' -ForEach @(
        @{ Url = 'http://example.com/app.zip' }; @{ Url = 'https://user:password@example.com/app.zip' }
        @{ Url = 'https://127.0.0.1/app.zip' }; @{ Url = 'file:///tmp/app.zip' }
    ) {
        { Assert-GithubAssetUri -Url $Url } | Should -Throw
    }

    It 'strips only the Scoop rename fragment without changing the source path or query' {
        (Assert-GithubAssetUri -Url 'https://example.com/app.zip?download=1#/app.7z').AbsoluteUri | Should -Be 'https://example.com/app.zip?download=1'
    }

    It 'pins public network addresses and blocks private and special ranges' {
        Initialize-GithubDownloadClient
        foreach ($address in @('127.0.0.1', '10.1.2.3', '169.254.169.254', '192.168.1.2', '172.16.0.1', '::1', 'fc00::1', '::ffff:127.0.0.1', '2001:db8::1')) {
            [ScoopMaintenance.PublicAssetClient]::IsPublic([Net.IPAddress]::Parse($address)) | Should -BeFalse
        }
        [ScoopMaintenance.PublicAssetClient]::IsPublic([Net.IPAddress]::Parse('8.8.8.8')) | Should -BeTrue
        [ScoopMaintenance.PublicAssetClient]::IsPublic([Net.IPAddress]::Parse('2606:4700:4700::1111')) | Should -BeTrue
    }

    It 'lists bounded ZIP entries and verifies extract_dir without extracting files' {
        $path = Join-Path $script:assetDirectory 'fixture.zip'
        New-TestZip -Path $path -Names @('demo-2.0/app.exe')
        (Test-GithubZipLayout -Path $path -ExtractDirectory 'demo-2.0').entries | Should -Be 1
        { Test-GithubZipLayout -Path $path -ExtractDirectory 'missing' } | Should -Throw '*not found*'
        @(Get-ChildItem -LiteralPath $script:assetDirectory).Count | Should -Be 1
    }

    It 'bounds ZIP central-directory metadata before constructing the archive reader' {
        $path = Join-Path $script:assetDirectory 'oversized-directory.zip'
        New-TestZip -Path $path -Names @('app.exe')
        $bytes = [IO.File]::ReadAllBytes($path)
        $endRecord = $bytes.Length - 22
        [BitConverter]::GetBytes([uint32]16777216).CopyTo($bytes, $endRecord + 12)
        [IO.File]::WriteAllBytes($path, $bytes)
        { Test-GithubZipLayout -Path $path } | Should -Throw '*bounded central directory*'
    }

    It 'rejects unsafe archive paths and Windows case collisions' -ForEach @(
        @{ Names = @('../escape.exe') }; @{ Names = @('/absolute.exe') }; @{ Names = @('C:/drive.exe') }
        @{ Names = @('app.exe', 'APP.exe') }; @{ Names = @('folder./app.exe') }
        @{ Names = @('NUL.txt') }; @{ Names = @('a/./app.exe', 'a/app.exe') }
    ) {
        $path = Join-Path $script:assetDirectory 'unsafe.zip'
        New-TestZip -Path $path -Names $Names
        { Test-GithubZipLayout -Path $path } | Should -Throw
    }

    It 'verifies every architecture and URL array entry in separate data directories' {
        Mock Save-GithubAsset -ModuleName github-validation { @{ Path = (Join-Path $Directory 'asset.bin'); Length = 10; Sha256 = ('a' * 64) } }
        $assets = @(
            [pscustomobject]@{ Architecture = '64bit'; Url = 'https://example.com/64.exe'; Hash = 'sha256:' + ('A' * 64) }
            [pscustomobject]@{ Architecture = '32bit'; Url = 'https://example.com/32.exe'; Hash = 'a' * 64 }
        )
        $result = Invoke-GithubAssetVerification -Assets $assets -Manifest @{} -Directory $script:assetDirectory
        $result.VerifiedAssetCount | Should -Be 2
        $result.Assets[0].layout.kind | Should -Be 'not-supported'
        Should -Invoke Save-GithubAsset -ModuleName github-validation -Times 2 -Exactly
        @(Get-ChildItem (Join-Path $script:assetDirectory 'assets') -Directory).Count | Should -Be 2
    }

    It 'rejects skipped hashes, mismatched hashes and partial asset failures' -ForEach @(
        @{ Hash = 'skip' }; @{ Hash = 'b' * 64 }
    ) {
        Mock Save-GithubAsset -ModuleName github-validation { @{ Path = (Join-Path $Directory 'asset.bin'); Length = 10; Sha256 = ('a' * 64) } }
        { Invoke-GithubAssetVerification -Assets @(@{ Url = 'https://example.com/app.exe'; Hash = $Hash }) -Manifest @{} -Directory $script:assetDirectory } | Should -Throw
    }

    It 'streams bounded bytes through an offline HTTP handler with redirects and no execution' {
        $script:handler = [OfflineAssetHandler]::new()
        $redirect = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Found)
        $redirect.Headers.Location = [Uri]::new('https://cdn.example.com/app.zip')
        $script:handler.Responses.Enqueue($redirect)
        $ok = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
        $ok.Content = [Net.Http.ByteArrayContent]::new([byte[]]@(1, 2, 3))
        $script:handler.Responses.Enqueue($ok)
        $script:client = [Net.Http.HttpClient]::new($script:handler)
        Mock Get-GithubAssetClient -ModuleName github-validation { $script:client }
        InModuleScope github-validation -Parameters @{ Directory = $script:assetDirectory } {
            param($Directory)
            $result = Save-GithubAsset -Url 'https://example.com/app.zip#/rename.zip' -Directory $Directory -MaxBytes 3
            $result.Length | Should -Be 3
            [IO.File]::ReadAllBytes($result.Path) | Should -Be @(1, 2, 3)
        }
        $script:handler.Requests.Count | Should -Be 2
    }
}

Describe 'Small native CLI boundary' {
    It 'honors ShouldProcess before creating a fresh validation data directory' {
        $path = Join-Path $TestDrive 'declined-data-directory'
        InModuleScope github-update -Parameters @{ Path = $path } {
            param($Path)
            { New-GithubDataDirectory -Path $Path -WhatIf } | Should -Throw '*declined*'
            $Path | Should -Not -Exist
        }
    }

    It 'directly invoking the thin CLI with gate off performs no network or writes' {
        $result = & (Join-Path $script:repoRoot 'bin/github-update.ps1') -Mode Merge -Repository owner/repo -App demo -RunId 123 -RunAttempt 2 -Enabled false -Publish
        ($result | ConvertFrom-Json).Published | Should -BeFalse
        $result = & (Join-Path $script:repoRoot 'bin/github-update.ps1') -Mode Dispatch -Repository owner/repo -App demo -RunId 123 -RunAttempt 2 -Enabled true
        ($result | ConvertFrom-Json).Published | Should -BeFalse
    }

    It 'checks native exit codes and does not interpret command arguments' {
        { Invoke-GithubNative -Arguments @('api', '--method', 'GET', 'repos/offline-test/no-such-repo') -Executable 'definitely-not-a-command-123' } | Should -Throw
    }

    It 'runs a fake native CLI with literal argv and checked nonzero exit code' {
        $executable = (Get-Command pwsh).Source
        $fixture = Join-Path $PSScriptRoot 'fixtures/github/native-cli.ps1'
        $result = Invoke-GithubNative -Executable $executable -Arguments @('-NoLogo', '-NoProfile', '-File', $fixture, 'literal; $(not-a-command)', 'two words') -InputText '{"sha":"literal"}' | ConvertFrom-Json
        $result.arguments[0] | Should -Be 'literal; $(not-a-command)'
        $result.arguments[1] | Should -Be 'two words'
        $result.inputText | Should -Be '{"sha":"literal"}'
        { Invoke-GithubNative -Executable $executable -Arguments @('-NoProfile', '-File', $fixture, 'exit7') } | Should -Throw '*exit code 7*'
        { Invoke-GithubNative -Executable $executable -Arguments @('-NoProfile', '-File', $fixture, 'big-error') } | Should -Throw '*bounded*'
    }

    It 'serializes write JSON over stdin and forces an explicit API method' {
        Mock Invoke-GithubNative -ModuleName github-api { '{"merged":true}' }
        $result = Invoke-GithubApi -Method PUT -Endpoint ('repos/owner/repo/pulls/17/merge') -Body @{ sha = 'a' * 40; merge_method = 'squash' } -Enabled true -Publish $true
        $result.merged | Should -BeTrue
        Should -Invoke Invoke-GithubNative -ModuleName github-api -Times 1 -ParameterFilter {
            $Arguments -contains 'PUT' -and $Arguments -contains '--input' -and
            ($InputText | ConvertFrom-Json).sha -eq ('a' * 40)
        }
    }

    It 'dispatches only the validation workflow on master and refuses direct disabled dispatch' {
        Mock Invoke-GithubNative -ModuleName github-api { '' }
        Invoke-GithubWorkflowDispatch -Repository owner/repo -BaseBranch master -PrNumber 17 -ExpectedHead $script:sha -App demo -Enabled true -Publish $true
        Should -Invoke Invoke-GithubNative -ModuleName github-api -Times 1 -ParameterFilter {
            $Arguments -contains 'validate-update.yml' -and $Arguments -contains 'master' -and $Arguments -contains 'publish=true'
        }
        { Invoke-GithubWorkflowDispatch -Repository owner/repo -BaseBranch master -PrNumber 17 -ExpectedHead $script:sha -App demo -Enabled false -Publish $true } | Should -Throw
    }

    It 'rejects empty or invalid native JSON responses and malformed API endpoints' {
        Mock Invoke-GithubNative -ModuleName github-api { '' }
        { Invoke-GithubApi -Endpoint 'repos/owner/repo/pulls/17' } | Should -Throw '*empty JSON*'
        { Invoke-GithubApi -Endpoint 'https://evil.example/api' } | Should -Throw '*endpoint*'
        Mock Invoke-GithubNative -ModuleName github-api { 'not-json' }
        { Invoke-GithubApi -Endpoint 'repos/owner/repo/pulls/17' } | Should -Throw
    }

    It 'denies direct API mutations without both publication gates' {
        Mock Invoke-GithubNative -ModuleName github-api { throw 'must not run' }
        { Invoke-GithubApi -Method POST -Endpoint 'repos/owner/repo/statuses/abc' -Body @{ state = 'success' } -Enabled 'false' -Publish $true } | Should -Throw
        { Invoke-GithubApi -Method PUT -Endpoint 'repos/owner/repo/pulls/17/merge' -Body @{} -Enabled 'true' -Publish 'true' } | Should -Throw
        Should -Invoke Invoke-GithubNative -ModuleName github-api -Times 0
    }
}
