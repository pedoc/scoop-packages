# Offline stand-in used only by native-boundary tests. Never invokes gh.
if ($args.Count -gt 0 -and $args[0] -eq 'exit7') {
    [Console]::Error.Write('HTTP 404 private response deliberately omitted from exception')
    exit 7
}
if ($args.Count -gt 0 -and $args[0] -eq 'big-error') {
    [Console]::Error.Write(('x' * 131072))
    exit 0
}
$payload = [Console]::In.ReadToEnd()
@{ arguments = @($args); inputText = $payload } | ConvertTo-Json -Compress
