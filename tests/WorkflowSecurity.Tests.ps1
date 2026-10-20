BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot

    function Get-WorkflowText([string]$Name) {
        Get-Content -LiteralPath (Join-Path $repositoryRoot ".github/workflows/$Name") -Raw
    }

    function Get-WorkflowJob([string]$Text, [string]$Name) {
        $pattern = '(?ms)^  ' + [regex]::Escape($Name) + ':\s*\r?\n(.*?)(?=^  [a-zA-Z0-9_-]+:\s*\r?$|\z)'
        $match = [regex]::Match($Text, $pattern)
        $match.Success | Should -BeTrue -Because "the $Name job must exist"
        $match.Value
    }
}

Describe 'Workflow trust boundaries' {
    It 'provides the <Name> workflow' -ForEach @(
        @{ Name = 'ci.yml' },
        @{ Name = 'update-manifests.yml' },
        @{ Name = 'validate-update.yml' }
    ) {
        Test-Path -LiteralPath (Join-Path $repositoryRoot ".github/workflows/$Name") | Should -BeTrue
    }

    It 'pins all external actions to immutable commits' {
        $files = @(
            '.github/workflows/ci.yml',
            '.github/workflows/update-manifests.yml',
            '.github/workflows/validate-update.yml',
            '.github/actions/setup-scoop/action.yml'
        )
        foreach ($file in $files) {
            $text = Get-Content -LiteralPath (Join-Path $repositoryRoot $file) -Raw
            $actions = [regex]::Matches($text, '(?m)^\s*(?:-\s*)?uses:\s+(\S+)')
            $actions.Count | Should -BeGreaterThan 0
            foreach ($action in $actions) {
                $reference = $action.Groups[1].Value
                if (!$reference.StartsWith('./')) {
                    $reference | Should -Match '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_./-]+@[a-f0-9]{40}$'
                }
            }
        }
    }

    It 'keeps ordinary pull request CI read-only' {
        $text = Get-WorkflowText 'ci.yml'
        $text | Should -Match '(?m)^  pull_request:'
        $text | Should -Match '(?m)^permissions:\r?\n  contents: read'
        $text | Should -Not -Match '(?m)^\s+(?:contents|pull-requests|statuses|actions|id-token): write'
        $text | Should -Not -Match 'pull_request_target|workflow_run'
        $text | Should -Match 'persist-credentials: false'
    }

    It 'defaults manual publication to disabled' {
        foreach ($name in @('update-manifests.yml', 'validate-update.yml')) {
            $text = Get-WorkflowText $name
            $text | Should -Match '(?s)workflow_dispatch:.*?publish:.*?type: boolean.*?default: false'
            $text | Should -Match '(?m)^permissions:\r?\n  contents: read'
            $text | Should -Not -Match 'pull_request_target|workflow_run'
        }
    }

    It 'gates publishing on the rollout flag and trusted default branch' {
        $job = Get-WorkflowJob (Get-WorkflowText 'update-manifests.yml') 'publish'
        $job | Should -Match 'vars\.SCOOP_UPDATES_ENABLED'
        $job | Should -Match 'inputs\.publish'
        $job | Should -Match 'github\.ref_name'
        $job | Should -Match "github\.ref_type == 'branch'"
        $job | Should -Match 'default_branch'
        ($job -match "needs\.collect\.result == 'success'") | Should -BeTrue -Because 'publication requires collector integrity success'
        $job | Should -Not -Match 'needs:\s*.*source-verdict'
        $job | Should -Match 'pull-requests: write'
        $job | Should -Match 'actions: write'
        $job | Should -Match 'add-paths:'
        ($job -match 'sign-commits: true') | Should -BeTrue -Because 'managed branches require verified GitHub bot signatures'
        $job | Should -Match 'automation/update-'
        $job | Should -Match '-Mode Dispatch'
    }

    It 'keeps the failing source verdict separate from collection integrity' {
        $job = Get-WorkflowJob (Get-WorkflowText 'update-manifests.yml') 'source-verdict'
        $job | Should -Match 'needs: collect'
        $job | Should -Match '-Mode Verdict'
        $job | Should -Not -Match '(?m)^\s+(?:contents|pull-requests|statuses|actions): write'
    }

    It 'independently gates <Name> on explicit dispatch authorization' -ForEach @(
        @{ Name = 'status' },
        @{ Name = 'merge' }
    ) {
        $job = Get-WorkflowJob (Get-WorkflowText 'validate-update.yml') $Name
        $job | Should -Match "github\.event_name == 'workflow_dispatch'"
        $job | Should -Match 'vars\.SCOOP_UPDATES_ENABLED'
        $job | Should -Match 'inputs\.publish'
        $job | Should -Match 'github\.ref_name'
        $job | Should -Match "github\.ref_type == 'branch'"
        $job | Should -Match 'default_branch'
        $job | Should -Match 'persist-credentials: false'
    }

    It 'merges only after this run validation and status publication succeed' {
        $text = Get-WorkflowText 'validate-update.yml'
        $job = Get-WorkflowJob $text 'merge'
        $job | Should -Match "needs\.validate\.result == 'success'"
        $job | Should -Match "needs\.status\.result == 'success'"
        $job | Should -Match 'contents: write'
        $job | Should -Match '-Mode Merge'
        $job | Should -Match 'ExpectedHead'
        $text | Should -Not -Match '--admin|enable-pull-request-automerge'
    }

    It 'uses only the built-in token rather than personal credentials' {
        foreach ($name in @('ci.yml', 'update-manifests.yml', 'validate-update.yml')) {
            $text = Get-WorkflowText $name
            $text | Should -Not -Match 'secrets\.(?!GITHUB_TOKEN)[a-zA-Z_][a-zA-Z0-9_]*'
            $text | Should -Not -Match 'create-github-app-token|pull_request_review:'
        }
    }
}
