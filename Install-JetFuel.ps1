param(
    [string]$ScriptUrl = "https://raw.githubusercontent.com/Revellio/JetFUEL/main/JetFuel.ps1"
)

$ErrorActionPreference = "Stop"

$targetDir = Join-Path $env:LOCALAPPDATA "JetFUEL"
$target = Join-Path $targetDir "JetFuel.ps1"
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

Write-Host "Downloading JetFUEL wizard from $ScriptUrl"
Invoke-WebRequest -UseBasicParsing -Uri $ScriptUrl -OutFile $target

Write-Host "Starting JetFUEL..."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $target
