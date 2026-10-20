#Requires -Version 7.2
Set-StrictMode -Version Latest

function Get-PolicyFile {
    param([string] $Path, [switch] $AllowLinkedParents)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '^(?:\\\\|//)|[\x00-\x1f?*]|:(?![/\\])') {
        throw 'Unsafe filesystem path.'
    }
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSProvider.Name -ne 'FileSystem' -or $file.PSIsContainer) { throw 'Expected a regular file.' }
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'File is a reparse point.' }
    if (!$AllowLinkedParents) {
        for ($parent = $file.Directory; $null -ne $parent; $parent = $parent.Parent) {
            if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Parent is a reparse point.' }
        }
    }
    return $file.FullName
}

function Assert-JsonPropertyName {
    param([Text.Json.JsonElement] $Element)
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (!$names.Add($property.Name)) { throw "Duplicate or case-colliding JSON property '$($property.Name)'." }
            Assert-JsonPropertyName -Element $property.Value
        }
    } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-JsonPropertyName -Element $item }
    }
}

function Read-StrictJsonFile {
    [CmdletBinding()]
    [OutputType([Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $Path)
    $file = Get-PolicyFile -Path $Path
    $maximumJsonBytes = 2MB
    if ([IO.FileInfo]::new($file).Length -gt $maximumJsonBytes) { throw 'JSON file exceeds the size limit.' }
    $text = [IO.File]::ReadAllText($file, [Text.UTF8Encoding]::new($false, $true))
    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($text)
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'JSON root must be an object.' }
        Assert-JsonPropertyName -Element $document.RootElement
        return ($text | ConvertFrom-Json -AsHashtable -Depth 64 -ErrorAction Stop)
    } finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}

function Assert-SafeAppName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][object] $App)
    if ($App -isnot [string] -or $App -notmatch '^[A-Za-z0-9._+-]{1,128}$' -or
        $App -in @('.', '..') -or $App.EndsWith('.') -or
        $App -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        throw 'Unsafe application basename.'
    }
}

function Test-PolicyKey {
    param([Collections.IDictionary] $Map, [string] $Name)
    return @($Map.PSBase.Keys) -ccontains $Name
}

function Get-ManifestMaintenanceState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][Collections.IDictionary] $Manifest)
    $hasCheckver = Test-PolicyKey $Manifest 'checkver'
    $hasAutoupdate = Test-PolicyKey $Manifest 'autoupdate'
    if ($hasCheckver -and $Manifest.checkver -isnot [string] -and $Manifest.checkver -isnot [Collections.IDictionary]) {
        throw 'checkver must be a string or object.'
    }
    if ($hasAutoupdate -and $Manifest.autoupdate -isnot [Collections.IDictionary]) { throw 'autoupdate must be an object.' }
    if ($hasCheckver -and $hasAutoupdate) { return 'configured' }
    if ($hasCheckver) { return 'missing-autoupdate' }
    if ($hasAutoupdate) { return 'missing-checkver' }
    return 'manual'
}

function Assert-PolicyUrl {
    param([object] $Url)
    $uri = $null
    if ($Url -isnot [string] -or $Url -match '[\s\\$\x00-\x1f]' -or
        ![Uri]::TryCreate($Url, [UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -cne 'https' -or !$uri.Host -or $uri.UserInfo) {
        throw 'Every asset URL must be a concrete HTTPS URL without userinfo or backslashes.'
    }
}

function Get-ManifestAsset {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary] $Manifest)
    $architectures = @('root')
    if (Test-PolicyKey $Manifest 'architecture') {
        if ($Manifest.architecture -isnot [Collections.IDictionary] -or !$Manifest.architecture.PSBase.Count) { throw 'architecture must be a nonempty object.' }
        $architectures = @($Manifest.architecture.PSBase.Keys)
        foreach ($architecture in $architectures) {
            if ($architecture -cnotin @('32bit', '64bit', 'arm64')) { throw "Unsupported architecture '$architecture'." }
        }
    }
    $assets = @(foreach ($architecture in $architectures) {
        $scope = $Manifest
        if ($architecture -cne 'root') {
            $scope = $Manifest.architecture[$architecture]
            if ($scope -isnot [Collections.IDictionary]) { throw "Invalid architecture object '$architecture'." }
        }
        $urls = if (Test-PolicyKey $scope 'url') { $scope['url'] } else { $Manifest['url'] }
        $hashes = if (Test-PolicyKey $scope 'hash') { $scope['hash'] } else { $Manifest['hash'] }
        $urls, $hashes = @($urls), @($hashes)
        if (!$urls.Count -or $urls.Count -ne $hashes.Count) { throw "URL/hash cardinality mismatch for '$architecture'." }
        for ($i = 0; $i -lt $urls.Count; $i++) {
            Assert-PolicyUrl -Url $urls[$i]
            if ($hashes[$i] -isnot [string] -or $hashes[$i] -cnotmatch '^(?:sha256:)?[a-fA-F0-9]{64}$') {
                throw "Every asset hash must be concrete SHA256 for '$architecture'; skip is forbidden."
            }
            [pscustomobject]@{ Architecture = $architecture; Url = $urls[$i]; Hash = $hashes[$i] }
        }
    })
    return $assets
}

