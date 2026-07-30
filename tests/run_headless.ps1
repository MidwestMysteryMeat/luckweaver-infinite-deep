param(
    [Parameter(Mandatory = $false)]
    [string]$GodotPath = "",

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 600)]
    [int]$MultiplayerTimeoutSeconds = 150
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

function Invoke-GodotScene {
    param([string]$Scene)
    & $GodotPath --headless --path $projectRoot $Scene
    if ($LASTEXITCODE -ne 0) {
        throw "$Scene failed with exit code $LASTEXITCODE."
    }
}

Write-Output "===== IMPORT / GLOBAL CLASS CACHE ====="
# A fresh clone has no ignored .godot/global_script_class_cache.cfg. Import once
# before launching a test scene so class_name references resolve deterministically.
& $GodotPath --headless --path $projectRoot --import
if ($LASTEXITCODE -ne 0) {
    throw "Godot import failed with exit code $LASTEXITCODE."
}

Write-Output "===== SOLO SMOKE ====="
Invoke-GodotScene "res://tests/smoke.tscn"

Write-Output "===== FLUID / LIGHT REGRESSION ====="
Invoke-GodotScene "res://tests/fluid_light_regression.tscn"

Write-Output "===== MULTIPLAYER ====="
& (Join-Path $PSScriptRoot "run_mp.ps1") -GodotPath $GodotPath `
    -TimeoutSeconds $MultiplayerTimeoutSeconds
if ($LASTEXITCODE -ne 0) {
    throw "Multiplayer suite failed with exit code $LASTEXITCODE."
}

Write-Output "ALL HEADLESS TESTS PASS"
