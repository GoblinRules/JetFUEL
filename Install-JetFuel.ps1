param(
    [string]$BaseUrl = "https://raw.githubusercontent.com/GoblinRules/JetFUEL/main"
)

$ErrorActionPreference = "Stop"

$targetDir = Join-Path $env:LOCALAPPDATA "JetFUEL"
$target = Join-Path $targetDir "JetFuel.ps1"
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

$downloads = @(
    @{ Uri = "$BaseUrl/JetFuel.ps1"; OutFile = $target },
    @{ Uri = "$BaseUrl/install-tailscale.sh"; OutFile = (Join-Path $targetDir "install-tailscale.sh") },
    @{ Uri = "$BaseUrl/install-tailscale.metadata.json"; OutFile = (Join-Path $targetDir "install-tailscale.metadata.json") },
    @{ Uri = "$BaseUrl/assets/icon.ico"; OutFile = (Join-Path $targetDir "assets\icon.ico") },
    @{ Uri = "$BaseUrl/assets/icon.png"; OutFile = (Join-Path $targetDir "assets\icon.png") },
    @{ Uri = "$BaseUrl/third_party/ConfigJon-Firmware-Management/metadata.json"; OutFile = (Join-Path $targetDir "third_party\ConfigJon-Firmware-Management\metadata.json") },
    @{ Uri = "$BaseUrl/third_party/ConfigJon-Firmware-Management/LICENSE"; OutFile = (Join-Path $targetDir "third_party\ConfigJon-Firmware-Management\LICENSE") },
    @{ Uri = "$BaseUrl/third_party/ConfigJon-Firmware-Management/Dell/Manage-DellBiosSettings-WMI.ps1"; OutFile = (Join-Path $targetDir "third_party\ConfigJon-Firmware-Management\Dell\Manage-DellBiosSettings-WMI.ps1") },
    @{ Uri = "$BaseUrl/third_party/ConfigJon-Firmware-Management/HP/Manage-HPBiosSettings-WMI.ps1"; OutFile = (Join-Path $targetDir "third_party\ConfigJon-Firmware-Management\HP\Manage-HPBiosSettings-WMI.ps1") },
    @{ Uri = "$BaseUrl/third_party/ConfigJon-Firmware-Management/Lenovo/Manage-LenovoBiosSettings.ps1"; OutFile = (Join-Path $targetDir "third_party\ConfigJon-Firmware-Management\Lenovo\Manage-LenovoBiosSettings.ps1") }
)

foreach ($item in $downloads) {
    $parent = Split-Path -Parent $item.OutFile
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Write-Host "Downloading $($item.Uri)"
    Invoke-WebRequest -UseBasicParsing -Uri $item.Uri -OutFile $item.OutFile
}

Write-Host "Starting JetFUEL..."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $target