function Test-PolicyEqual {
    param([AllowNull()][object] $Left, [AllowNull()][object] $Right)
    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    if ($Left -is [Collections.IDictionary] -and $Right -is [Collections.IDictionary]) {
        if ($Left.PSBase.Count -ne $Right.PSBase.Count) { return $false }
        foreach ($key in $Left.PSBase.Keys) {
            if (!(Test-PolicyKey $Right $key) -or !(Test-PolicyEqual $Left[$key] $Right[$key])) { return $false }
        }
        return $true
    }
    if ($Left -is [Collections.IList] -and $Right -is [Collections.IList]) {
        if ($Left.Count -ne $Right.Count) { return $false }
        for ($i = 0; $i -lt $Left.Count; $i++) {
            if (!(Test-PolicyEqual $Left[$i] $Right[$i])) { return $false }
        }
        return $true
    }
    if ($Left.GetType() -ne $Right.GetType()) { return $false }
    if ($Left -is [string]) { return $Left -ceq $Right }
    return $Left.Equals($Right)
}

function Assert-PolicyShape {
    param([object] $Before, [object] $After, [string] $Path)
    if ($Before -is [string] -and $After -is [string]) { return }
    if ($Before -isnot [Collections.IList] -or $After -isnot [Collections.IList] -or
        !$Before.Count -or $Before.Count -ne $After.Count) { throw "Unsupported structure or array shape change at '$Path'." }
    for ($i = 0; $i -lt $Before.Count; $i++) { Assert-PolicyShape $Before[$i] $After[$i] "$Path[$i]" }
}

function Expand-PolicyValue {
    param([object] $Value, [Collections.IDictionary] $Substitutions)
    if ($Value -is [string]) {
        $expanded = $Value
        foreach ($key in ($Substitutions.PSBase.Keys | Sort-Object Length -Descending)) {
            $expanded = $expanded.Replace($key, [string] $Substitutions[$key])
        }
        if ($expanded.Contains('$')) { throw "Unsupported or unavailable substitution in '$Value'." }
        return $expanded
    }
    if ($Value -isnot [Collections.IList] -or !$Value.Count) { throw 'Unsupported template value; expected a string or nonempty array.' }
    $expanded = @(foreach ($item in $Value) { ,(Expand-PolicyValue $item $Substitutions) })
    return ,$expanded
}

function Assert-PolicyHashTemplate {
    param([object] $Value, [Collections.IDictionary] $Substitutions)
    $allowedFields = @('url', 'regex', 'find', 'jp', 'jsonpath', 'xpath', 'mode', 'type')
    $hashVariables = @('$urlNoExt', '$basenameNoExt', '$baseurl', '$basename', '$url', '$sha256', '$sha512', '$sha1', '$md5', '$checksum', '$base64')
    foreach ($entry in @($Value)) {
        if ($entry -isnot [Collections.IDictionary]) { throw 'Unsupported hash extraction template type.' }
        foreach ($key in $entry.PSBase.Keys) {
            if ($key -cnotin $allowedFields -or $entry[$key] -isnot [string]) { throw "Unsupported hash template field '$key'." }
            $text = $entry[$key]
            foreach ($variable in ($Substitutions.PSBase.Keys | Sort-Object Length -Descending)) { $text = $text.Replace($variable, [string] $Substitutions[$variable]) }
            foreach ($variable in $hashVariables) { $text = $text.Replace($variable, '') }
            if ($text -match '\$[A-Za-z_(]') { throw "Unsupported or unavailable hash substitution in '$($entry[$key])'." }
        }
    }
}

