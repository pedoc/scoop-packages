Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Connect to the vetted resolved address itself, avoiding a DNS check/connect rebinding gap.
$script:PublicAssetClientSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
namespace ScoopMaintenance {
    public static class PublicAssetClient {
        public static bool IsPublic(IPAddress address) {
            if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
            if (IPAddress.IsLoopback(address)) return false;
            byte[] b = address.GetAddressBytes();
            if (address.AddressFamily == AddressFamily.InterNetwork) {
                if (b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224) return false;
                if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return false;
                if (b[0] == 169 && b[1] == 254) return false;
                if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return false;
                if (b[0] == 192 && (b[1] == 168 || (b[1] == 0 && (b[2] == 0 || b[2] == 2)))) return false;
                if (b[0] == 198 && (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100))) return false;
                if (b[0] == 203 && b[1] == 0 && b[2] == 113) return false;
                return true;
            }
            if (address.AddressFamily != AddressFamily.InterNetworkV6) return false;
            // Permit global unicast only; reject transition, documentation, and special ranges.
            if ((b[0] & 0xe0) != 0x20 || (b[0] == 0x20 && b[1] == 0x02)) return false;
            if (b[0] == 0x20 && b[1] == 0x01 && (b[2] < 2 || (b[2] == 0x0d && b[3] == 0xb8))) return false;
            return true;
        }
        public static HttpClient Create() {
            var handler = new SocketsHttpHandler {
                AllowAutoRedirect = false, UseProxy = false,
                AutomaticDecompression = DecompressionMethods.None,
                ConnectTimeout = TimeSpan.FromSeconds(30), MaxConnectionsPerServer = 2
            };
            handler.ConnectCallback = async (context, token) => {
                IPAddress[] addresses = await Dns.GetHostAddressesAsync(context.DnsEndPoint.Host, token);
                Exception last = null;
                foreach (var address in addresses) {
                    if (!IsPublic(address)) continue;
                    var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                    try {
                        await socket.ConnectAsync(new IPEndPoint(address, context.DnsEndPoint.Port), token);
                        return new NetworkStream(socket, true);
                    } catch (Exception error) { socket.Dispose(); last = error; }
                }
                throw new HttpRequestException("No permitted public asset endpoint could be reached.", last);
            };
            var client = new HttpClient(handler, true);
            client.Timeout = Timeout.InfiniteTimeSpan;
            client.DefaultRequestHeaders.UserAgent.ParseAdd("scoop-maintenance/1");
            return client;
        }
    }
}
'@

function Initialize-GithubDownloadClient {
    if ('ScoopMaintenance.PublicAssetClient' -as [type]) { return }
    Add-Type -TypeDefinition $script:PublicAssetClientSource
}

function Assert-GithubAssetUri {
    param([string]$Url)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or
        $uri.UserInfo -ne '' -or [string]::IsNullOrEmpty($uri.Host) -or $uri.IsLoopback) { throw 'Asset must use a public HTTPS URL without credentials.' }
    $builder = [UriBuilder]::new($uri)
    $builder.Fragment = ''
    return $builder.Uri
}

function Get-GithubAssetClient {
    Initialize-GithubDownloadClient
    return [ScoopMaintenance.PublicAssetClient]::Create()
}

function Save-GithubAsset {
    <#
    .SYNOPSIS
    Streams one public HTTPS asset into its own fresh directory under fixed limits.
    .DESCRIPTION
    Redirect destinations are revalidated; connections use vetted public resolved IPs.
    No GitHub token, authorization header, downloaded script or executable is used.
    Archive handling is separate and read-only; asset bytes are never extracted here.
    #>
    param([string]$Url, [string]$Directory, [long]$MaxBytes = 1073741824, [int]$TimeoutSeconds = 300)
    $uri = Assert-GithubAssetUri -Url $Url
    $path = Join-Path $Directory 'asset.bin'
    $client = Get-GithubAssetClient
    $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        for ($redirects = 0; $redirects -le 5; $redirects++) {
            $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token).GetAwaiter().GetResult()
            try {
                if ([int]$response.StatusCode -in @(301, 302, 303, 307, 308)) {
                    if ($redirects -eq 5 -or $null -eq $response.Headers.Location) { throw 'Asset exceeded the redirect limit or has no redirect destination.' }
                    $next = [Uri]::new($uri, $response.Headers.Location)
                    $uri = Assert-GithubAssetUri -Url $next.AbsoluteUri
                    continue
                }
                $null = $response.EnsureSuccessStatusCode()
                if ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -gt $MaxBytes) { throw 'Asset exceeds the download size limit.' }
                $source = $response.Content.ReadAsStreamAsync($cancellation.Token).GetAwaiter().GetResult()
                $target = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $buffer = [byte[]]::new(1048576)
                    [long]$length = 0
                    while (($read = $source.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
                        $length += $read
                        if ($length -gt $MaxBytes) { throw 'Asset exceeds the download size limit.' }
                        $target.Write($buffer, 0, $read)
                    }
                    if ($length -le 0) { throw 'Asset download was empty.' }
                } finally { $target.Dispose(); $source.Dispose() }
                return @{ Path = $path; Length = $length; Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
            } finally { $response.Dispose() }
        }
        throw 'Asset download did not complete.'
    } finally { $client.Dispose(); $cancellation.Dispose() }
}

