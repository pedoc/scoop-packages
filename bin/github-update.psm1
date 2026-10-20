Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'manifest-policy.psm1') -Scope Local
Import-Module (Join-Path $PSScriptRoot 'github-api.psm1') -Scope Local
Import-Module (Join-Path $PSScriptRoot 'github-validation.psm1') -Scope Local
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot

function Get-GithubUpdateResult {
    param([bool]$Staged = $false, [bool]$Dispatched = $false, [bool]$StatusPosted = $false,
        [bool]$Merged = $false, [bool]$Published = $false, [System.Collections.IDictionary]$Details = @{})
    return @{ staged = $Staged; dispatched = $Dispatched; statusPosted = $StatusPosted; merged = $Merged; published = $Published } + $Details
}

function Test-GithubIntegerValue {
    param([object]$Value)
    return $Value -is [int] -or $Value -is [long]
}

function Get-GithubBytesHash {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Assert-GithubSafePath {
    param([Parameter(Mandatory)][string]$Path, [switch]$File)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $item = if ($File) { [IO.FileInfo]::new($fullPath) } else { [IO.DirectoryInfo]::new($fullPath) }
    if (-not $item.Exists) { throw 'Required data path does not exist.' }
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Data path must not contain symbolic links or reparse points.' }
        $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
    }
    return $fullPath
}

function New-GithubDataDirectory {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.File]::Exists($fullPath)) { throw 'Output directory is a file.' }
    $isExistingDirectory = [IO.Directory]::Exists($fullPath)
    if ($isExistingDirectory) {
        $null = Assert-GithubSafePath -Path $fullPath
        if (@([IO.Directory]::EnumerateFileSystemEntries($fullPath)).Count -ne 0) { throw 'Output directory must be fresh and empty.' }
    } else {
        $parent = [IO.DirectoryInfo]::new($fullPath).Parent
        if ($null -eq $parent -or -not $parent.Exists) { throw 'Output directory parent must exist.' }
        $null = Assert-GithubSafePath -Path $parent.FullName
    }
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Create fresh validation data directory')) { throw 'Validation data directory creation was declined.' }
    if (-not $isExistingDirectory) { [void][IO.Directory]::CreateDirectory($fullPath) }
    return $fullPath
}

