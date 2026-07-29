param(
    [Parameter(Mandatory = $false)]
    [string]$GodotPath = "",

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 600)]
    [int]$TimeoutSeconds = 150,

    [switch]$KeepLogs
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if (-not $GodotPath) {
    if ($env:GODOT_BIN) {
        $GodotPath = $env:GODOT_BIN
    } else {
        $godotCommand = Get-Command godot -ErrorAction SilentlyContinue
        if ($godotCommand) {
            $GodotPath = $godotCommand.Source
        }
    }
}
if (-not $GodotPath -or -not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) {
    throw "Godot executable not found. Pass -GodotPath or set GODOT_BIN."
}
$GodotPath = (Resolve-Path -LiteralPath $GodotPath).Path

$logRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "luckweaver-mp-" + [Guid]::NewGuid().ToString("N")
)
$null = New-Item -ItemType Directory -Path $logRoot
$hostOut = Join-Path $logRoot "host.stdout.log"
$hostErr = Join-Path $logRoot "host.stderr.log"
$clientOut = Join-Path $logRoot "client.stdout.log"
$clientErr = Join-Path $logRoot "client.stderr.log"
$hostProcess = $null
$clientProcess = $null
$testPassed = $false

function Get-CombinedLog {
    param([string]$StdoutPath, [string]$StderrPath)
    $parts = @()
    if (Test-Path -LiteralPath $StdoutPath) {
        $parts += Get-Content -LiteralPath $StdoutPath -Raw
    }
    if (Test-Path -LiteralPath $StderrPath) {
        $parts += Get-Content -LiteralPath $StderrPath -Raw
    }
    return ($parts -join [Environment]::NewLine)
}

function Wait-ForMarker {
    param(
        [string]$StdoutPath,
        [string]$StderrPath,
        [string]$Marker,
        [int]$Seconds
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Get-CombinedLog $StdoutPath $StderrPath) -match [regex]::Escape($Marker)) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Stop-ProcessTree {
    param([int]$RootProcessId)
    $children = Get-CimInstance Win32_Process |
        Where-Object { $_.ParentProcessId -eq $RootProcessId }
    foreach ($child in $children) {
        Stop-ProcessTree -RootProcessId ([int]$child.ProcessId)
    }
    Stop-Process -Id $RootProcessId -Force -ErrorAction SilentlyContinue
}

try {
    $quotedRoot = '"' + $projectRoot.Replace('"', '\"') + '"'
    $hostProcess = Start-Process -FilePath $GodotPath `
        -ArgumentList @("--headless", "--path", $quotedRoot, "res://tests/mp_host.tscn") `
        -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $hostOut -RedirectStandardError $hostErr

    if (-not (Wait-ForMarker $hostOut $hostErr "[mp_host] hosting LAN" 30)) {
        throw "Host did not open its LAN session within 30 seconds."
    }

    $clientProcess = Start-Process -FilePath $GodotPath `
        -ArgumentList @("--headless", "--path", $quotedRoot, "res://tests/mp_client.tscn") `
        -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $clientOut -RedirectStandardError $clientErr

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $hostProcess.Refresh()
        $clientProcess.Refresh()
        if ($hostProcess.HasExited -and $clientProcess.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    $hostProcess.Refresh()
    $clientProcess.Refresh()
    if (-not $hostProcess.HasExited -or -not $clientProcess.HasExited) {
        throw "Multiplayer test exceeded ${TimeoutSeconds}s."
    }

    $hostLog = Get-CombinedLog $hostOut $hostErr
    $clientLog = Get-CombinedLog $clientOut $clientErr
    Write-Output "===== HOST ====="
    Write-Output $hostLog.TrimEnd()
    Write-Output "===== CLIENT ====="
    Write-Output $clientLog.TrimEnd()

    if ($hostProcess.ExitCode -ne 0 -or $hostLog -notmatch "MP HOST PASS") {
        throw "Host failed (exit $($hostProcess.ExitCode))."
    }
    if ($clientProcess.ExitCode -ne 0 -or $clientLog -notmatch "MP CLIENT PASS") {
        throw "Client failed (exit $($clientProcess.ExitCode))."
    }
    Write-Output "MULTIPLAYER PASS"
    $testPassed = $true
} finally {
    if ($clientProcess -and -not $clientProcess.HasExited) {
        Stop-ProcessTree -RootProcessId $clientProcess.Id
    }
    if ($hostProcess -and -not $hostProcess.HasExited) {
        Stop-ProcessTree -RootProcessId $hostProcess.Id
    }
    if ($KeepLogs -or -not $testPassed) {
        Write-Output "Logs: $logRoot"
    } elseif (Test-Path -LiteralPath $logRoot) {
        $resolvedLogRoot = (Resolve-Path -LiteralPath $logRoot).Path
        $resolvedTemp = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path
        if ($resolvedLogRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedLogRoot -Recurse -Force
        }
    }
}