function Get-GithubZipDirectory {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 22) { throw 'Invalid bounded central directory in ZIP archive.' }
        $length = [int][Math]::Min($stream.Length, 65557)
        $start = $stream.Length - $length
        $stream.Position = $start
        $tail = $reader.ReadBytes($length)
        for ($offset = $tail.Length - 22; $offset -ge 0; $offset--) {
            if ([BitConverter]::ToUInt32($tail, $offset) -ne 0x06054b50) { continue }
            $commentLength = [BitConverter]::ToUInt16($tail, $offset + 20)
            if ($offset + 22 + $commentLength -ne $tail.Length) { continue }
            $count = [BitConverter]::ToUInt16($tail, $offset + 10)
            $size = [BitConverter]::ToUInt32($tail, $offset + 12)
            $position = [BitConverter]::ToUInt32($tail, $offset + 16)
            if ([BitConverter]::ToUInt16($tail, $offset + 4) -ne 0 -or [BitConverter]::ToUInt16($tail, $offset + 6) -ne 0 -or
                [BitConverter]::ToUInt16($tail, $offset + 8) -ne $count -or $count -eq 0 -or $count -gt 50000 -or
                $size -gt 8388608 -or [long]$position + $size -ne $start + $offset) { throw 'ZIP exceeds the bounded central directory format, count or size limit; ZIP64/multidisk is unsupported.' }
            return @{ Count = $count; Position = [long]$position; End = [long]$position + $size }
        }
        throw 'Invalid bounded central directory in ZIP archive.'
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Assert-GithubZipDirectory {
    param([string]$Path, [System.Collections.IDictionary]$Directory)
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $stream.Position = $Directory.Position
        for ($index = 0; $index -lt $Directory.Count; $index++) {
            if ($stream.Position + 46 -gt $Directory.End) { throw 'ZIP central directory entry exceeds its bounded region.' }
            $header = $reader.ReadBytes(46)
            if ($header.Length -ne 46 -or [BitConverter]::ToUInt32($header, 0) -ne 0x02014b50) { throw 'Invalid ZIP central directory entry.' }
            $skip = [int][BitConverter]::ToUInt16($header, 28) + [BitConverter]::ToUInt16($header, 30) + [BitConverter]::ToUInt16($header, 32)
            if ($stream.Position + $skip -gt $Directory.End -or [BitConverter]::ToUInt16($header, 34) -ne 0 -or
                ([BitConverter]::ToUInt16($header, 8) -band 65) -ne 0 -or
                [BitConverter]::ToUInt32($header, 20) -eq [uint32]::MaxValue -or [BitConverter]::ToUInt32($header, 24) -eq [uint32]::MaxValue -or
                [BitConverter]::ToUInt32($header, 42) -ge $Directory.Position) { throw 'ZIP central directory uses unsupported encrypted, ZIP64 or out-of-bounds metadata.' }
            $stream.Position += $skip
        }
        if ($stream.Position -ne $Directory.End) { throw 'ZIP central directory count or region does not match.' }
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function ConvertTo-GithubArchivePath {
    param([string]$Path)
    $name = $Path.Replace('\', '/')
    if ($name -match '(^/|[<>:"|?*\x00-\x1f])') { throw 'Archive contains unsafe paths.' }
    $segments = foreach ($segment in ($name -split '/')) {
        if ($segment -ceq '..' -or ($segment -cne '.' -and $segment -match '[. ]$') -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'Archive contains unsafe Windows paths.' }
        if ($segment -cne '.' -and $segment -cne '') { $segment }
    }
    return (@($segments) -join '/')
}

function Test-GithubZipLayout {
    param([string]$Path, [string]$ExtractDirectory)
    $directory = Get-GithubZipDirectory -Path $Path
    Assert-GithubZipDirectory -Path $Path -Directory $directory
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if ($archive.Entries.Count -eq 0 -or $archive.Entries.Count -gt 50000) { throw 'Archive has an invalid or excessive entry count.' }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [long]$expanded = 0
        foreach ($entry in $archive.Entries) {
            $name = ConvertTo-GithubArchivePath -Path $entry.FullName
            if ((($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960 -or
                ($entry.ExternalAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Archive contains symbolic links or reparse points.' }
            if (-not $names.Add($name)) { throw 'Archive contains conflicting paths.' }
            $expanded += $entry.Length
            if ($expanded -gt 10737418240 -or ($entry.Length -gt 0 -and
                ($entry.CompressedLength -eq 0 -or $entry.Length / $entry.CompressedLength -gt 1000))) { throw 'Archive exceeds bounded expanded-size or compression-ratio limits.' }
        }
        if (-not [string]::IsNullOrEmpty($ExtractDirectory)) {
            $prefix = ConvertTo-GithubArchivePath -Path $ExtractDirectory
            $present = $prefix -ceq '' -or @($names | Where-Object { $_.StartsWith($prefix + '/', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            if (-not $present) { throw 'Declared extract_dir was not found in the archive.' }
        }
        return @{ kind = 'zip'; entries = $archive.Entries.Count; extractDirectoryChecked = (-not [string]::IsNullOrEmpty($ExtractDirectory)) }
    } finally { $archive.Dispose() }
}

function Get-GithubAssetExtractDirectory {
    param([System.Collections.IDictionary]$Manifest, [object]$Asset)
    $extractDirectory = if (@($Manifest.Keys) -ccontains 'extract_dir') { $Manifest.extract_dir } else { '' }
    $architecture = 'root'
    if ($Asset -is [System.Collections.IDictionary]) {
        if (@($Asset.Keys) -ccontains 'Architecture') { $architecture = $Asset.Architecture }
    } elseif ($null -ne $Asset.PSObject.Properties['Architecture']) { $architecture = $Asset.Architecture }
    if (@($Manifest.Keys) -ccontains 'architecture' -and
        @($Manifest.architecture.Keys) -ccontains $architecture -and @($Manifest.architecture[$architecture].Keys) -ccontains 'extract_dir') {
        $extractDirectory = $Manifest.architecture[$architecture].extract_dir
    }
    if ($extractDirectory -isnot [string]) { throw 'Only string extract_dir values support archive layout validation.' }
    return $extractDirectory
}

function Invoke-GithubAssetVerification {
    param([object[]]$Assets, [System.Collections.IDictionary]$Manifest, [string]$Directory)
    if ($Assets.Count -le 0 -or $Assets.Count -gt 32) { throw 'Declared asset count is empty or exceeds the bounded validation limit.' }
    $assetRoot = Join-Path $Directory 'assets'
    if (Test-Path -LiteralPath $assetRoot) { throw 'Asset directory must be fresh.' }
    [void][IO.Directory]::CreateDirectory($assetRoot)
    [long]$total = 0
    $records = foreach ($asset in $Assets) {
        if ($asset.Hash -isnot [string] -or $asset.Hash -cnotmatch '^(?:sha256:)?[a-fA-F0-9]{64}$') { throw 'Every declared asset requires a full SHA256 digest.' }
        $expectedHash = ($asset.Hash -creplace '^sha256:', '').ToLowerInvariant()
        $assetDirectory = Join-Path $assetRoot ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($assetDirectory)
        $remaining = [Math]::Min([long]1073741824, [long]4294967296 - $total)
        if ($remaining -le 0) { throw 'Assets exceed the aggregate download limit.' }
        $download = Save-GithubAsset -Url $asset.Url -Directory $assetDirectory -MaxBytes $remaining
        $total += $download.Length
        if ($total -gt 4294967296) { throw 'Assets exceed the aggregate download limit.' }
        if ($download.Sha256 -cne $expectedHash) { throw 'Downloaded asset SHA256 does not match its manifest.' }
        $uri = [Uri]::new($asset.Url)
        $layout = @{ kind = 'not-supported'; reason = 'No safe bounded archive lister is implemented for this asset type.' }
        if ($uri.AbsolutePath -match '\.(zip|nupkg)$' -or $uri.Fragment -match '\.(zip|nupkg)$') {
            $extractDirectory = Get-GithubAssetExtractDirectory -Manifest $Manifest -Asset $asset
            $layout = Test-GithubZipLayout -Path $download.Path -ExtractDirectory $extractDirectory
        }
        @{ url = $asset.Url; sha256 = $download.Sha256; bytes = $download.Length; layout = $layout }
    }
    return @{ VerifiedAssetCount = @($records).Count; DeclaredAssetCount = $Assets.Count; Assets = @($records) }
}

Export-ModuleMember -Function Initialize-GithubDownloadClient, Assert-GithubAssetUri, Save-GithubAsset, Test-GithubZipLayout, Invoke-GithubAssetVerification