function Assert-PolicyTemplate {
    param([Collections.IDictionary] $Template, [Collections.IDictionary] $Substitutions, [string] $Path = 'autoupdate')
    foreach ($key in $Template.PSBase.Keys) {
        if ($key -ceq 'architecture' -and $Path -ceq 'autoupdate') {
            if ($Template[$key] -isnot [Collections.IDictionary]) { throw 'Unsupported autoupdate architecture template.' }
            foreach ($architecture in $Template[$key].PSBase.Keys) {
                if ($architecture -cnotin @('32bit', '64bit', 'arm64') -or $Template[$key][$architecture] -isnot [Collections.IDictionary]) {
                    throw "Unsupported autoupdate architecture '$architecture'."
                }
                Assert-PolicyTemplate $Template[$key][$architecture] $Substitutions "$Path.architecture.$architecture"
            }
        } elseif ($key -ceq 'hash') {
            Assert-PolicyHashTemplate $Template[$key] $Substitutions
        } elseif ($key -cin @('url', 'extract_dir', 'bin', 'shortcuts')) {
            $null = Expand-PolicyValue $Template[$key] $Substitutions
            if ($key -ceq 'url') {
                foreach ($url in @($Template[$key])) {
                    if ($url -isnot [string] -or $url -cnotmatch '^https://([^/?#]+)' -or $Matches[1].Contains('$')) {
                        throw "Unsupported URL template authority/origin at '$Path.url'."
                    }
                }
            }
        } else { throw "Unsupported autoupdate field '$Path.$key'." }
    }
}

function Assert-PolicyRelativePath {
    param([object] $Value, [string] $Field)
    if ($Value -isnot [string] -or !$Value.Length -or $Value -match '^[\\/]|[<>:"|?*\x00-\x1f]' -or
        '..' -cin ($Value -split '[/\\]')) { throw "Unsafe relative path or traversal in '$Field'." }
    foreach ($segment in ($Value -split '[/\\]')) {
        if (($segment -cne '.' -and $segment -match '[. ]$') -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Unsafe Windows relative path segment in '$Field'."
        }
    }
}

function Assert-PolicyPath {
    param([string] $Field, [object] $Value)
    foreach ($entry in @($Value)) {
        $target = if ($entry -is [Collections.IList]) { $entry[0] } else { $entry }
        Assert-PolicyRelativePath $target $Field
    }
}

function Get-PolicyTemplateValue {
    param([Collections.IDictionary] $Template, [string] $Architecture, [string] $Field)
    if ($Architecture -and (Test-PolicyKey $Template 'architecture') -and
        (Test-PolicyKey $Template.architecture $Architecture) -and (Test-PolicyKey $Template.architecture[$Architecture] $Field)) {
        return ,($Template.architecture[$Architecture][$Field])
    }
    if (Test-PolicyKey $Template $Field) { return ,($Template[$Field]) }
    return $null
}

function Assert-PolicyScope {
    param([Collections.IDictionary] $Before, [Collections.IDictionary] $After, [Collections.IDictionary] $Template,
        [Collections.IDictionary] $NewSubstitutions, [string] $Architecture = '')
    $scopeName = if ($Architecture) { "architecture.$Architecture" } else { 'manifest' }
    foreach ($key in $After.PSBase.Keys) {
        if (Test-PolicyKey $Before $key) { continue }
        if ($key -cne 'extract_dir' -or $After[$key] -isnot [string]) { throw "Unsupported structure change at '$scopeName.$key'." }
        $value = Get-PolicyTemplateValue $Template $Architecture $key
        if ($null -eq $value -or !(Test-PolicyEqual $After[$key] (Expand-PolicyValue $value $NewSubstitutions))) {
            throw "Missing unchanged autoupdate template or unexplained addition at '$scopeName.$key'."
        }
        Assert-PolicyRelativePath $After[$key] "$scopeName.$key"
    }
    foreach ($key in $Before.PSBase.Keys) {
        if (!(Test-PolicyKey $After $key)) { throw "Unsupported structure change at '$scopeName.$key'." }
        if (!$Architecture -and $key -ceq 'version') { continue }
        if (!$Architecture -and $key -ceq 'architecture') {
            foreach ($arch in @($Before.architecture.PSBase.Keys) + @($After.architecture.PSBase.Keys)) {
                if (!(Test-PolicyKey $Before.architecture $arch) -or !(Test-PolicyKey $After.architecture $arch)) { throw 'Unsupported architecture structure change.' }
            }
            foreach ($arch in $Before.architecture.PSBase.Keys) {
                Assert-PolicyScope $Before.architecture[$arch] $After.architecture[$arch] $Template $NewSubstitutions $arch
            }
        } elseif ($key -cin @('url', 'hash', 'extract_dir', 'bin', 'shortcuts')) {
            Assert-PolicyShape $Before[$key] $After[$key] "$scopeName.$key"
            if ($key -ceq 'hash') { continue }
            if ($key -cne 'url' -and (Test-PolicyEqual $Before[$key] $After[$key])) { continue }
            $value = Get-PolicyTemplateValue $Template $Architecture $key
            if ($null -eq $value) { throw "Missing unchanged autoupdate template for '$scopeName.$key'." }
            # Trusted forward templates need not describe the historical pinned layout.
            $newValue = Expand-PolicyValue $value $NewSubstitutions
            if (!(Test-PolicyEqual $After[$key] $newValue)) {
                throw "Unexplained change at '$scopeName.$key'; unchanged template does not match."
            }
            if ($key -cne 'url') { Assert-PolicyPath $key $After[$key] }
        } elseif (!(Test-PolicyEqual $Before[$key] $After[$key])) {
            throw "Unsupported change at '$scopeName.$key'."
        }
    }
}

