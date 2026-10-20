BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../bin/github-api.psm1') -Force

    function New-IdentityTestCommit {
        param(
            [AllowNull()][object]$Author = @{ login = 'github-actions[bot]' },
            [AllowNull()][object]$Committer = @{ login = 'web-flow' },
            [AllowNull()][object]$Verification = @{ verified = $true; reason = 'valid' }
        )
        return @{ author = $Author; committer = $Committer; commit = @{ verification = $Verification } }
    }

    function New-IdentityTestComparison {
        param([object[]]$Commits, [int]$TotalCommits = 1)
        return @{ total_commits = $TotalCommits; merge_base_commit = @{ sha = ('d' * 40) }; commits = $Commits }
    }
}

Describe 'GitHub-signed bot commit identity boundary' {
    BeforeEach {
        $script:comparison = New-IdentityTestComparison -Commits @(New-IdentityTestCommit)
        $script:treeBefore = @{
            'bucket/demo.json' = @{ type = 'blob'; mode = '100644'; sha = ('1' * 40); size = 10 }
            'bin/tool.ps1' = @{ type = 'blob'; mode = '100644'; sha = ('2' * 40) }
        }
        $script:treeAfter = @{
            'bucket/demo.json' = @{ type = 'blob'; mode = '100644'; sha = ('3' * 40); size = 10 }
            'bin/tool.ps1' = @{ type = 'blob'; mode = '100644'; sha = ('2' * 40) }
        }
        Mock Invoke-GithubApi -ModuleName github-api { $script:comparison }
        Mock Get-GithubTree -ModuleName github-api {
            if ($Sha -ceq ('d' * 40)) { return $script:treeBefore }
            return $script:treeAfter
        }
    }

    It 'accepts verified bot-authored commits with committer <CommitterLogin>' -ForEach @(
        @{ CommitterLogin = 'github-actions[bot]' }
        @{ CommitterLogin = 'web-flow' }
    ) {
        $commit = New-IdentityTestCommit -Committer @{ login = $CommitterLogin }
        $script:comparison = New-IdentityTestComparison -Commits @($commit)

        $change = Get-GithubBranchChange -Repository owner/repo -BaseSha ('b' * 40) -HeadSha ('a' * 40) -App demo

        $change.BeforeTree['bucket/demo.json'].sha | Should -BeExactly ('1' * 40)
        $change.AfterTree['bucket/demo.json'].sha | Should -BeExactly ('3' * 40)
        Should -Invoke Get-GithubTree -ModuleName github-api -Times 2 -Exactly
    }

    It 'rejects unsafe linked identities: <Case>' -ForEach @(
        @{ Case = 'human author'; Identity = @{ Author = @{ login = 'human' } } }
        @{ Case = 'web-flow author'; Identity = @{ Author = @{ login = 'web-flow' } } }
        @{ Case = 'null author'; Identity = @{ Author = $null } }
        @{ Case = 'missing author login'; Identity = @{ Author = @{} } }
        @{ Case = 'case-altered author'; Identity = @{ Author = @{ login = 'GitHub-Actions[bot]' } } }
        @{ Case = 'human committer'; Identity = @{ Committer = @{ login = 'human' } } }
        @{ Case = 'null committer'; Identity = @{ Committer = $null } }
        @{ Case = 'missing committer login'; Identity = @{ Committer = @{} } }
        @{ Case = 'case-altered bot committer'; Identity = @{ Committer = @{ login = 'GitHub-Actions[bot]' } } }
        @{ Case = 'case-altered web-flow committer'; Identity = @{ Committer = @{ login = 'Web-Flow' } } }
    ) {
        $script:comparison = New-IdentityTestComparison -Commits @(New-IdentityTestCommit @Identity)

        { Get-GithubBranchChange -Repository owner/repo -BaseSha ('b' * 40) -HeadSha ('a' * 40) -App demo } | Should -Throw

        Should -Invoke Get-GithubTree -ModuleName github-api -Times 0 -Exactly
    }

    It 'rejects unsafe web-flow signature evidence: <Case>' -ForEach @(
        @{ Case = 'unsigned'; Verification = @{ verified = $false; reason = 'valid' } }
        @{ Case = 'string true'; Verification = @{ verified = 'true'; reason = 'valid' } }
        @{ Case = 'string false'; Verification = @{ verified = 'false'; reason = 'valid' } }
        @{ Case = 'numeric one'; Verification = @{ verified = 1; reason = 'valid' } }
        @{ Case = 'numeric zero'; Verification = @{ verified = 0; reason = 'valid' } }
        @{ Case = 'null verified'; Verification = @{ verified = $null; reason = 'valid' } }
        @{ Case = 'missing verified'; Verification = @{ reason = 'valid' } }
        @{ Case = 'null verification'; Verification = $null }
        @{ Case = 'invalid reason'; Verification = @{ verified = $true; reason = 'unsigned' } }
        @{ Case = 'case-altered reason'; Verification = @{ verified = $true; reason = 'Valid' } }
        @{ Case = 'null reason'; Verification = @{ verified = $true; reason = $null } }
        @{ Case = 'missing reason'; Verification = @{ verified = $true } }
    ) {
        $commit = New-IdentityTestCommit -Verification $Verification
        $script:comparison = New-IdentityTestComparison -Commits @($commit)

        { Get-GithubBranchChange -Repository owner/repo -BaseSha ('b' * 40) -HeadSha ('a' * 40) -App demo } | Should -Throw

        Should -Invoke Get-GithubTree -ModuleName github-api -Times 0 -Exactly
    }

    It 'rejects incomplete or oversized histories with <TotalCommits> reported commits' -ForEach @(
        @{ TotalCommits = 0 }
        @{ TotalCommits = 2 }
        @{ TotalCommits = 251 }
    ) {
        $commits = if ($TotalCommits -eq 251) { @(New-IdentityTestCommit) * 251 } else { @(New-IdentityTestCommit) }
        $script:comparison = New-IdentityTestComparison -Commits $commits -TotalCommits $TotalCommits

        { Get-GithubBranchChange -Repository owner/repo -BaseSha ('b' * 40) -HeadSha ('a' * 40) -App demo } | Should -Throw '*empty or incomplete*'

        Should -Invoke Get-GithubTree -ModuleName github-api -Times 0 -Exactly
    }

    It 'rejects a <Invalid> commit at the <Position> of a multi-commit history' -ForEach @(
        @{ Invalid = 'human'; Position = 'start' }
        @{ Invalid = 'human'; Position = 'end' }
        @{ Invalid = 'unsigned'; Position = 'start' }
        @{ Invalid = 'unsigned'; Position = 'end' }
    ) {
        $valid = New-IdentityTestCommit
        $invalidCommit = if ($Invalid -eq 'human') {
            New-IdentityTestCommit -Author @{ login = 'human' }
        } else {
            New-IdentityTestCommit -Verification @{ verified = $false; reason = 'unsigned' }
        }
        $commits = if ($Position -eq 'start') { @($invalidCommit, $valid) } else { @($valid, $invalidCommit) }
        $script:comparison = New-IdentityTestComparison -Commits $commits -TotalCommits 2

        { Get-GithubBranchChange -Repository owner/repo -BaseSha ('b' * 40) -HeadSha ('a' * 40) -App demo } | Should -Throw

        Should -Invoke Get-GithubTree -ModuleName github-api -Times 0 -Exactly
    }

    It 'still rejects extra file changes after accepting a verified web-flow commit' {
        $script:treeAfter = @{
            'bucket/demo.json' = @{ type = 'blob'; mode = '100644'; sha = ('3' * 40); size = 10 }
            'bin/tool.ps1' = @{ type = 'blob'; mode = '100644'; sha = ('4' * 40) }
        }

        { Get-GithubBranchChange -Repository owner/repo -BaseSha ('b' * 40) -HeadSha ('a' * 40) -App demo } | Should -Throw '*exactly one*'

        Should -Invoke Get-GithubTree -ModuleName github-api -Times 2 -Exactly
    }
}