function Assert-GithubContext {
    param([string]$Repository, [string]$App, [string]$BaseBranch, [string]$RunId, [string]$RunAttempt)
    if ($Repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$' -or $Repository.Contains('..')) { throw 'Invalid repository name.' }
    $null = Assert-SafeAppName -App $App
    # The trusted default branch is intentionally explicit, not an arbitrary caller-supplied workflow ref.
    if ($BaseBranch -cne 'master') { throw 'Only the trusted master default branch is supported.' }
    if ($RunId -cnotmatch '^[1-9][0-9]{0,19}$' -or $RunAttempt -cnotmatch '^[1-9][0-9]{0,9}$') { throw 'Expected trusted run ID and attempt are required.' }
}

function Assert-GithubPullIdentity {
    param([System.Collections.IDictionary]$Pull, [string]$Repository, [string]$App, [string]$BaseBranch, [int]$PrNumber, [string]$ExpectedHead)
    if ($PrNumber -le 0 -or $ExpectedHead -cnotmatch '^[a-f0-9]{40}$') { throw 'An exact PR number and head SHA are required.' }
    if ($Pull.number -ne $PrNumber -or $Pull.state -cne 'open' -or $Pull.draft -isnot [bool] -or $Pull.draft -or
        $Pull.user.login -cne 'github-actions[bot]' -or $null -eq $Pull.head.repo -or
        $Pull.head.repo.full_name -cne $Repository -or $Pull.base.repo.full_name -cne $Repository -or
        $Pull.head.ref -cne "automation/update-$App" -or $Pull.base.ref -cne $BaseBranch -or
        $Pull.head.sha -cne $ExpectedHead) { throw 'PR identity, managed branch, base, author or exact head is invalid.' }
}

function Write-GithubActionOutput {
    param([System.Collections.IDictionary]$Values)
    if ([string]::IsNullOrEmpty($env:GITHUB_OUTPUT)) { return }
    $lines = foreach ($key in $Values.Keys) {
        $value = [string]$Values[$key]
        if ($key -cnotmatch '^[a-z_]+$' -or $value -cnotmatch '^[A-Za-z0-9_./+-]*$') { throw 'Invalid workflow output.' }
        "$key=$value"
    }
    [IO.File]::AppendAllText($env:GITHUB_OUTPUT, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
}

function Assert-GithubEvidence {
    param([string]$Path, [System.Collections.IDictionary]$Context)
    $null = Assert-GithubSafePath -Path $Path -File
    if ((Get-Item -LiteralPath $Path).Length -gt 2097152) { throw 'Validation evidence is too large.' }
    $evidence = Read-StrictJsonFile -Path $Path
    $runUrl = "https://github.com/$($Context.Repository)/actions/runs/$($Context.RunId)/attempts/$($Context.RunAttempt)"
    if (-not (Test-GithubIntegerValue $evidence.schema) -or $evidence.schema -ne 1 -or $evidence.status -cne 'success' -or
        $evidence.repository -cne $Context.Repository -or -not (Test-GithubIntegerValue $evidence.prNumber) -or $evidence.prNumber -ne $Context.PrNumber -or
        $evidence.app -cne $Context.App -or $evidence.headSha -cne $Context.ExpectedHead -or
        $evidence.runId -isnot [string] -or $evidence.runId -cne $Context.RunId -or
        $evidence.runAttempt -isnot [string] -or $evidence.runAttempt -cne $Context.RunAttempt -or
        $evidence.runUrl -cne $runUrl -or -not (Test-GithubIntegerValue $evidence.verifiedAssetCount) -or -not (Test-GithubIntegerValue $evidence.declaredAssetCount) -or
        $evidence.verifiedAssetCount -le 0 -or $evidence.verifiedAssetCount -ne $evidence.declaredAssetCount -or
        $evidence.assets -isnot [System.Collections.IList] -or @($evidence.assets).Count -ne $evidence.verifiedAssetCount -or $evidence.baseSha -cnotmatch '^[a-f0-9]{40}$' -or
        $evidence.baselineSha256 -isnot [string] -or $evidence.candidateSha256 -isnot [string] -or $evidence.policyDigest -isnot [string] -or
        $evidence.baselineSha256 -cnotmatch '^[a-f0-9]{64}$' -or $evidence.candidateSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $evidence.policyDigest -cnotmatch '^[a-f0-9]{64}$') { throw 'Validation evidence is failed, empty, stale or not bound to this run and head.' }
    foreach ($asset in $evidence.assets) {
        if ($asset.sha256 -isnot [string] -or $asset.sha256 -cnotmatch '^[a-f0-9]{64}$' -or -not (Test-GithubIntegerValue $asset.bytes) -or
            $asset.bytes -le 0 -or $asset.bytes -gt 1073741824 -or $asset.url -isnot [string]) { throw 'Validation evidence contains an unverified asset.' }
    }
    return $evidence
}

function Assert-GithubFreshInput {
    param([System.Collections.IDictionary]$Evidence, [System.Collections.IDictionary]$BaseState)
    if ($BaseState.ManifestSha256 -cne $Evidence.baselineSha256 -or $BaseState.PolicyDigest -cne $Evidence.policyDigest) { throw 'Validation is stale: target manifest or trusted policy inputs changed.' }
}

function Get-GithubManifestPair {
    param([byte[]]$BeforeBytes, [byte[]]$AfterBytes, [string]$Directory, [string]$ScoopHome)
    $beforeDirectory = Join-Path $Directory 'baseline'
    $afterDirectory = Join-Path $Directory 'candidate'
    [void][IO.Directory]::CreateDirectory($beforeDirectory)
    [void][IO.Directory]::CreateDirectory($afterDirectory)
    $beforePath = Join-Path $beforeDirectory 'manifest.json'
    $afterPath = Join-Path $afterDirectory 'manifest.json'
    [IO.File]::WriteAllBytes($beforePath, $BeforeBytes)
    [IO.File]::WriteAllBytes($afterPath, $AfterBytes)
    $before = Read-StrictJsonFile -Path $beforePath
    $after = Read-StrictJsonFile -Path $afterPath
    $null = Assert-ManifestSchema -Path $beforePath -ScoopHome $ScoopHome
    $null = Assert-ManifestSchema -Path $afterPath -ScoopHome $ScoopHome
    $decision = Get-ManifestUpdateDecision -Before $before -After $after -ScoopHome $ScoopHome
    if ($decision.Allowed -isnot [bool] -or -not $decision.Allowed) { throw "Manifest update requires manual review: $($decision.Reason)" }
    return @{ Before = $before; After = $after; Assets = @($decision.Assets) }
}

function Invoke-GithubStage {
    param([System.Collections.IDictionary]$Context, [string]$CandidateDirectory, [string]$BaseSha)
    if ($BaseSha -cnotmatch '^[a-f0-9]{40}$') { throw 'Expected trusted source base SHA is required.' }
    $directory = Assert-GithubSafePath -Path $CandidateDirectory
    $entries = @(Get-ChildItem -LiteralPath $directory -Force)
    if ($entries.Count -ne 2 -or @($entries | Where-Object { $_.PSIsContainer -or $_.Name -cnotin @('result.json', 'candidate.json') }).Count -ne 0) { throw 'Candidate artifact must contain only result.json and candidate.json.' }
    foreach ($entry in $entries) {
        $null = Assert-GithubSafePath -Path $entry.FullName -File
        if ($entry.Length -le 0 -or $entry.Length -gt 2097152) { throw 'Candidate artifact data has invalid size.' }
    }
    $result = Read-StrictJsonFile -Path (Join-Path $directory 'result.json')
    if (-not (Test-GithubIntegerValue $result.schema) -or $result.schema -ne 1 -or $result.app -isnot [string] -or $result.app -cne $Context.App -or
        $result.reason -isnot [string] -or $result.oldVersion -isnot [string] -or $result.newVersion -isnot [string] -or $result.status -cne 'updated' -or
        $result.sourceResolved -isnot [bool] -or -not $result.sourceResolved -or $result.baseSha -isnot [string] -or $result.baseSha -cne $BaseSha -or
        $result.runId -isnot [string] -or $result.runId -cne $Context.RunId -or
        $result.runAttempt -isnot [string] -or $result.runAttempt -cne $Context.RunAttempt -or
        $result.originalSha256 -isnot [string] -or $result.candidateSha256 -isnot [string] -or $result.originalSha256 -cnotmatch '^[a-f0-9]{64}$' -or $result.candidateSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Candidate artifact provenance is invalid or from another trusted run.' }
    $bytes = [IO.File]::ReadAllBytes((Join-Path $directory 'candidate.json'))
    if ((Get-GithubBytesHash -Bytes $bytes) -cne $result.candidateSha256) { throw 'Candidate artifact digest does not match.' }
    $base = Get-GithubBaseState -Repository $Context.Repository -BaseBranch $Context.BaseBranch -App $Context.App -ScoopHome $Context.ScoopHome
    if ($base.ManifestSha256 -cne $result.originalSha256) { throw 'Candidate artifact is stale: current target manifest changed.' }
    if ($base.Sha -cne $BaseSha) {
        $sourceBase = Get-GithubBaseState -Repository $Context.Repository -BaseBranch $Context.BaseBranch -App $Context.App -ScoopHome $Context.ScoopHome -CommitSha $BaseSha
        if ($sourceBase.ManifestSha256 -cne $result.originalSha256) { throw 'Candidate artifact original digest does not match the trusted source base.' }
    }
    $managed = Assert-GithubManagedBranch -Repository $Context.Repository -App $Context.App -BaseBranch $Context.BaseBranch -BaseSha $base.Sha
    $temporary = New-GithubDataDirectory -Path (Join-Path ([IO.Path]::GetTempPath()) ('scoop-stage-' + [guid]::NewGuid().ToString('N')))
    try {
        $pair = Get-GithubManifestPair -BeforeBytes $base.Bytes -AfterBytes $bytes -Directory $temporary -ScoopHome $Context.ScoopHome
        if ($pair.Before.version -cne $result.oldVersion -or $pair.After.version -cne $result.newVersion) { throw 'Candidate artifact version provenance does not match.' }
    } finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
    $staged = $false
    $file = "bucket/$($Context.App).json"
    if (Test-PublishAuthorization -Enabled $Context.Enabled -Publish $Context.Publish) {
        $null = Assert-GithubSafePath -Path $Context.RepositoryDirectory
        $target = Assert-GithubSafePath -Path (Join-Path $Context.RepositoryDirectory $file) -File
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $result.originalSha256) { throw 'Trusted checkout target manifest differs from the expected baseline.' }
        [IO.File]::WriteAllBytes($target, $bytes)
        $staged = $true
    }
    $output = Get-GithubUpdateResult -Staged $staged -Details @{ app = $Context.App; branch = "automation/update-$($Context.App)"; file = $file; existingPr = $managed.ExistingPr; headSha = $managed.HeadSha }
    Write-GithubActionOutput -Values @{ app = $output.App; branch = $output.Branch; file = $output.File; staged = $staged.ToString().ToLowerInvariant(); existing_pr = $output.ExistingPr; head_sha = $output.HeadSha }
    return $output
}

function Invoke-GithubValidate {
    param([System.Collections.IDictionary]$Context, [string]$OutputDirectory, [string]$ValidationPath)
    $directory = New-GithubDataDirectory -Path $OutputDirectory
    $expectedPath = Join-Path $directory 'validation.json'
    $evidence = [ordered]@{
        schema = 1; status = 'failure'; repository = $Context.Repository; prNumber = $Context.PrNumber
        app = $Context.App; headSha = $Context.ExpectedHead; baseSha = ''; baselineSha256 = ''; candidateSha256 = ''; policyDigest = ''
        runId = $Context.RunId; runAttempt = $Context.RunAttempt; verifiedAssetCount = 0; declaredAssetCount = 0
        runUrl = "https://github.com/$($Context.Repository)/actions/runs/$($Context.RunId)/attempts/$($Context.RunAttempt)"
        assets = @(); reason = 'Validation did not complete.'
    }
    try {
        Assert-GithubContext -Repository $Context.Repository -App $Context.App -BaseBranch $Context.BaseBranch -RunId $Context.RunId -RunAttempt $Context.RunAttempt
        if ($ValidationPath -and [IO.Path]::GetFullPath($ValidationPath) -cne $expectedPath) { throw 'ValidationPath must be validation.json in the fresh output directory.' }
        $snapshot = Get-GithubPullSnapshot -Repository $Context.Repository -PrNumber $Context.PrNumber -ExpectedHead $Context.ExpectedHead -BaseBranch $Context.BaseBranch -App $Context.App -ScoopHome $Context.ScoopHome
        $evidence.baseSha = $snapshot.BaseSha
        $evidence.baselineSha256 = Get-GithubBytesHash -Bytes $snapshot.BaseBytes
        $evidence.candidateSha256 = Get-GithubBytesHash -Bytes $snapshot.HeadBytes
        $evidence.policyDigest = $snapshot.PolicyDigest
        Assert-GithubPullIdentity -Pull $snapshot.Pull -Repository $Context.Repository -App $Context.App -BaseBranch $Context.BaseBranch -PrNumber $Context.PrNumber -ExpectedHead $Context.ExpectedHead
        Assert-GithubPolicyCheckout -Repository $Context.Repository -BaseSha $snapshot.BaseSha -RepositoryDirectory $Context.RepositoryDirectory
        $pair = Get-GithubManifestPair -BeforeBytes $snapshot.BaseBytes -AfterBytes $snapshot.HeadBytes -Directory $directory -ScoopHome $Context.ScoopHome
        $evidence.declaredAssetCount = $pair.Assets.Count
        $verification = Invoke-GithubAssetVerification -Assets $pair.Assets -Manifest $pair.After -Directory $directory
        if ($verification.VerifiedAssetCount -le 0 -or $verification.VerifiedAssetCount -ne $verification.DeclaredAssetCount -or
            $verification.DeclaredAssetCount -ne $pair.Assets.Count -or @($verification.Assets).Count -ne $pair.Assets.Count) { throw 'Asset validation is empty or incomplete.' }
        $evidence.status = 'success'
        $evidence.verifiedAssetCount = $verification.VerifiedAssetCount
        $evidence.declaredAssetCount = $verification.DeclaredAssetCount
        $evidence.assets = @($verification.Assets)
        $evidence.reason = 'All declared assets passed SHA256 validation; binaries were not executed.'
    } catch {
        $evidence.reason = 'Validation failed; see trusted job error output.'
        throw
    } finally {
        [IO.File]::WriteAllText($expectedPath, (ConvertTo-Json -InputObject $evidence -Depth 30), [Text.UTF8Encoding]::new($false))
    }
    return Get-GithubUpdateResult -Details @{ validationPath = $expectedPath; verifiedAssetCount = $evidence.verifiedAssetCount }
}

function Invoke-GithubStatus {
    param([System.Collections.IDictionary]$Context, [string]$ValidationPath, [bool]$ValidationSucceeded)
    $pull = Get-GithubPull -Repository $Context.Repository -PrNumber $Context.PrNumber
    Assert-GithubPullIdentity -Pull $pull -Repository $Context.Repository -App $Context.App -BaseBranch $Context.BaseBranch -PrNumber $Context.PrNumber -ExpectedHead $Context.ExpectedHead
    $state = 'failure'
    if ($ValidationSucceeded) {
        $null = Assert-GithubEvidence -Path $ValidationPath -Context $Context
        $state = 'success'
    }
    $body = @{
        state = $state; context = 'scoop/update-validation'
        description = if ($state -eq 'success') { 'All declared assets validated for this run' } else { 'Validation failed or did not complete in this run' }
        target_url = "https://github.com/$($Context.Repository)/actions/runs/$($Context.RunId)/attempts/$($Context.RunAttempt)"
    }
    $response = Invoke-GithubApi -Method POST -Endpoint "repos/$($Context.Repository)/statuses/$($Context.ExpectedHead)" -Body $body -Enabled $Context.Enabled -Publish $Context.Publish
    if ($response.state -cne $state -or $response.context -cne $body.context -or $response.target_url -cne $body.target_url -or
        $response.creator.login -cne 'github-actions[bot]') { throw 'GitHub did not confirm the requested current-run validation status.' }
    return Get-GithubUpdateResult -StatusPosted $true -Published $true -Details @{ state = $state }
}

function Invoke-GithubMerge {
    param([System.Collections.IDictionary]$Context, [string]$ValidationPath, [bool]$ValidationSucceeded)
    if (-not $ValidationSucceeded) { throw 'This run did not successfully validate the candidate.' }
    $evidence = Assert-GithubEvidence -Path $ValidationPath -Context $Context
    $pull = Get-GithubPull -Repository $Context.Repository -PrNumber $Context.PrNumber
    Assert-GithubPullIdentity -Pull $pull -Repository $Context.Repository -App $Context.App -BaseBranch $Context.BaseBranch -PrNumber $Context.PrNumber -ExpectedHead $Context.ExpectedHead
    $base = Get-GithubBaseState -Repository $Context.Repository -BaseBranch $Context.BaseBranch -App $Context.App -ScoopHome $Context.ScoopHome
    Assert-GithubFreshInput -Evidence $evidence -BaseState $base
    $statuses = @(Invoke-GithubApi -Method GET -Endpoint "repos/$($Context.Repository)/commits/$($Context.ExpectedHead)/statuses?per_page=100")
    $matching = @($statuses | Where-Object { $_.context -ceq 'scoop/update-validation' })
    if ($matching.Count -eq 0 -or $matching[0].state -cne 'success' -or $matching[0].target_url -cne $evidence.runUrl -or $matching[0].creator.login -cne 'github-actions[bot]') { throw 'No successful validation status exists for this exact run and head.' }
    # Head is atomically protected by the merge API sha parameter; base freshness is a best-effort reread, not CAS.
    $pull = Get-GithubPull -Repository $Context.Repository -PrNumber $Context.PrNumber
    Assert-GithubPullIdentity -Pull $pull -Repository $Context.Repository -App $Context.App -BaseBranch $Context.BaseBranch -PrNumber $Context.PrNumber -ExpectedHead $Context.ExpectedHead
    $base = Get-GithubBaseState -Repository $Context.Repository -BaseBranch $Context.BaseBranch -App $Context.App -ScoopHome $Context.ScoopHome
    Assert-GithubFreshInput -Evidence $evidence -BaseState $base
    $response = Invoke-GithubApi -Method PUT -Endpoint "repos/$($Context.Repository)/pulls/$($Context.PrNumber)/merge" -Body @{ sha = $Context.ExpectedHead; merge_method = 'squash' } -Enabled $Context.Enabled -Publish $Context.Publish
    if ($response.merged -isnot [bool] -or -not $response.merged) { throw 'PR was not merged; protections or conflicts may require manual attention.' }
    return Get-GithubUpdateResult -Merged $true -Published $true -Details @{ headSha = $Context.ExpectedHead }
}

function Invoke-GithubUpdate {
    <#
    .SYNOPSIS
    Orchestrates one identity-checked, policy-gated managed manifest update.
    .DESCRIPTION
    RepositoryDirectory and ScoopHome must be trusted default-branch code and a pinned
    Scoop installation. No scripts or commands are loaded from candidate artifacts.
    Publication requires the strict shared gate; a string 'true' is not a Boolean Publish.
    Status success and merge require nonempty evidence bound to the current run attempt.
    .OUTPUTS
    System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('Stage', 'Dispatch', 'Validate', 'Status', 'Merge')][string]$Mode,
        [Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$App, [string]$BaseBranch = 'master',
        [int]$PrNumber, [string]$ExpectedHead, [string]$ScoopHome, [string]$OutputDirectory,
        [string]$ValidationPath, [string]$CandidateDirectory, [string]$BaseSha,
        [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$RunAttempt,
        [AllowEmptyString()][string]$Enabled = '', [object]$Publish = $false, [bool]$ValidationSucceeded = $false,
        [string]$RepositoryDirectory = $script:RepositoryRoot
    )
    if ($Mode -ne 'Validate') { Assert-GithubContext -Repository $Repository -App $App -BaseBranch $BaseBranch -RunId $RunId -RunAttempt $RunAttempt }
    $context = @{ Repository = $Repository; App = $App; BaseBranch = $BaseBranch; PrNumber = $PrNumber; ExpectedHead = $ExpectedHead; ScoopHome = $ScoopHome; RunId = $RunId; RunAttempt = $RunAttempt; Enabled = $Enabled; Publish = $Publish; RepositoryDirectory = $RepositoryDirectory }
    $contextIdentity = @{ Repository = $Repository; App = $App; BaseBranch = $BaseBranch; PrNumber = $PrNumber; ExpectedHead = $ExpectedHead }
    if ($Mode -in @('Dispatch', 'Status', 'Merge') -and -not (Test-PublishAuthorization -Enabled $Enabled -Publish $Publish)) { return Get-GithubUpdateResult -Details @{ reason = 'Publication is disabled or not explicitly authorized.' } }
    switch ($Mode) {
        Stage { return Invoke-GithubStage -Context $context -CandidateDirectory $CandidateDirectory -BaseSha $BaseSha }
        Validate { return Invoke-GithubValidate -Context $context -OutputDirectory $OutputDirectory -ValidationPath $ValidationPath }
        Status { return Invoke-GithubStatus -Context $context -ValidationPath $ValidationPath -ValidationSucceeded $ValidationSucceeded }
        Merge { return Invoke-GithubMerge -Context $context -ValidationPath $ValidationPath -ValidationSucceeded $ValidationSucceeded }
        Dispatch {
            $pull = Get-GithubPull -Repository $Repository -PrNumber $PrNumber
            Assert-GithubPullIdentity -Pull $pull @contextIdentity
            $null = Assert-GithubManagedBranch -Repository $Repository -App $App -BaseBranch $BaseBranch -BaseSha $pull.base.sha
            Invoke-GithubWorkflowDispatch -Repository $Repository -BaseBranch $BaseBranch -PrNumber $PrNumber -ExpectedHead $ExpectedHead -App $App -Enabled $Enabled -Publish $Publish
            return Get-GithubUpdateResult -Dispatched $true -Published $true -Details @{ prNumber = $PrNumber; headSha = $ExpectedHead }
        }
    }
}

Export-ModuleMember -Function Invoke-GithubUpdate