function Get-ManifestUpdateDecision {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary] $Before, [Parameter(Mandatory)][Collections.IDictionary] $After,
        [Parameter(Mandatory)][string] $ScoopHome)
    try {
        foreach ($manifest in @($Before, $After)) {
            if ($manifest['version'] -isnot [string] -or $manifest['version'] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$' -or
                $manifest['version'] -cnotmatch '\d') { throw 'Unsupported or nonconcrete version.' }
            if ($manifest['autoupdate'] -isnot [Collections.IDictionary]) { throw 'Missing or wrongly typed autoupdate template.' }
        }
        if (!(Test-PolicyEqual $Before['autoupdate'] $After['autoupdate'])) { throw 'Unsupported change to autoupdate definitions.' }
        # ScoopHome is a pinned, trusted installation supplied by the caller, never PR data.
        . (Get-PolicyFile (Join-Path $ScoopHome 'lib/versions.ps1') -AllowLinkedParents)
        . (Get-PolicyFile (Join-Path $ScoopHome 'lib/autoupdate.ps1') -AllowLinkedParents)
        try {
            $comparison = Compare-Version -ReferenceVersion $Before['version'] -DifferenceVersion $After['version'] -ErrorAction Stop
        } catch { throw "Scoop version comparison failed: $($_.Exception.Message)" }
        if ($comparison -le 0) { throw 'Version must be a strict upgrade; downgrades and same-version repacks are forbidden.' }
        $oldSubstitutions = Get-VersionSubstitution $Before['version']
        $newSubstitutions = Get-VersionSubstitution $After['version']
        Assert-PolicyTemplate $Before['autoupdate'] $oldSubstitutions
        Assert-PolicyTemplate $Before['autoupdate'] $newSubstitutions
        $assets = @(Get-ManifestAsset -Manifest $After)
        if (!$assets.Count) { throw 'No assets were validated.' }
        Assert-PolicyScope $Before $After $Before['autoupdate'] $newSubstitutions
        return [pscustomobject]@{ Allowed = $true; Reason = 'Strict version upgrade explained by unchanged trusted templates.'; Assets = $assets }
    } catch {
        return [pscustomobject]@{ Allowed = $false; Reason = $_.Exception.Message; Assets = @() }
    }
}

function Invoke-PolicyValidator {
    param([string] $Executable, [string] $Schema, [string] $Manifest)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $PSScriptRoot
    $start.ArgumentList.Add($Schema)
    $start.ArgumentList.Add($Manifest)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (!$process.Start()) { throw 'Scoop validator failed to start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $validatorTimeoutMilliseconds = 30000
        if (!$process.WaitForExit($validatorTimeoutMilliseconds)) {
            $process.Kill($true)
            throw 'Scoop validator timed out.'
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}

function Assert-ManifestSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $ScoopHome)
    $null = Read-StrictJsonFile -Path $Path
    $manifest = Get-PolicyFile -Path $Path
    $schema = Get-PolicyFile (Join-Path $ScoopHome 'schema.json') -AllowLinkedParents
    $executable = Get-PolicyFile (Join-Path $ScoopHome 'supporting/validator/bin/validator.exe') -AllowLinkedParents
    foreach ($name in @('Scoop.Validator.dll', 'Newtonsoft.Json.dll', 'Newtonsoft.Json.Schema.dll')) {
        $null = Get-PolicyFile (Join-Path $ScoopHome "supporting/validator/bin/$name") -AllowLinkedParents
    }
    $result = Invoke-PolicyValidator -Executable $executable -Schema $schema -Manifest $manifest
    $evidence = '(?m)^\s*(?:-\s+|\[\+\]\s+)' + [regex]::Escape([IO.Path]::GetFileName($manifest)) + ' validates against the schema!\s*$'
    if ($result.ExitCode -ne 0 -or $result.Output -cnotmatch $evidence -or
        $result.Output -match '(?im)free-quota|quota.*exceed|^\s*skip(?:ped|ping)?\b|validation.*limit') {
        throw "Scoop validator did not affirm successful validation (exit $($result.ExitCode)): $($result.Output)"
    }
}

function Test-PublishAuthorization {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string] $Enabled, [AllowNull()][object] $Publish)
    return ($Enabled -ceq 'true' -and $Publish -is [bool] -and $Publish)
}

Export-ModuleMember -Function Read-StrictJsonFile, Assert-SafeAppName, Get-ManifestMaintenanceState, Get-ManifestAsset, Assert-ManifestSchema, Get-ManifestUpdateDecision, Test-PublishAuthorization
