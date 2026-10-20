param(
    [Parameter(Mandatory)]
    [ValidateSet('success', 'error', 'flood', 'timeout', 'environment', 'tree', 'sleep')]
    [string] $Mode,
    [string] $MarkerPath
)

$ErrorActionPreference = 'Stop'
switch ($Mode) {
    'success' {
        [Console]::Out.WriteLine('widget: 1.0.0')
        exit 0
    }
    'error' {
        [Console]::Error.WriteLine('simulated child failure')
        exit 7
    }
    'flood' {
        [Console]::Out.Write('x' * 200000)
        Start-Sleep -Seconds 30
    }
    'timeout' {
        [Console]::Out.WriteLine('started')
        Start-Sleep -Seconds 30
    }
    'environment' {
        [ordered]@{
            cwd = [Environment]::CurrentDirectory
            cache = $env:SCOOP_CACHE
            marker = $env:WORKER_TEST_MARKER
            profileLoaded = $null -ne (Get-Variable WorkerProfileLoaded -ErrorAction SilentlyContinue)
        } | ConvertTo-Json -Compress
    }
    'tree' {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = Join-Path $PSHOME 'pwsh.exe'
        $info.UseShellExecute = $false
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Mode', 'sleep', '-MarkerPath', $MarkerPath)) {
            $info.ArgumentList.Add($argument)
        }
        $child = [Diagnostics.Process]::Start($info)
        try { Start-Sleep -Seconds 30 } finally { $child.Dispose() }
    }
    'sleep' {
        [IO.File]::WriteAllText($MarkerPath, [string] $PID)
        Start-Sleep -Seconds 30
    }
}
