#Requires -Version 5.1
param(
    [switch]$NoGui
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [Windows.Forms.Application]::EnableVisualStyles() } catch {}
try {
    Add-Type -Namespace JetFuel -Name DpiNative -MemberDefinition @'
[DllImport("shcore.dll")]
public static extern int SetProcessDpiAwareness(int value);
[DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
[DllImport("kernel32.dll")]
public static extern uint SetErrorMode(uint uMode);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool SetDllDirectory(string lpPathName);
'@
    # 1 = PROCESS_SYSTEM_DPI_AWARE. Fails harmlessly when awareness was already set.
    if ([JetFuel.DpiNative]::SetProcessDpiAwareness(1) -ne 0) {
        [void][JetFuel.DpiNative]::SetProcessDPIAware()
    }
} catch {
    try { [void][JetFuel.DpiNative]::SetProcessDPIAware() } catch {}
}

function Get-UiScale {
    try {
        $graphics = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        try {
            return [Math]::Max(1.0, [double]$graphics.DpiX / 96.0)
        } finally {
            $graphics.Dispose()
        }
    } catch {
        return 1.0
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-CommandPath {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-JetFuelScriptRoot {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { return $PSScriptRoot }
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { return (Split-Path -Parent $PSCommandPath) }
    return (Get-Location).ProviderPath
}

function Get-CleanExceptionMessage {
    param([Parameter(Mandatory)]$ErrorRecord)

    if ($ErrorRecord.Exception.InnerException -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.Exception.InnerException.Message)) {
        return $ErrorRecord.Exception.InnerException.Message
    }
    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match "Program '.*?' failed to run: (.+?)(?:At .+?:line|\r?\n\s*At )") {
        return $matches[1].Trim()
    }
    $message = $message -replace '(?s)\s*At [A-Z]:\\.*?:line\s+\d+.*$', ''
    $message = $message -replace '(?s)At [A-Z]:\\.*?:line\s+\d+.*$', ''
    return $message.Trim()
}

function Test-WingetAvailable {
    $winget = Get-CommandPath -Name "winget.exe"
    if (-not $winget) {
        return @{
            Ok = $false
            Path = $null
            Message = "winget was not found. Install or repair Microsoft App Installer from the Microsoft Store, or install Git for Windows manually."
        }
    }

    try {
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $winget
        $psi.Arguments = "--version"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $process = [Diagnostics.Process]::Start($psi)
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill() } catch {}
            return @{
                Ok = $false
                Path = $winget
                Message = "winget exists but did not respond within 10 seconds."
            }
        }
        $output = (($process.StandardOutput.ReadToEnd(), $process.StandardError.ReadToEnd()) -join " ").Trim()
        if ($process.ExitCode -ne 0) {
            return @{
                Ok = $false
                Path = $winget
                Message = "winget exists but did not run successfully. Output: $output"
            }
        }
        return @{
            Ok = $true
            Path = $winget
            Message = "winget available: $output"
        }
    } catch {
        $cleanMessage = Get-CleanExceptionMessage -ErrorRecord $_
        return @{
            Ok = $false
            Path = $winget
            Message = "winget exists but Windows could not start it: $cleanMessage"
        }
    }
}

function Open-AppInstallerStorePage {
    Start-Process "ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1"
}

function Prompt-WingetRepairOrGitManual {
    param(
        [Parameter(Mandatory)]$WingetState
    )

    $choice = [Windows.Forms.MessageBox]::Show(
        "Git Bash was not found, and JetFUEL cannot install Git automatically because winget/App Installer is missing or broken.`r`n`r`n$($WingetState.Message)`r`n`r`nYes = open Microsoft Store to install/reinstall App Installer (winget)`r`nNo = open Git for Windows download page`r`nCancel = stop",
        "Repair winget or install Git",
        "YesNoCancel",
        "Warning"
    )

    if ($choice -eq [Windows.Forms.DialogResult]::Yes) {
        Open-AppInstallerStorePage
        throw "Opened Microsoft Store App Installer page. Install or reinstall App Installer, then run preflight again."
    }
    if ($choice -eq [Windows.Forms.DialogResult]::No) {
        Start-Process "https://git-scm.com/download/win"
        throw "Opened Git for Windows download page. Install Git for Windows, then run this wizard again."
    }

    throw $WingetState.Message
}

function Get-GitBashPath {
    $candidates = @(
        "${env:ProgramFiles}\Git\bin\bash.exe",
        "${env:ProgramFiles}\Git\usr\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "${env:LOCALAPPDATA}\Programs\Git\bin\bash.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate) -and (Test-IsGitForWindowsBash -BashPath $candidate)) {
            return $candidate
        }
    }

    $bash = Get-CommandPath -Name "bash.exe"
    if ($bash -and $bash -like "*\Git\*" -and (Test-IsGitForWindowsBash -BashPath $bash)) {
        return $bash
    }

    return $null
}

function Get-WslBashPath {
    $bash = Get-CommandPath -Name "bash.exe"
    if ($bash -and $bash -like "*\Windows\System32\bash.exe" -and (Test-IsWslBash -BashPath $bash)) {
        return $bash
    }
    $candidate = "$env:WINDIR\System32\bash.exe"
    if (Test-Path -LiteralPath $candidate) {
        if (Test-IsWslBash -BashPath $candidate) { return $candidate }
    }
    return $null
}

function Test-IsGitForWindowsBash {
    param([Parameter(Mandatory)][string]$BashPath)

    if (-not (Test-Path -LiteralPath $BashPath)) { return $false }
    try {
        $result = & $BashPath -lc "command -v cygpath >/dev/null 2>&1 && cygpath -u 'C:\Windows'" 2>$null
        return ($LASTEXITCODE -eq 0 -and ($result -join "`n") -match '^/c/Windows')
    } catch {
        return $false
    }
}

function Test-IsWslBash {
    param([Parameter(Mandatory)][string]$BashPath)

    if (-not (Test-Path -LiteralPath $BashPath)) { return $false }
    try {
        $result = & $BashPath -lc "command -v wslpath >/dev/null 2>&1 && wslpath -u 'C:\Windows'" 2>$null
        return ($LASTEXITCODE -eq 0 -and ($result -join "`n") -match '^/mnt/[a-z]/Windows')
    } catch {
        return $false
    }
}

function Select-BashForInstall {
    param([scriptblock]$Log)

    $gitBash = Get-GitBashPath
    if ($gitBash) {
        return @{ Path = $gitBash; Kind = "Git" }
    }

    $wslBash = Get-WslBashPath
    if ($wslBash) {
        $choice = [Windows.Forms.MessageBox]::Show(
            "Git Bash was not found. WSL bash is available.`r`n`r`nYes = install Git for Windows / Git Bash (recommended)`r`nNo = use WSL bash for this run`r`nCancel = stop",
            "Choose bash for JetFUEL",
            "YesNoCancel",
            "Question"
        )
        if ($choice -eq [Windows.Forms.DialogResult]::No) {
            & $Log "Using WSL bash by user choice: $wslBash"
            return @{ Path = $wslBash; Kind = "WSL" }
        }
        if ($choice -eq [Windows.Forms.DialogResult]::Cancel) {
            throw "Preflight cancelled. Git Bash was not installed and WSL bash was not selected."
        }
    } else {
        $wingetState = Test-WingetAvailable
        if (-not $wingetState.Ok) {
            Prompt-WingetRepairOrGitManual -WingetState $wingetState
        }

        $choice = [Windows.Forms.MessageBox]::Show(
            "Git Bash was not found. Install Git for Windows now using winget?",
            "Install Git Bash",
            "YesNo",
            "Question"
        )
        if ($choice -ne [Windows.Forms.DialogResult]::Yes) {
            throw "Git Bash is required unless WSL bash is installed and selected."
        }
    }

    $gitBash = Install-GitForWindows -Log $Log
    return @{ Path = $gitBash; Kind = "Git" }
}

function Install-GitForWindows {
    param([scriptblock]$Log)

    & $Log "Git Bash was not found. Trying to install Git for Windows with winget..."
    $wingetState = Test-WingetAvailable
    if (-not $wingetState.Ok) {
        Prompt-WingetRepairOrGitManual -WingetState $wingetState
    }
    $winget = $wingetState.Path
    & $Log $wingetState.Message

    $args = @(
        "install",
        "--id", "Git.Git",
        "--exact",
        "--source", "winget",
        "--accept-source-agreements",
        "--accept-package-agreements"
    )

    $process = Start-Process -FilePath $winget -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "winget failed to install Git for Windows. Exit code: $($process.ExitCode)"
    }

    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    $bash = Get-GitBashPath
    if (-not $bash) { throw "Git installed, but bash.exe was still not found. Restart PowerShell and try again." }

    & $Log "Git Bash installed: $bash"
    return $bash
}

function Write-JetFuelCleanupLog {
    param(
        [scriptblock]$Log,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Log) {
        & $Log $Message
    } else {
        Write-Host $Message
    }
}

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        return [IO.Path]::GetFullPath($Path).TrimEnd("\")
    } catch {
        return $Path.TrimEnd("\")
    }
}

function Test-PathInsideDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $normalPath = Get-NormalizedPath -Path $Path
    $normalRoot = Get-NormalizedPath -Path $Root
    if (-not $normalPath -or -not $normalRoot) { return $false }
    if ([string]::Equals($normalPath, $normalRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $normalPath.StartsWith($normalRoot + "\", [StringComparison]::OrdinalIgnoreCase)
}

function Start-JetFuelDelayedDirectoryRemoval {
    param([Parameter(Mandatory)][string]$Path)

    $safePath = $Path.Replace("'", "''")
    $parentPid = $PID
    $cleanupScript = @"
try { Wait-Process -Id $parentPid -Timeout 45 -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Seconds 2
`$target = '$safePath'
if (`$target -and (Test-Path -LiteralPath `$target)) {
    Remove-Item -LiteralPath `$target -Recurse -Force -ErrorAction SilentlyContinue
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanupScript))
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden",
        "-EncodedCommand", $encoded
    ) -WindowStyle Hidden | Out-Null
}

function Get-GitForWindowsInstallInfo {
    $bash = Get-GitBashPath
    if (-not $bash) { return $null }

    $binDir = Split-Path -Parent $bash
    $root = Split-Path -Parent $binDir
    if ((Split-Path -Leaf $root) -ieq "usr") {
        $root = Split-Path -Parent $root
    }

    return [pscustomobject]@{
        Bash = $bash
        Root = $root
        Uninstaller = Join-Path $root "unins000.exe"
    }
}

function Uninstall-GitForWindows {
    param([scriptblock]$Log)

    $gitInfo = Get-GitForWindowsInstallInfo
    if (-not $gitInfo) {
        Write-JetFuelCleanupLog -Log $Log -Message "Git Bash was not found; no Git uninstall needed."
        return
    }

    $wingetState = Test-WingetAvailable
    if ($wingetState.Ok) {
        Write-JetFuelCleanupLog -Log $Log -Message "Uninstalling Git for Windows with winget..."
        $args = @(
            "uninstall",
            "--id", "Git.Git",
            "--exact",
            "--silent",
            "--accept-source-agreements",
            "--disable-interactivity"
        )
        try {
            $process = Start-Process -FilePath $wingetState.Path -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
            if ($process.ExitCode -eq 0) {
                Write-JetFuelCleanupLog -Log $Log -Message "Git for Windows uninstall completed with winget."
                return
            }
            Write-JetFuelCleanupLog -Log $Log -Message "Warning: winget Git uninstall exited with code $($process.ExitCode); trying Git uninstaller if available."
        } catch {
            Write-JetFuelCleanupLog -Log $Log -Message "Warning: winget Git uninstall could not run: $(Get-CleanExceptionMessage -ErrorRecord $_)"
        }
    } else {
        Write-JetFuelCleanupLog -Log $Log -Message "Warning: $($wingetState.Message)"
    }

    if ($gitInfo.Uninstaller -and (Test-Path -LiteralPath $gitInfo.Uninstaller)) {
        Write-JetFuelCleanupLog -Log $Log -Message "Running Git for Windows uninstaller: $($gitInfo.Uninstaller)"
        $process = Start-Process -FilePath $gitInfo.Uninstaller -ArgumentList @("/VERYSILENT", "/NORESTART") -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -eq 0) {
            Write-JetFuelCleanupLog -Log $Log -Message "Git for Windows uninstall completed."
            return
        }
        throw "Git for Windows uninstaller failed with exit code $($process.ExitCode)."
    }

    throw "Git for Windows was found at $($gitInfo.Root), but JetFUEL could not find a working uninstaller."
}

function Remove-JetFuelTemporaryFiles {
    param([scriptblock]$Log)

    $tempRoot = [IO.Path]::GetTempPath()
    $items = @()
    try {
        $items = @(Get-ChildItem -LiteralPath $tempRoot -Force -ErrorAction Stop | Where-Object {
            $_.Name -match '^JetFUEL(-home)?-[0-9A-Fa-f]{32}$'
        })
    } catch {
        Write-JetFuelCleanupLog -Log $Log -Message "Warning: could not list temp files: $(Get-CleanExceptionMessage -ErrorRecord $_)"
    }

    foreach ($item in $items) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            Write-JetFuelCleanupLog -Log $Log -Message "Removed temp item: $($item.FullName)"
        } catch {
            Write-JetFuelCleanupLog -Log $Log -Message "Warning: could not remove temp item $($item.FullName): $(Get-CleanExceptionMessage -ErrorRecord $_)"
        }
    }

    if ($items.Count -eq 0) {
        Write-JetFuelCleanupLog -Log $Log -Message "No JetFUEL temp folders found."
    }
}

function Remove-JetFuelLocalCache {
    param([scriptblock]$Log)

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return }
    $localRoot = Join-Path $env:LOCALAPPDATA "JetFUEL"
    if (-not (Test-Path -LiteralPath $localRoot)) {
        Write-JetFuelCleanupLog -Log $Log -Message "No JetFUEL local cache found."
        return
    }

    if (Test-PathInsideDirectory -Path (Get-JetFuelScriptRoot) -Root $localRoot) {
        Start-JetFuelDelayedDirectoryRemoval -Path $localRoot
        Write-JetFuelCleanupLog -Log $Log -Message "Queued JetFUEL local cache removal after exit: $localRoot"
        return
    }

    Remove-Item -LiteralPath $localRoot -Recurse -Force -ErrorAction Stop
    Write-JetFuelCleanupLog -Log $Log -Message "Removed JetFUEL local cache: $localRoot"
}

function Invoke-JetFuelCleanup {
    param([scriptblock]$Log)

    Write-JetFuelCleanupLog -Log $Log -Message "Starting JetFUEL cleanup. SSH key files are left untouched."
    Remove-JetFuelTemporaryFiles -Log $Log
    Remove-JetFuelWebView2Support -Log $Log
    Remove-JetKvmDesktopClient -Log $Log -StopRunning
    Remove-JetFuelLocalCache -Log $Log

    $gitInfo = Get-GitForWindowsInstallInfo
    if ($gitInfo) {
        $choice = [Windows.Forms.MessageBox]::Show(
            "Uninstall Git for Windows / Git Bash now?`r`n`r`nThis can affect other tools that use Git. SSH keys in your .ssh folder will not be removed.",
            "Uninstall Git Bash?",
            "YesNo",
            "Warning"
        )
        if ($choice -eq [Windows.Forms.DialogResult]::Yes) {
            Uninstall-GitForWindows -Log $Log
        } else {
            Write-JetFuelCleanupLog -Log $Log -Message "Git for Windows left installed by user choice."
        }
    } else {
        Write-JetFuelCleanupLog -Log $Log -Message "Git Bash was not found; no Git uninstall needed."
    }

    Write-JetFuelCleanupLog -Log $Log -Message "Cleanup complete. SSH key files were not changed."
}

function Get-JetKvmDesktopInstallRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw "LOCALAPPDATA is not available, so JetFUEL cannot manage the Web UI."
    }
    return (Join-Path $env:LOCALAPPDATA "JetFUEL\tools\jetkvm-desktop")
}

function Get-JetKvmDesktopState {
    $root = Get-JetKvmDesktopInstallRoot
    $executable = Join-Path $root "jetkvm-desktop.exe"
    $manifestPath = Join-Path $root "jetfuel-install.json"
    $manifest = $null
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {}
    }
    return [pscustomobject]@{
        Installed = Test-Path -LiteralPath $executable
        Root = $root
        Executable = $executable
        ManifestPath = $manifestPath
        Version = if ($manifest -and $manifest.version) { [string]$manifest.version } else { $null }
        ReleaseUrl = if ($manifest -and $manifest.releaseUrl) { [string]$manifest.releaseUrl } else { $null }
    }
}

function Get-JetKvmDesktopLatestRelease {
    $headers = @{
        Accept = "application/vnd.github+json"
        "User-Agent" = "JetFUEL"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    $release = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/lkarlslund/jetkvm-desktop/releases/latest" -Headers $headers -ErrorAction Stop
    $asset = @($release.assets | Where-Object { $_.name -eq "jetkvm-desktop-windows-amd64.zip" }) | Select-Object -First 1
    if (-not $asset) {
        throw "The latest jetkvm-desktop release does not contain the expected Windows x64 ZIP."
    }
    $digest = [string]$asset.digest
    $digestMatch = [regex]::Match($digest, '^sha256:([0-9a-fA-F]{64})$')
    if (-not $digestMatch.Success) {
        throw "The jetkvm-desktop Windows release does not publish a usable SHA-256 digest."
    }
    return [pscustomobject]@{
        Version = [string]$release.tag_name
        ReleaseUrl = [string]$release.html_url
        AssetUrl = [string]$asset.browser_download_url
        AssetName = [string]$asset.name
        Sha256 = $digestMatch.Groups[1].Value.ToUpperInvariant()
    }
}

function Invoke-JetFuelResponsiveDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination
    )

    $client = [Net.WebClient]::new()
    $client.Headers[[Net.HttpRequestHeader]::UserAgent] = "JetFUEL"
    try {
        $task = $client.DownloadFileTaskAsync([Uri]$Uri, $Destination)
        while (-not $task.IsCompleted) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 60
        }
        if ($task.IsFaulted) {
            throw $task.Exception.GetBaseException()
        }
        if ($task.IsCanceled) {
            throw "The download was cancelled."
        }
    } finally {
        $client.Dispose()
    }
}

function Get-JetFuelFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $stream = $null
    $sha256 = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $sha256 = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "")
    } finally {
        if ($sha256) { $sha256.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Assert-JetKvmDesktopNotRunning {
    $running = @(Get-Process -Name "jetkvm-desktop" -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        throw "The Web UI is running. Close it before installing or updating it. Uninstall and Exit cleanup can close the JetFUEL-managed process automatically."
    }
}

function Stop-JetKvmDesktopClient {
    param([scriptblock]$Log)

    $state = Get-JetKvmDesktopState
    if (-not $state.Installed) { return }

    $managedExecutable = [IO.Path]::GetFullPath($state.Executable)
    $managedProcesses = @(Get-Process -Name "jetkvm-desktop" -ErrorAction SilentlyContinue | Where-Object {
        try {
            $_.Path -and ([IO.Path]::GetFullPath($_.Path) -ieq $managedExecutable)
        } catch {
            $false
        }
    })
    foreach ($process in $managedProcesses) {
        if ($process.HasExited) { continue }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            $null = $process.CloseMainWindow()
            $null = $process.WaitForExit(3000)
        }
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            $process.WaitForExit(3000)
        }
        if ($Log) { & $Log "Closed the JetFUEL-managed Web UI process." }
    }
}

function Test-JetKvmDesktopRuntimeDependencies {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    if (-not (Test-Path -LiteralPath $ExecutablePath)) {
        return [pscustomobject]@{
            Ready = $false
            Missing = @("jetkvm-desktop.exe")
            Invalid = @()
        }
    }

    # Follow the private MinGW dependency chain recursively. A system-wide DLL is
    # deliberately not accepted because an incompatible copy can cause 0xc000007b.
    $knownRuntimeDlls = @("libgcc_s_seh-1.dll", "libstdc++-6.dll", "libwinpthread-1.dll", "libssp-0.dll")
    $executableDirectory = Split-Path -Parent $ExecutablePath
    $expectedMachine = 0x8664
    $missing = New-Object Collections.Generic.List[string]
    $invalid = New-Object Collections.Generic.List[string]
    $pending = New-Object Collections.Queue
    $visited = @{}
    $pending.Enqueue($ExecutablePath)

    while ($pending.Count -gt 0) {
        $binaryPath = [string]$pending.Dequeue()
        $binaryName = Split-Path -Leaf $binaryPath
        if ($visited.ContainsKey($binaryName)) { continue }
        $visited[$binaryName] = $true

        if ((Get-PeMachineCode -Path $binaryPath) -ne $expectedMachine) {
            if (-not $invalid.Contains($binaryName)) { $invalid.Add($binaryName) }
            continue
        }

        $binaryText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($binaryPath))
        foreach ($dllName in $knownRuntimeDlls) {
            if ($binaryText.IndexOf($dllName, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $localDll = Join-Path $executableDirectory $dllName
            if (-not (Test-Path -LiteralPath $localDll)) {
                if (-not $missing.Contains($dllName)) { $missing.Add($dllName) }
                continue
            }
            $pending.Enqueue($localDll)
        }
    }

    return [pscustomobject]@{
        Ready = ($missing.Count -eq 0) -and ($invalid.Count -eq 0)
        Missing = @($missing)
        Invalid = @($invalid)
    }
}

function Get-PeMachineCode {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { return 0 }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 6)) { return 0 }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { return 0 }
        return $reader.ReadUInt16()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Add-JetKvmDesktopRuntimeDependencies {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [scriptblock]$Log
    )

    $executableMachine = Get-PeMachineCode -Path $ExecutablePath
    if ($executableMachine -ne 0x8664) {
        throw "The downloaded JetKVM Desktop executable is not the expected Windows x64 build."
    }

    $runtime = Test-JetKvmDesktopRuntimeDependencies -ExecutablePath $ExecutablePath
    if ($runtime.Ready) { return @() }
    $gitInfo = Get-GitForWindowsInstallInfo
    if (-not $gitInfo) {
        throw "The upstream JetKVM Desktop Windows package needs private MinGW runtime files, but Git for Windows is unavailable. Run Setup preflight and install Git for Windows, then retry."
    }
    $gitRuntimeDirectory = Join-Path $gitInfo.Root "mingw64\bin"
    $copied = @()
    for ($pass = 0; $pass -lt 5; $pass++) {
        $runtime = Test-JetKvmDesktopRuntimeDependencies -ExecutablePath $ExecutablePath
        if ($runtime.Ready) { break }
        $required = @($runtime.Missing) + @($runtime.Invalid | Where-Object { $_ -ne "jetkvm-desktop.exe" })
        $copiedThisPass = 0
        foreach ($dllName in ($required | Select-Object -Unique)) {
            $source = Join-Path $gitRuntimeDirectory $dllName
            if (-not (Test-Path -LiteralPath $source)) { continue }
            if ((Get-PeMachineCode -Path $source) -ne $executableMachine) { continue }
            Copy-Item -LiteralPath $source -Destination (Split-Path -Parent $ExecutablePath) -Force -ErrorAction Stop
            $copied += $dllName
            $copiedThisPass++
            if ($Log) { & $Log "[OK] Added $dllName from the local Git for Windows x64 runtime." }
        }
        if ($copiedThisPass -eq 0) { break }
    }

    $runtime = Test-JetKvmDesktopRuntimeDependencies -ExecutablePath $ExecutablePath
    if (-not $runtime.Ready) {
        $problems = @($runtime.Missing) + @($runtime.Invalid | ForEach-Object { "$_ (wrong architecture or invalid)" })
        throw "The upstream JetKVM Desktop Windows package has unusable runtime files: $($problems -join ', '). JetFUEL could not obtain a complete matching x64 runtime from Git for Windows."
    }
    return @($copied | Select-Object -Unique)
}

function Test-JetKvmDesktopLaunch {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ExecutablePath
    $startInfo.Arguments = "--help"
    $startInfo.WorkingDirectory = Split-Path -Parent $ExecutablePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $previousErrorMode = $null
    try {
        # Suppress Windows loader popups during the smoke test. A failure is
        # returned as an exit code and surfaced by JetFUEL instead.
        try { $previousErrorMode = [JetFuel.DpiNative]::SetErrorMode(0x0003) } catch {}
        if (-not $process.Start()) { throw "Windows did not start the executable." }
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill() } catch {}
            throw "The Web UI loader check did not finish within 10 seconds."
        }
        if ($process.ExitCode -ne 0) {
            $exitHex = ('0x{0:X8}' -f $process.ExitCode)
            throw "Windows could not load the Web UI executable (exit $exitHex). Reinstall Git for Windows x64, then retry the Web UI installation."
        }
    } finally {
        $process.Dispose()
        if ($null -ne $previousErrorMode) {
            try { [void][JetFuel.DpiNative]::SetErrorMode([uint32]$previousErrorMode) } catch {}
        }
    }
}

function Install-JetKvmDesktopClient {
    param([scriptblock]$Log)

    Assert-JetKvmDesktopNotRunning
    $release = Get-JetKvmDesktopLatestRelease
    $state = Get-JetKvmDesktopState
    $workRoot = Join-Path ([IO.Path]::GetTempPath()) ("JetFUEL-desktop-" + [Guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path $workRoot $release.AssetName
    $stagingPath = Join-Path $workRoot "staging"
    try {
        New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
        if ($Log) { & $Log "Downloading JetKVM Desktop $($release.Version) from the pinned upstream repository..." }
        Invoke-JetFuelResponsiveDownload -Uri $release.AssetUrl -Destination $archivePath
        $actualHash = Get-JetFuelFileSha256 -Path $archivePath
        if ($actualHash -ne $release.Sha256) {
            throw "JetKVM Desktop SHA-256 verification failed. Expected $($release.Sha256), received $actualHash."
        }
        if ($Log) { & $Log "[OK] JetKVM Desktop download SHA-256 verified." }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $stagingPath -Force
        $executable = Get-ChildItem -LiteralPath $stagingPath -Filter "jetkvm-desktop.exe" -File -Recurse | Select-Object -First 1
        if (-not $executable) {
            throw "The verified JetKVM Desktop archive did not contain jetkvm-desktop.exe."
        }
        $runtimeFiles = @(Add-JetKvmDesktopRuntimeDependencies -ExecutablePath $executable.FullName -Log $Log)
        Test-JetKvmDesktopLaunch -ExecutablePath $executable.FullName
        if ($Log) { & $Log "[OK] Web UI loader smoke test passed." }
        if (Test-Path -LiteralPath $state.Root) {
            Remove-Item -LiteralPath $state.Root -Recurse -Force -ErrorAction Stop
        }
        New-Item -ItemType Directory -Path $state.Root -Force | Out-Null
        $payloadRoot = $executable.Directory.FullName
        Copy-Item -Path (Join-Path $payloadRoot "*") -Destination $state.Root -Recurse -Force -ErrorAction Stop
        @'
MIT License

Copyright (c) 2026 Lars Karlslund

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'@ | Set-Content -LiteralPath (Join-Path $state.Root "LICENSE-jetkvm-desktop.txt") -Encoding UTF8
        $manifest = [ordered]@{
            version = $release.Version
            installedAt = (Get-Date).ToUniversalTime().ToString("o")
            repository = "https://github.com/lkarlslund/jetkvm-desktop"
            releaseUrl = $release.ReleaseUrl
            asset = $release.AssetName
            sha256 = $release.Sha256
            license = "LICENSE-jetkvm-desktop.txt"
            runtimeSource = if ($runtimeFiles.Count -gt 0) { "Local Git for Windows x64 runtime" } else { "Upstream release" }
            runtimeFiles = @($runtimeFiles)
        }
        $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $state.Root "jetfuel-install.json") -Encoding UTF8
        if (-not (Test-Path -LiteralPath (Join-Path $state.Root "jetkvm-desktop.exe"))) {
            throw "JetKVM Desktop installation did not produce the expected executable."
        }
        if ($Log) { & $Log "[OK] JetFUEL Web UI $($release.Version) installed with the upstream MIT notice." }
        return (Get-JetKvmDesktopState)
    } finally {
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-JetKvmDesktopClient {
    param(
        [scriptblock]$Log,
        [switch]$StopRunning
    )

    if ($StopRunning) {
        Stop-JetKvmDesktopClient -Log $Log
    } else {
        Assert-JetKvmDesktopNotRunning
    }
    $state = Get-JetKvmDesktopState
    if (-not (Test-Path -LiteralPath $state.Root)) {
        if ($Log) { & $Log "The JetFUEL-managed Web UI is not installed." }
        return
    }
    $toolsRoot = Join-Path $env:LOCALAPPDATA "JetFUEL\tools"
    if (-not (Test-PathInsideDirectory -Path $state.Root -Root $toolsRoot)) {
        throw "Refusing to remove the Web UI because its path is outside the JetFUEL tools directory."
    }
    Remove-Item -LiteralPath $state.Root -Recurse -Force -ErrorAction Stop
    if ($Log) { & $Log "[OK] JetFUEL-managed Web UI and its private runtime files removed." }
}

function Start-JetKvmDesktopClient {
    param([string]$JetKvmAddress)

    $state = Get-JetKvmDesktopState
    if (-not $state.Installed) {
        throw "The Web UI is not installed. Use Install Web UI on the Web UI tab first."
    }
    $runtime = Test-JetKvmDesktopRuntimeDependencies -ExecutablePath $state.Executable
    if (-not $runtime.Ready) {
        $problems = @($runtime.Missing) + @($runtime.Invalid | ForEach-Object { "$_ (invalid x64 runtime)" })
        throw "The managed Web UI cannot start because its private runtime is incomplete: $($problems -join ', '). Use Update / reinstall on the Web UI tab."
    }
    if (-not [string]::IsNullOrWhiteSpace($JetKvmAddress)) {
        Assert-ValidIpOrHost -Value $JetKvmAddress
        Start-Process -FilePath $state.Executable -ArgumentList @($JetKvmAddress.Trim()) -WorkingDirectory $state.Root | Out-Null
    } else {
        # Windows PowerShell 5.1 rejects -ArgumentList when the supplied array is empty.
        Start-Process -FilePath $state.Executable -WorkingDirectory $state.Root | Out-Null
    }
}

function Get-JetFuelWebView2InstallRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw "LOCALAPPDATA is not available, so JetFUEL cannot manage the embedded Web UI."
    }
    return (Join-Path $env:LOCALAPPDATA "JetFUEL\tools\webview2")
}

function Get-JetFuelWebView2State {
    $root = Get-JetFuelWebView2InstallRoot
    $manifestPath = Join-Path $root "jetfuel-install.json"
    $manifest = $null
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {}
    }
    $required = @(
        "Microsoft.Web.WebView2.Core.dll",
        "Microsoft.Web.WebView2.WinForms.dll",
        "WebView2Loader.dll"
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
    return [pscustomobject]@{
        Installed = ($missing.Count -eq 0)
        Root = $root
        ManifestPath = $manifestPath
        Version = if ($manifest -and $manifest.version) { [string]$manifest.version } else { $null }
        Missing = $missing
    }
}

function Import-JetFuelWebView2Support {
    $state = Get-JetFuelWebView2State
    if (-not $state.Installed) {
        $details = if ($state.Missing.Count -gt 0) { ": $($state.Missing -join ', ')" } else { "" }
        throw "The embedded Web UI support files are not installed$details. Use Install Web UI first."
    }

    if (-not ("Microsoft.Web.WebView2.WinForms.WebView2" -as [type])) {
        [void][JetFuel.DpiNative]::SetDllDirectory($state.Root)
        Add-Type -Path (Join-Path $state.Root "Microsoft.Web.WebView2.Core.dll") -ErrorAction Stop
        Add-Type -Path (Join-Path $state.Root "Microsoft.Web.WebView2.WinForms.dll") -ErrorAction Stop
    }
    return $state
}

function Get-JetFuelWebView2RuntimeVersion {
    [void](Import-JetFuelWebView2Support)
    try {
        return [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
    } catch {
        return $null
    }
}

function Install-JetFuelWebView2Runtime {
    param([scriptblock]$Log)

    $installerPath = Join-Path ([IO.Path]::GetTempPath()) ("JetFUEL-WebView2Setup-" + [Guid]::NewGuid().ToString("N") + ".exe")
    try {
        if ($Log) { & $Log "Microsoft Edge WebView2 Runtime is missing. Downloading Microsoft's Evergreen installer..." }
        Invoke-JetFuelResponsiveDownload -Uri "https://go.microsoft.com/fwlink/p/?LinkId=2124703" -Destination $installerPath
        $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
        if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
            -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Microsoft Corporation(,|$)') {
            throw "The downloaded WebView2 Runtime installer does not have a valid Microsoft Corporation signature."
        }
        if ($Log) { & $Log "[OK] Microsoft signature verified. Installing WebView2 Runtime..." }
        $process = Start-Process -FilePath $installerPath -ArgumentList @("/silent", "/install") -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Microsoft WebView2 Runtime installer failed with exit code $($process.ExitCode)."
        }
    } finally {
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-JetFuelWebView2Support {
    param([scriptblock]$Log)

    $version = "1.0.4078.44"
    $expectedSha256 = "DC4D1D9168DF26B830398303E50210B6E1729F6CE5A7AC69D2C766852F489962"
    $packageUri = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg"
    $state = Get-JetFuelWebView2State
    if ($state.Installed -and $state.Version -eq $version) {
        $runtimeVersion = Get-JetFuelWebView2RuntimeVersion
        if ([string]::IsNullOrWhiteSpace($runtimeVersion)) {
            Install-JetFuelWebView2Runtime -Log $Log
            $runtimeVersion = Get-JetFuelWebView2RuntimeVersion
        }
        if ([string]::IsNullOrWhiteSpace($runtimeVersion)) {
            throw "Microsoft Edge WebView2 Runtime is still unavailable after installation. Restart Windows and retry."
        }
        return [pscustomobject]@{ Version = $version; RuntimeVersion = $runtimeVersion; Root = $state.Root }
    }

    if ("Microsoft.Web.WebView2.WinForms.WebView2" -as [type]) {
        throw "The embedded Web UI support is already loaded. Close and reopen JetFUEL before reinstalling it."
    }

    $workRoot = Join-Path ([IO.Path]::GetTempPath()) ("JetFUEL-webview2-" + [Guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path $workRoot "webview2.zip"
    $extractPath = Join-Path $workRoot "package"
    $stagingPath = Join-Path $workRoot "staging"
    try {
        New-Item -ItemType Directory -Path $extractPath, $stagingPath -Force | Out-Null
        if ($Log) { & $Log "Downloading pinned Microsoft WebView2 SDK $version..." }
        Invoke-JetFuelResponsiveDownload -Uri $packageUri -Destination $archivePath
        $actualHash = Get-JetFuelFileSha256 -Path $archivePath
        if ($actualHash -ne $expectedSha256) {
            throw "WebView2 SDK SHA-256 verification failed. Expected $expectedSha256, received $actualHash."
        }
        if ($Log) { & $Log "[OK] WebView2 SDK package SHA-256 verified." }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force

        $payload = [ordered]@{
            "Microsoft.Web.WebView2.Core.dll" = "lib\net462\Microsoft.Web.WebView2.Core.dll"
            "Microsoft.Web.WebView2.WinForms.dll" = "lib\net462\Microsoft.Web.WebView2.WinForms.dll"
            "WebView2Loader.dll" = "runtimes\win-x64\native\WebView2Loader.dll"
            "LICENSE-WebView2.txt" = "LICENSE.txt"
        }
        foreach ($entry in $payload.GetEnumerator()) {
            $source = Join-Path $extractPath $entry.Value
            if (-not (Test-Path -LiteralPath $source)) {
                throw "The verified WebView2 package is missing $($entry.Value)."
            }
            Copy-Item -LiteralPath $source -Destination (Join-Path $stagingPath $entry.Key) -Force
        }
        [ordered]@{
            version = $version
            installedAt = (Get-Date).ToUniversalTime().ToString("o")
            package = "Microsoft.Web.WebView2"
            packageUri = $packageUri
            sha256 = $expectedSha256
            license = "LICENSE-WebView2.txt"
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stagingPath "jetfuel-install.json") -Encoding UTF8

        # Remove the retired external client while migrating to the embedded UI.
        Remove-JetKvmDesktopClient -Log $Log -StopRunning
        if (Test-Path -LiteralPath $state.Root) {
            Remove-Item -LiteralPath $state.Root -Recurse -Force -ErrorAction Stop
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $state.Root) -Force | Out-Null
        Move-Item -LiteralPath $stagingPath -Destination $state.Root -Force

        $runtimeVersion = Get-JetFuelWebView2RuntimeVersion
        if ([string]::IsNullOrWhiteSpace($runtimeVersion)) {
            Install-JetFuelWebView2Runtime -Log $Log
            $runtimeVersion = Get-JetFuelWebView2RuntimeVersion
        }
        if ([string]::IsNullOrWhiteSpace($runtimeVersion)) {
            throw "Microsoft Edge WebView2 Runtime is unavailable. Restart Windows and retry the Web UI installation."
        }
        if ($Log) { & $Log "[OK] Embedded Web UI support $version installed; Edge runtime $runtimeVersion detected." }
        return [pscustomobject]@{ Version = $version; RuntimeVersion = $runtimeVersion; Root = $state.Root }
    } finally {
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-JetFuelWebView2Support {
    param([scriptblock]$Log)

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return }
    $paths = @(
        (Get-JetFuelWebView2InstallRoot),
        (Join-Path $env:LOCALAPPDATA "JetFUEL\webview2-user-data")
    )
    $toolsRoot = Join-Path $env:LOCALAPPDATA "JetFUEL"
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if (-not (Test-PathInsideDirectory -Path $path -Root $toolsRoot)) {
            throw "Refusing to remove embedded Web UI files outside the JetFUEL directory."
        }
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            Write-JetFuelCleanupLog -Log $Log -Message "Removed embedded Web UI files: $path"
        } catch {
            Start-JetFuelDelayedDirectoryRemoval -Path $path
            Write-JetFuelCleanupLog -Log $Log -Message "Queued embedded Web UI file removal after exit: $path"
        }
    }
}

function Get-JetKvmWebUri {
    param([Parameter(Mandatory)][string]$Address)

    $trimmed = $Address.Trim()
    Assert-ValidIpOrHost -Value ($trimmed -replace '^https?://', '')
    if ($trimmed -notmatch '^https?://') { $trimmed = "http://$trimmed" }
    $uri = $null
    if (-not [Uri]::TryCreate($trimmed, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @("http", "https")) {
        throw "Enter a valid JetKVM HTTP or HTTPS address."
    }
    return $uri
}

function ConvertTo-BashPath {
    param(
        [Parameter(Mandatory)][string]$BashPath,
        [Parameter(Mandatory)][string]$WindowsPath,
        [Parameter(Mandatory)][ValidateSet("Git", "WSL")][string]$BashKind
    )

    if ($BashKind -eq "Git" -and -not (Test-IsGitForWindowsBash -BashPath $BashPath)) {
        throw "The selected bash is not Git for Windows bash. Found '$BashPath'. Install Git for Windows or remove WSL bash from earlier in PATH for this wizard."
    }
    if ($BashKind -eq "WSL" -and -not (Test-IsWslBash -BashPath $BashPath)) {
        throw "The selected bash is not WSL bash. Found '$BashPath'."
    }

    $escaped = $WindowsPath.Replace("\", "\\").Replace("'", "'\''")
    $converter = if ($BashKind -eq "Git") { "cygpath -u" } else { "wslpath -a -u" }
    $converted = & $BashPath -lc "$converter '$escaped'"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($converted)) {
        throw "Could not convert Windows path for $BashKind bash: $WindowsPath"
    }
    return $converted.Trim()
}

function Assert-ValidIpOrHost {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Enter the JetKVM IP address or hostname first, then run preflight."
    }
    if ($Value -notmatch '^[a-zA-Z0-9][a-zA-Z0-9\.\-:]*$') {
        throw "The JetKVM IP/hostname contains invalid characters. Example: 192.168.50.9 or jetkvm.local"
    }
}

function New-SshKeyPair {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [AllowEmptyString()][string]$Passphrase = "",
        [scriptblock]$Log
    )

    $sshKeygen = Get-CommandPath -Name "ssh-keygen.exe"
    if (-not $sshKeygen) { $sshKeygen = Get-CommandPath -Name "ssh-keygen" }
    if (-not $sshKeygen) { throw "ssh-keygen was not found. Install the Windows OpenSSH Client optional feature or Git for Windows." }

    $parent = Split-Path -Parent $KeyPath
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    if ((Test-Path -LiteralPath $KeyPath) -or (Test-Path -LiteralPath "$KeyPath.pub")) {
        throw "SSH key already exists at $KeyPath. Choose a different path or use the existing key."
    }

    & $Log "Generating RSA 4096-bit SSH key: $KeyPath"
    $sshPassphraseArg = if ([string]::IsNullOrEmpty($Passphrase)) { '""' } else { $Passphrase }
    $output = & $sshKeygen -t rsa -b 4096 -f $KeyPath -N $sshPassphraseArg 2>&1
    if ($output) { $output | ForEach-Object { & $Log ([string]$_) } }
    if ($LASTEXITCODE -ne 0) {
        throw "ssh-keygen failed. Check the key path is writable and that no key already exists at this location."
    }
}

function Get-PublicKeyText {
    param([Parameter(Mandatory)][string]$KeyPath)

    $pub = if ($KeyPath.EndsWith(".pub", [StringComparison]::OrdinalIgnoreCase)) { $KeyPath } else { "$KeyPath.pub" }
    if (-not (Test-Path -LiteralPath $pub)) { throw "Public key was not found: $pub" }
    return (Get-Content -LiteralPath $pub -Raw).Trim()
}

function Get-JetKvmTailscaleInitScript {
    return @'
#!/bin/sh
# /userdata/init.d/S22tailscale
# JetFUEL robust Tailscale startup for JetKVM.

LOG=/tmp/tailscale-init.log
TS_DIR=/userdata/tailscale
TS_DAEMON=$TS_DIR/tailscaled
TS_CLI=$TS_DIR/tailscale
SOCK=/var/run/tailscale/tailscaled.sock
WATCHDOG_PID=/var/run/tailscale/jetfuel-watchdog.pid

log() {
  echo "$(date): $*" >> "$LOG"
}

is_running() {
  ps | grep '[t]ailscaled' >/dev/null 2>&1
}

wait_for_network() {
  i=1
  while [ "$i" -le 20 ]; do
    ip route | grep default >/dev/null 2>&1 && return 0
    log "waiting for default route ($i/20)"
    sleep 1
    i=$((i + 1))
  done
  log "default route was not ready after 20 seconds"
  return 1
}

prepare_tun() {
  mkdir -p /var/run/tailscale /dev/net
  modprobe tun >> "$LOG" 2>&1 || true
  if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200 >> "$LOG" 2>&1 || true
  fi
}

start_daemon() {
  prepare_tun
  wait_for_network || true
  if is_running; then
    log "tailscaled already running"
    return 0
  fi
  if [ ! -x "$TS_DAEMON" ]; then
    log "missing or non-executable $TS_DAEMON"
    return 1
  fi
  log "starting tailscaled"
  "$TS_DAEMON" >> "$LOG" 2>&1 &
}

wait_for_socket() {
  i=1
  while [ "$i" -le 30 ]; do
    [ -S "$SOCK" ] && return 0
    if ! is_running; then
      log "tailscaled exited while waiting for socket"
      return 1
    fi
    sleep 1
    i=$((i + 1))
  done
  log "tailscaled socket did not become ready after 30 seconds"
  return 1
}

watchdog_running() {
  if [ -f "$WATCHDOG_PID" ]; then
    pid="$(cat "$WATCHDOG_PID" 2>/dev/null || true)"
    if [ -n "$pid" ] && ps | grep -q "^[[:space:]]*$pid[[:space:]]"; then
      return 0
    fi
  fi
  return 1
}

daemon_responding() {
  [ -x "$TS_CLI" ] || return 0
  command -v timeout >/dev/null 2>&1 || return 0

  timeout 12 "$TS_CLI" status >/dev/null 2>&1
  result=$?
  case "$result" in
    124|137|143) return 1 ;;
    *) return 0 ;;
  esac
}

start_watchdog() {
  if watchdog_running; then
    log "watchdog already running"
    return 0
  fi
  (
    log "watchdog started"
    health_failures=0
    while true; do
      sleep 60
      if ! is_running; then
        log "watchdog: tailscaled is not running; restarting"
        start_daemon || true
        wait_for_socket || true
        health_failures=0
        continue
      fi
      if [ ! -S "$SOCK" ]; then
        log "watchdog: tailscaled socket missing; restarting daemon"
        killall tailscaled >> "$LOG" 2>&1 || true
        sleep 2
        start_daemon || true
        wait_for_socket || true
        health_failures=0
        continue
      fi
      if daemon_responding; then
        health_failures=0
      else
        health_failures=$((health_failures + 1))
        log "watchdog: tailscaled health probe timed out ($health_failures/3)"
        if [ "$health_failures" -ge 3 ]; then
          log "watchdog: tailscaled is unresponsive; restarting daemon"
          killall tailscaled >> "$LOG" 2>&1 || true
          sleep 2
          start_daemon || true
          wait_for_socket || true
          health_failures=0
        fi
      fi
    done
  ) &
  echo $! > "$WATCHDOG_PID"
}

stop_watchdog() {
  if [ -f "$WATCHDOG_PID" ]; then
    pid="$(cat "$WATCHDOG_PID" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      kill "$pid" >> "$LOG" 2>&1 || true
    fi
    rm -f "$WATCHDOG_PID"
  fi
}

case "$1" in
  start)
    start_daemon || exit 1
    start_watchdog
    wait_for_socket
    ;;
  stop)
    stop_watchdog
    killall tailscaled >> "$LOG" 2>&1 || true
    ;;
  restart)
    stop_watchdog
    killall tailscaled >> "$LOG" 2>&1 || true
    sleep 1
    "$0" start
    ;;
  reload-watchdog)
    stop_watchdog
    start_watchdog
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|reload-watchdog}"
    exit 1
    ;;
esac
'@
}

function Get-JetKvmTailscaleInitInstallBlock {
    $script = Get-JetKvmTailscaleInitScript
    return @"
cat > /userdata/init.d/S22tailscale <<'JETFUEL_TAILSCALE_INIT'
$script
JETFUEL_TAILSCALE_INIT
chmod +x /userdata/init.d/S22tailscale
"@
}

function Get-JetKvmTailscaleRemoteStartBlock {
    return @'
echo "       Ensuring tailscaled is running..."
if [ -x /userdata/init.d/S22tailscale ]; then
  /userdata/init.d/S22tailscale start 2>&1 || true
elif [ -x /userdata/tailscale/tailscaled ]; then
  mkdir -p /var/run/tailscale /dev/net
  modprobe tun 2>/dev/null || true
  [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null || true
  /userdata/tailscale/tailscaled >/tmp/tailscaled.log 2>&1 &
else
  echo "ERROR: /userdata/tailscale/tailscaled is missing or not executable"
  exit 1
fi

i=1
while [ "$i" -le 35 ]; do
  if [ -S /var/run/tailscale/tailscaled.sock ]; then
    echo "       tailscaled socket is ready"
    exit 0
  fi
  if ! ps | grep '[t]ailscaled' >/dev/null 2>&1; then
    echo "ERROR: tailscaled exited while starting"
    cat /tmp/tailscale-init.log 2>/dev/null || true
    cat /tmp/tailscaled.log 2>/dev/null || true
    exit 1
  fi
  sleep 1
  i=$((i + 1))
done

echo "ERROR: tailscaled did not become ready within 35 seconds"
ps | grep tailscale | grep -v grep 2>&1 || true
cat /tmp/tailscale-init.log 2>/dev/null || true
cat /tmp/tailscaled.log 2>/dev/null || true
exit 1
'@
}

function Download-PatchedJetKvmTailscaleInstaller {
    param(
        [Parameter(Mandatory)][ValidateSet("Git", "WSL")][string]$BashKind,
        [Parameter(Mandatory)][string]$KeyBashPath,
        [ValidateSet("Official JetKVM", "JetFUEL repo", "Custom URL", "Local file")][string]$InstallerSourceKind = "Official JetKVM",
        [AllowEmptyString()][string]$InstallerSourcePath = "",
        [scriptblock]$Log
    )

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("JetFUEL-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $scriptPath = Join-Path $tempDir "install-tailscale.sh"

    switch ($InstallerSourceKind) {
        "Official JetKVM" {
            & $Log "Downloading official JetKVM Tailscale installer..."
            Invoke-WebRequest -UseBasicParsing -Uri "https://jetkvm.com/install-tailscale.sh" -OutFile $scriptPath
        }
        "JetFUEL repo" {
            $repoScript = Join-Path (Get-JetFuelScriptRoot) "install-tailscale.sh"
            if (-not (Test-Path -LiteralPath $repoScript)) {
                throw "JetFUEL repo installer was selected, but install-tailscale.sh was not found next to JetFuel.ps1."
            }
            & $Log "Using JetFUEL repo reference copy of JetKVM installer: $repoScript"
            Copy-Item -LiteralPath $repoScript -Destination $scriptPath -Force
        }
        "Custom URL" {
            if ([string]::IsNullOrWhiteSpace($InstallerSourcePath)) {
                throw "Custom installer URL is empty. Add it in Settings or choose Official JetKVM."
            }
            if ($InstallerSourcePath -notmatch '^https?://') {
                throw "Custom installer URL must start with http:// or https://."
            }
            & $Log "Downloading custom Tailscale installer: $InstallerSourcePath"
            Invoke-WebRequest -UseBasicParsing -Uri $InstallerSourcePath -OutFile $scriptPath
        }
        "Local file" {
            if ([string]::IsNullOrWhiteSpace($InstallerSourcePath)) {
                throw "Local installer file is empty. Add it in Settings or choose Official JetKVM."
            }
            if (-not (Test-Path -LiteralPath $InstallerSourcePath)) {
                throw "Local installer file was not found: $InstallerSourcePath"
            }
            & $Log "Using local Tailscale installer: $InstallerSourcePath"
            Copy-Item -LiteralPath $InstallerSourcePath -Destination $scriptPath -Force
        }
    }

    $content = Get-Content -LiteralPath $scriptPath -Raw
    if ($BashKind -eq "Git") {
        $content = $content.Replace('ping -c 3 -W 5 "$JETKVM_IP"', 'ping -n 3 -w 5000 "$JETKVM_IP"')
        & $Log "Applied Git Bash compatibility patch to installer ping check."
    } else {
        & $Log "Using unmodified installer ping check for WSL bash."
    }
    $initInstallBlock = Get-JetKvmTailscaleInitInstallBlock
    $configureNeedle = "  ./tailscale configure jetkvm 2>&1 >/dev/null"
    if ($content.Contains($configureNeedle) -and $content -notmatch "JetFUEL robust Tailscale startup") {
        $content = $content.Replace(
            $configureNeedle,
            "$configureNeedle`n`n  echo `"       Installing robust JetFUEL Tailscale boot hook...`"`n$initInstallBlock"
        )
        & $Log "Applied robust JetKVM Tailscale boot-hook patch."
    } elseif ($content -match "JetFUEL robust Tailscale startup") {
        & $Log "Installer already contains the JetFUEL robust boot-hook patch."
    } else {
        & $Log "Warning: could not locate tailscale configure step to patch boot hook. Install may still need Repair Tailscale afterwards."
    }

    $startNeedle = @'
	echo "[7/7] Starting Tailscale service..."
	ssh root@"$JETKVM_IP" "tailscale up $TAILSCALE_UP_ARGS"
'@
    if ($content.Contains($startNeedle)) {
        $remoteStartBlock = (Get-JetKvmTailscaleRemoteStartBlock) -split "`r?`n"
        $indentedRemoteStartBlock = (($remoteStartBlock | ForEach-Object { $_ }) -join "`n")
        $startReplacement = @"
	echo "[7/7] Starting Tailscale service..."
	ssh root@"`$JETKVM_IP" 'sh -s' <<'JETFUEL_START_TAILSCALE'
$indentedRemoteStartBlock
JETFUEL_START_TAILSCALE
	ssh root@"`$JETKVM_IP" "tailscale up `$TAILSCALE_UP_ARGS"
"@
        $content = $content.Replace($startNeedle, $startReplacement)
        & $Log "Applied tailscaled start/readiness patch to installer."
    } elseif ($content -match "JETFUEL_START_TAILSCALE") {
        & $Log "Installer already contains the JetFUEL tailscaled start/readiness patch."
    } else {
        & $Log "Warning: could not locate installer start step to patch tailscaled readiness."
    }
    $content = $content.Replace('SSH_TEST_OUTPUT=$(ssh ', 'SSH_TEST_OUTPUT=$(ssh $JETFUEL_SSH_OPTS ')
    $content = $content.Replace("`tssh root@", "`tssh `$JETFUEL_SSH_OPTS root@")
    $content = $content.Replace("`tssh -o ServerAliveInterval", "`tssh `$JETFUEL_SSH_OPTS -o ServerAliveInterval")
    $content = $content.Replace("`t`tif ssh -q ", "`t`tif ssh `$JETFUEL_SSH_OPTS -q ")
    $content = $content.Replace("`tssh root@`"`$JETKVM_IP`"", "`tssh `$JETFUEL_SSH_OPTS root@`"`$JETKVM_IP`"")
    & $Log "Patched installer SSH calls to use the selected wizard key."
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($scriptPath, $content, $utf8NoBom)

    return $scriptPath
}

function Invoke-JetKvmTailscaleInstall {
    param(
        [Parameter(Mandatory)][string]$BashPath,
        [ValidateSet("Git", "WSL")][string]$BashKind,
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [string]$KeyPath,
        [Parameter(Mandatory)][string]$TailscaleVersion,
        [string]$AuthKey,
        [string]$Hostname,
        [switch]$CleanInstall,
        [ValidateSet("Official JetKVM", "JetFUEL repo", "Custom URL", "Local file")][string]$InstallerSourceKind = "Official JetKVM",
        [AllowEmptyString()][string]$InstallerSourcePath = "",
        [scriptblock]$Log,
        [scriptblock]$LoginUrlHandler
    )

    Assert-ValidIpOrHost -Value $JetKvmAddress
    $Hostname = ConvertTo-TailscaleHostname -Value $Hostname
    Assert-TailscaleHostname -Value $Hostname
    if ([string]::IsNullOrWhiteSpace($BashKind)) {
        if (Test-IsGitForWindowsBash -BashPath $BashPath) { $BashKind = "Git" }
        elseif (Test-IsWslBash -BashPath $BashPath) { $BashKind = "WSL" }
        else { throw "Could not identify bash type. Use Git Bash or WSL bash." }
    }
    if ([string]::IsNullOrWhiteSpace($KeyPath)) {
        throw "Internal error: SSH key path was not supplied to the installer step. Run preflight again and retry."
    }

    $keyBashPath = ConvertTo-BashPath -BashPath $BashPath -WindowsPath $KeyPath -BashKind $BashKind
    $sshOpts = "-i $keyBashPath -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o IgnoreUnknown=WarnWeakCrypto -o WarnWeakCrypto=no-pq-kex"
    $sshProbeCommand = "ssh $sshOpts -o ConnectTimeout=5 root@$JetKvmAddress 'echo JETFUEL_SSH_OK'"
    & $Log "Checking SSH from $BashKind bash with the selected key..."
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $sshProbeOutput = & $BashPath -lc $sshProbeCommand 2>&1
        $sshProbeExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    $sshProbeText = (($sshProbeOutput | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($sshProbeExit -ne 0 -or $sshProbeText -notmatch "JETFUEL_SSH_OK") {
        if ([string]::IsNullOrWhiteSpace($sshProbeText)) { $sshProbeText = "No SSH error details returned." }
        throw "$BashKind bash could not SSH to the JetKVM with the selected key. Details: $sshProbeText"
    }
    & $Log "$BashKind bash SSH check confirmed."

    $installer = Download-PatchedJetKvmTailscaleInstaller -BashKind $BashKind -KeyBashPath $keyBashPath -InstallerSourceKind $InstallerSourceKind -InstallerSourcePath $InstallerSourcePath -Log $Log
    $installerBashPath = ConvertTo-BashPath -BashPath $BashPath -WindowsPath $installer -BashKind $BashKind

    $tempHome = Join-Path ([IO.Path]::GetTempPath()) ("JetFUEL-home-" + [Guid]::NewGuid().ToString("N"))
    $sshDir = Join-Path $tempHome ".ssh"
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    $sshConfig = @"
Host $JetKvmAddress
    HostName $JetKvmAddress
    User root
    IdentityFile $keyBashPath
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    IgnoreUnknown WarnWeakCrypto
    WarnWeakCrypto no-pq-kex
"@
    $sshConfigPath = Join-Path $sshDir "config"
    [IO.File]::WriteAllText($sshConfigPath, $sshConfig, [Text.UTF8Encoding]::new($false))
    $homeBashPath = ConvertTo-BashPath -BashPath $BashPath -WindowsPath $tempHome -BashKind $BashKind
    & $Log "Prepared temporary SSH config for installer ($BashKind bash)."

    $tailscaleUpArgs = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($AuthKey)) { $tailscaleUpArgs.Add("--authkey=$AuthKey") }
    if (-not [string]::IsNullOrWhiteSpace($Hostname)) { $tailscaleUpArgs.Add("--hostname=$Hostname") }

    $installArgs = New-Object System.Collections.Generic.List[string]
    $installArgs.Add($installerBashPath)
    $installArgs.Add("-v")
    $installArgs.Add($TailscaleVersion)
    $installArgs.Add("-y")
    if ($CleanInstall) { $installArgs.Add("-c") }
    $installArgs.Add($JetKvmAddress)
    if ($tailscaleUpArgs.Count -gt 0) {
        $installArgs.Add("--")
        foreach ($arg in $tailscaleUpArgs) { $installArgs.Add($arg) }
    }

    $quoteForBash = {
        param([string]$Value)
        return "'" + $Value.Replace("'", "'\''") + "'"
    }
    $quotedArgs = ($installArgs | ForEach-Object { & $quoteForBash $_ }) -join " "
    $bashCommand = "export HOME=$(& $quoteForBash $homeBashPath); export JETFUEL_SSH_OPTS=$(& $quoteForBash $sshOpts); $quotedArgs"

    & $Log "Starting JetKVM Tailscale install with $BashKind bash. The device will reboot during this step."
    $installerOutput = New-Object System.Collections.Generic.List[string]
    $loginUrlOpened = $false
    $installerExitCode = 1
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $BashPath -lc $bashCommand 2>&1 | ForEach-Object {
            $line = [string]$_
            $installerOutput.Add($line) | Out-Null
            & $Log $line
            if (-not $loginUrlOpened -and [string]::IsNullOrWhiteSpace($AuthKey)) {
                $url = Get-TailscaleLoginUrlFromText -Text $line
                if ($url) {
                    $loginUrlOpened = $true
                    if ($LoginUrlHandler) {
                        & $LoginUrlHandler $url
                    } else {
                        Start-Process $url
                    }
                }
            }
        }
        $installerExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    if ($installerExitCode -ne 0) {
        $installerText = ($installerOutput -join "`n")
        if (-not $loginUrlOpened -and [string]::IsNullOrWhiteSpace($AuthKey)) {
            $url = Get-TailscaleLoginUrlFromText -Text $installerText
            if ($url) {
                $loginUrlOpened = $true
                if ($LoginUrlHandler) { & $LoginUrlHandler $url } else { Start-Process $url }
            }
        }
        if ($loginUrlOpened) {
            throw "Tailscale needs browser login. Complete the login page, then click Check Tailscale."
        }
        if ($installerText -match 'invalid key|unable to validate API key|API key .*not valid|API key does not exist') {
            throw "Tailscale rejected the auth key. Create a new pre-authentication key in the Tailscale admin console, make sure it starts with tskey-auth-, check that it has not expired or already been used, then paste the full key and retry. You can also untick the auth key box and log in manually after install."
        }
        throw "JetKVM Tailscale installer failed with exit code $installerExitCode."
    }
}

function Open-JetKvmUi {
    param([string]$JetKvmAddress)
    if ([string]::IsNullOrWhiteSpace($JetKvmAddress)) { return }
    Assert-ValidIpOrHost -Value $JetKvmAddress
    Start-Process "http://$JetKvmAddress"
}

function Test-JetKvmWebUi {
    param([Parameter(Mandatory)][string]$JetKvmAddress)
    $client = $null
    try {
        $client = [Net.Sockets.TcpClient]::new()
        $async = $client.BeginConnect($JetKvmAddress, 80, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(3000, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) { $client.Close() }
    }
}

function Test-JetKvmSshLogin {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath
    )

    $ssh = Get-CommandPath -Name "ssh.exe"
    if (-not $ssh) { $ssh = Get-CommandPath -Name "ssh" }
    if (-not $ssh) { return @{ Ok = $false; Message = "SSH client not found" } }
    if (-not (Test-Path -LiteralPath $KeyPath)) { return @{ Ok = $false; Message = "Private key not found yet" } }

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $ssh -i $KeyPath -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o IgnoreUnknown=WarnWeakCrypto -o WarnWeakCrypto=no-pq-kex root@$JetKvmAddress "echo SSH_OK" 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    $text = (($output | ForEach-Object { [string]$_ }) -join " ").Trim()
    if ($exitCode -eq 0 -and $text -match "SSH_OK") {
        $cleanText = ($text -replace "Warning: Permanently added '[^']+' \([^)]+\) to the list of known hosts\.", "").Trim()
        if ([string]::IsNullOrWhiteSpace($cleanText)) { $cleanText = "SSH login confirmed" }
        return @{ Ok = $true; Message = $cleanText }
    }

    if ([string]::IsNullOrWhiteSpace($text)) { $text = "SSH login failed" }
    return @{ Ok = $false; Message = $text }
}

function Invoke-JetKvmSshCommand {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSeconds = 60
    )

    $ssh = Get-CommandPath -Name "ssh.exe"
    if (-not $ssh) { $ssh = Get-CommandPath -Name "ssh" }
    if (-not $ssh) { throw "OpenSSH client was not found. Enable Windows OpenSSH Client and try again." }
    if (-not (Test-Path -LiteralPath $KeyPath)) { throw "Private key not found: $KeyPath" }

    $sshArgs = @(
        "-i", $KeyPath,
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "IdentitiesOnly=yes",
        "-o", "IgnoreUnknown=WarnWeakCrypto",
        "-o", "WarnWeakCrypto=no-pq-kex",
        "root@$JetKvmAddress",
        $Command
    )

    $job = Start-Job -ScriptBlock {
        param($SshPath, $ArgsForSsh)
        & $SshPath @ArgsForSsh 2>&1 | ForEach-Object { [string]$_ }
        "__JETFUEL_EXIT_CODE:$LASTEXITCODE"
    } -ArgumentList $ssh, $sshArgs

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($job.State -in @("NotStarted", "Running") -and [DateTime]::UtcNow -lt $deadline) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }

    if ($job.State -in @("NotStarted", "Running")) {
        $partial = Receive-Job -Job $job -ErrorAction SilentlyContinue
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return @{
            ExitCode = 124
            TimedOut = $true
            Output = (($partial | ForEach-Object { [string]$_ }) -join "`n").Trim()
        }
    }

    $received = Receive-Job -Job $job
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

    $exitCode = 0
    $output = New-Object System.Collections.Generic.List[string]
    foreach ($line in $received) {
        $text = [string]$line
        if ($text -match '^__JETFUEL_EXIT_CODE:(-?\d+)$') {
            $exitCode = [int]$Matches[1]
        } else {
            $output.Add($text)
        }
    }

    return @{
        ExitCode = $exitCode
        TimedOut = $false
        Output = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    }
}

function ConvertTo-ShellSingleQuoted {
    param([AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function ConvertTo-JetKvmEncodedShellCommand {
    param([Parameter(Mandatory)][string]$Script)

    $normalized = $Script.Replace("`r`n", "`n").Replace("`r", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
    return "if command -v base64 >/dev/null 2>&1; then echo $encoded | base64 -d | sh; else echo '[FAIL] base64 applet is unavailable'; exit 127; fi"
}

function Remove-AnsiEscapeSequences {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return [regex]::Replace($Text, "$([char]27)\[[0-?]*[ -/]*[@-~]", "")
}

function Get-JetKvmQuickDiagnosticsCommand {
    return @'
section() {
  printf '\n=== %s ===\n' "$1"
}

run_with_timeout() {
  seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

section "VERSION"
if command -v wget >/dev/null 2>&1; then
  wget -qO- http://127.0.0.1/metrics 2>/dev/null | grep '^jetkvm_build_info' || true
fi
printf 'System version: '
cat /version 2>/dev/null || echo unknown
printf 'Hardware SKU: '
cat /etc/jetkvm-sku 2>/dev/null || echo jetkvm-v2
uname -a 2>/dev/null || true

section "UPTIME AND LOAD"
uptime 2>&1 || true
cat /proc/loadavg 2>/dev/null || true

section "MEMORY"
if command -v free >/dev/null 2>&1; then
  free -m 2>&1 || true
else
  sed -n '1,12p' /proc/meminfo 2>/dev/null || true
fi

section "D-STATE PROCESSES"
dstate_found=0
for p in /proc/[0-9]*; do
  state="$(awk '/^State:/{print $2}' "$p/status" 2>/dev/null)"
  if [ "$state" = "D" ]; then
    printf '%-7s %-24s %s\n' "${p##*/}" "$(cat "$p/comm" 2>/dev/null)" "$state"
    dstate_found=1
  fi
done
if [ "$dstate_found" -eq 0 ]; then echo '[OK] no D-state processes found'; fi

section "IMPORTANT PROCESSES"
ps 2>&1 | grep -E 'jetkvm|tailscale|venc|vpss|vps|rga|valloc|sys|vlog' | grep -v grep || true

section "NETWORK"
if command -v ip >/dev/null 2>&1; then
  ip addr 2>&1 || true
  ip route 2>&1 || true
else
  ifconfig 2>&1 || true
  route -n 2>&1 || true
fi
cat /etc/resolv.conf 2>/dev/null || true

section "STORAGE"
df -h 2>&1 || true

section "TAILSCALE"
if command -v tailscale >/dev/null 2>&1; then
  run_with_timeout 8 tailscale status 2>&1 || echo '[WARN] tailscale status did not complete within 8 seconds'
  run_with_timeout 8 tailscale ip -4 2>&1 || echo '[WARN] tailscale ip did not complete within 8 seconds'
  run_with_timeout 8 tailscale version 2>&1 || echo '[WARN] tailscale version did not complete within 8 seconds'
else
  echo '[INFO] tailscale command is not installed'
fi

section "TAILSCALE PERSISTENCE"
if [ -f /userdata/init.d/S22tailscale ]; then
  echo '[OK] boot hook exists'
  if grep -q 'watchdog' /userdata/init.d/S22tailscale; then echo '[OK] watchdog configured'; else echo '[WARN] watchdog not configured'; fi
else
  echo '[WARN] boot hook is missing'
fi
if [ -f /var/run/tailscale/jetfuel-watchdog.pid ]; then
  watchdog_pid="$(cat /var/run/tailscale/jetfuel-watchdog.pid 2>/dev/null || true)"
  if [ -n "$watchdog_pid" ] && ps | grep -q "^[[:space:]]*$watchdog_pid[[:space:]]"; then
    echo "[OK] watchdog process running PID $watchdog_pid"
  else
    echo '[WARN] watchdog PID file exists but process was not found'
  fi
else
  echo '[WARN] watchdog PID file is missing'
fi
tail -n 40 /tmp/tailscale-init.log 2>/dev/null || true

section "RECENT KERNEL MESSAGES"
dmesg 2>&1 | tail -n 80 || true

echo
echo '[OK] quick diagnostics complete'
'@
}

function Get-JetKvmFullDiagnosticsCommand {
    $quick = Get-JetKvmQuickDiagnosticsCommand
    $detail = @'

section "ALL PROCESSES"
ps 2>&1 || true

section "JETKVM APPLICATION LOG"
if [ -f /userdata/jetkvm/last.log ]; then
  tail -n 600 /userdata/jetkvm/last.log 2>&1 || true
else
  echo '[WARN] /userdata/jetkvm/last.log was not found'
fi

section "JETKVM CRASH DUMPS"
if [ -d /userdata/jetkvm/crashdump ]; then
  ls -lah /userdata/jetkvm/crashdump 2>&1 || true
  for crash_file in /userdata/jetkvm/crashdump/*.log; do
    [ -f $crash_file ] || continue
    echo '--- crash log, last 250 lines ---'
    echo $crash_file
    tail -n 250 $crash_file 2>&1 || true
  done
else
  echo '[OK] no crashdump directory exists'
fi

section "VIDEO AND USB STATE"
for state_file in /sys/class/drm/*/status; do
  [ -f "$state_file" ] || continue
  printf '%s: ' "$state_file"
  cat "$state_file" 2>/dev/null || true
done
cat /proc/bus/input/devices 2>/dev/null || true
if command -v lsusb >/dev/null 2>&1; then lsusb 2>&1 || true; fi

section "THERMAL STATE"
for thermal_file in /sys/class/thermal/thermal_zone*/temp; do
  [ -f "$thermal_file" ] || continue
  printf '%s: ' "$thermal_file"
  cat "$thermal_file" 2>/dev/null || true
done

section "PERSISTENT FILE INVENTORY"
ls -lah /userdata/jetkvm 2>&1 || true
ls -lah /userdata/init.d 2>&1 || true
ls -lah /userdata/tailscale 2>&1 || true

section "FULL KERNEL LOG"
dmesg 2>&1 || true

echo
echo '[OK] full diagnostic report complete'
'@
    return ($quick + $detail)
}

function Get-JetKvmCrashLogsCommand {
    return @'
echo '--- JetKVM crash files ---'
if [ -d /userdata/jetkvm/crashdump ]; then
  ls -lah /userdata/jetkvm/crashdump 2>&1 || true
  found=0
  for crash_file in /userdata/jetkvm/crashdump/*.log /userdata/jetkvm/crashdump/*.txt; do
    [ -f $crash_file ] || continue
    found=1
    echo '--- crash log, last 250 lines ---'
    echo $crash_file
    tail -n 250 $crash_file 2>&1 || true
  done
  if [ $found -eq 0 ]; then echo '[INFO] no text crash logs found'; fi
else
  echo '[OK] no crashdump directory exists'
fi
'@
}

function Get-JetKvmInventory {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath
    )

    $script = @'
clean_value() {
  printf '%s' "$1" | tr '\r\n' '  ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

serial="$(awk -F: '/^Serial[[:space:]]*:/{gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
sku="$(cat /etc/jetkvm-sku 2>/dev/null)"
[ -n "$sku" ] || sku='jetkvm-v2'
system_version="$(cat /version 2>/dev/null)"
app_version=''
if command -v wget >/dev/null 2>&1; then
  app_version="$(wget -qO- http://127.0.0.1/metrics 2>/dev/null | sed -n 's/^jetkvm_build_info{.*version="\([^"]*\)".*/\1/p' | head -n 1)"
fi
mac="$(cat /sys/class/net/eth0/address 2>/dev/null)"
hostname_value="$(hostname 2>/dev/null)"

cloud_state='Not configured'
if [ -r /userdata/kvm_config.json ] && grep -Eq '"cloud_token"[[:space:]]*:[[:space:]]*"[^"]+"' /userdata/kvm_config.json; then
  cloud_state='Configured'
fi

tailscale_name=''
if command -v tailscale >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  tailscale_name="$(timeout 8 tailscale debug prefs 2>/dev/null | sed -n 's/.*"Hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
fi

printf 'JETFUEL_INVENTORY_SERIAL=%s\n' "$(clean_value "$serial")"
printf 'JETFUEL_INVENTORY_SKU=%s\n' "$(clean_value "$sku")"
printf 'JETFUEL_INVENTORY_APP_VERSION=%s\n' "$(clean_value "$app_version")"
printf 'JETFUEL_INVENTORY_SYSTEM_VERSION=%s\n' "$(clean_value "$system_version")"
printf 'JETFUEL_INVENTORY_MAC=%s\n' "$(clean_value "$mac")"
printf 'JETFUEL_INVENTORY_HOSTNAME=%s\n' "$(clean_value "$hostname_value")"
printf 'JETFUEL_INVENTORY_TAILSCALE_NAME=%s\n' "$(clean_value "$tailscale_name")"
printf 'JETFUEL_INVENTORY_CLOUD_STATE=%s\n' "$(clean_value "$cloud_state")"
'@

    $command = ConvertTo-JetKvmEncodedShellCommand -Script $script
    $result = Invoke-JetKvmSshCommand -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Command $command -TimeoutSeconds 25
    if ($result.TimedOut) {
        throw "JetKVM inventory collection timed out after 25 seconds."
    }
    if ($result.ExitCode -ne 0) {
        throw "JetKVM inventory collection failed with exit code $($result.ExitCode)."
    }

    $values = @{}
    foreach ($line in ((Remove-AnsiEscapeSequences -Text $result.Output) -split "`n")) {
        if ($line -match '^JETFUEL_INVENTORY_([A-Z_]+)=(.*)$') {
            $values[$Matches[1]] = $Matches[2].Trim()
        }
    }
    if (-not $values.ContainsKey("SKU")) {
        throw "JetKVM inventory output was incomplete. Confirm Developer Mode SSH access and try again."
    }

    function Get-InventoryValue([string]$Name, [string]$Fallback = "Not available") {
        if ($values.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace([string]$values[$Name])) {
            return [string]$values[$Name]
        }
        return $Fallback
    }

    $sku = Get-InventoryValue "SKU" "jetkvm-v2"
    $appVersion = Get-InventoryValue "APP_VERSION" "Unknown"
    $systemVersion = Get-InventoryValue "SYSTEM_VERSION" "Unknown"
    return [pscustomobject][ordered]@{
        KvmMake = "JetKVM"
        KvmModelVersion = "$sku | App $appVersion | System $systemVersion"
        SerialNumber = Get-InventoryValue "SERIAL"
        MacAddress = (Get-InventoryValue "MAC").ToUpperInvariant()
        Hostname = Get-InventoryValue "HOSTNAME"
        TailscaleName = Get-InventoryValue "TAILSCALE_NAME"
        CloudConfiguredState = Get-InventoryValue "CLOUD_STATE" "Unknown"
        JetKvmAddress = $JetKvmAddress
        CollectedAt = Get-Date
    }
}

function Get-LocalWindowsInventory {
    $unavailable = "Unavailable"
    $pc = $null
    $bios = $null
    $cpu = $null
    $operatingSystem = $null
    $nic = $null
    $networkAdapters = @()

    try { $pc = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch {}
    try { $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop } catch {}
    try { $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch {}
    try { $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
    try { $networkAdapters = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction Stop) } catch {}
    try {
        $adaptersByIndex = @{}
        foreach ($adapter in $networkAdapters) {
            $adaptersByIndex[[string]$adapter.Index] = $adapter
        }

        $nic = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop |
            Where-Object { $_.IPEnabled -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$_.MACAddress) } |
            Sort-Object @{ Expression = {
                    $adapter = $adaptersByIndex[[string]$_.Index]
                    $pnpId = if ($adapter -and $adapter.PNPDeviceID) { [string]$adapter.PNPDeviceID } else { "" }
                    if ($pnpId -like 'PCI\*' -or $pnpId -like 'USB\*') { 0 }
                    elseif ($adapter -and $adapter.PhysicalAdapter -eq $true) { 1 }
                    else { 2 }
                }
            }, @{ Expression = { if (@($_.DefaultIPGateway).Count -gt 0) { 0 } else { 1 } } }, Index |
            Select-Object -First 1
    } catch {}

    $ramGb = $unavailable
    if ($pc -and $pc.TotalPhysicalMemory) {
        $ramGb = [math]::Round(([double]$pc.TotalPhysicalMemory / 1GB), 2)
    }

    $externalIp = $unavailable
    try {
        $ipResult = Invoke-RestMethod -UseBasicParsing -Uri "https://api.ipify.org?format=json" -TimeoutSec 12 -ErrorAction Stop
        if ($ipResult -and -not [string]::IsNullOrWhiteSpace([string]$ipResult.ip)) {
            $externalIp = ([string]$ipResult.ip).Trim()
        }
    } catch {}

    function Get-LocalInventoryValue($Value) {
        if ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)) {
            return ([string]$Value).Trim()
        }
        return $unavailable
    }

    $windowsVersion = $unavailable
    if ($operatingSystem) {
        $caption = Get-LocalInventoryValue $operatingSystem.Caption
        $buildNumber = Get-LocalInventoryValue $operatingSystem.BuildNumber
        if ($caption -ne $unavailable -and $buildNumber -ne $unavailable) {
            $windowsVersion = "$caption (build $buildNumber)"
        } elseif ($caption -ne $unavailable) {
            $windowsVersion = $caption
        }
    }

    return [pscustomobject][ordered]@{
        PcName = Get-LocalInventoryValue $(if ($pc) { $pc.Name } else { $null })
        PcMake = Get-LocalInventoryValue $(if ($pc) { $pc.Manufacturer } else { $null })
        PcModel = Get-LocalInventoryValue $(if ($pc) { $pc.Model } else { $null })
        WindowsVersion = $windowsVersion
        SerialNumber = Get-LocalInventoryValue $(if ($bios) { $bios.SerialNumber } else { $null })
        MacAddress = Get-LocalInventoryValue $(if ($nic) { $nic.MACAddress } else { $null })
        Cpu = Get-LocalInventoryValue $(if ($cpu) { $cpu.Name } else { $null })
        RamGb = $ramGb
        ExternalIp = $externalIp
    }
}

function Format-JetKvmInventoryReport {
    param([Parameter(Mandatory)]$Inventory)

    $report = @(
        "JetFUEL deployment inventory",
        "Generated: $($Inventory.CollectedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))",
        "JetKVM address: $($Inventory.JetKvmAddress)",
        "",
        "JETKVM DEVICE",
        "KVM Make: $($Inventory.KvmMake)",
        "KVM Model/Version: $($Inventory.KvmModelVersion)",
        "KVM Serial Number: $($Inventory.SerialNumber)",
        "KVM MAC: $($Inventory.MacAddress)",
        "Hostname: $($Inventory.Hostname)",
        "Tailscale Name: $($Inventory.TailscaleName)",
        "Cloud Configured State: $($Inventory.CloudConfiguredState)",
        ""
    )

    if ($Inventory.LocalComputer) {
        $local = $Inventory.LocalComputer
        $report += @(
            "LOCAL WINDOWS PC",
            "PC Name: $($local.PcName)",
            "PC Make: $($local.PcMake)",
            "PC Model: $($local.PcModel)",
            "Windows Version: $($local.WindowsVersion)",
            "PC Serial Number: $($local.SerialNumber)",
            "PC MAC: $($local.MacAddress)",
            "CPU: $($local.Cpu)",
            "RAM (GB): $($local.RamGb)",
            "External IP: $($local.ExternalIp)",
            ""
        )
    }

    return ($report -join [Environment]::NewLine)
}

function Save-JetKvmInventoryReport {
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Choose a report file path."
    }
    [IO.File]::WriteAllText($Path, (Format-JetKvmInventoryReport -Inventory $Inventory), [Text.UTF8Encoding]::new($false))
    return $Path
}

function Get-JetKvmManualAppUpdateCommand {
    return @'
echo '=== JetKVM manual app update ==='
JETKVM_SKU="$(cat /etc/jetkvm-sku 2>/dev/null || printf jetkvm-v2)"
echo "Hardware SKU: $JETKVM_SKU"
set -- $(wget -qO - "https://api.jetkvm.com/releases?deviceId=manual-update&sku=$JETKVM_SKU&appVersion=%3E%3D0.0.0" | sed -n 's/.*"appUrl":"\([^"]*\)".*"appHash":"\([^"]*\)".*/\1 \2/p')
if [ "$#" -ne 2 ]; then
  echo 'ERROR: release API did not return an app URL and SHA-256 hash'
  exit 1
fi
app_url="$1"
app_hash="$2"
tmp_file="$(mktemp)" || exit 1
echo "Downloading compatible app release from $app_url"
if ! wget "$app_url" -O "$tmp_file"; then
  rm -f "$tmp_file"
  echo 'ERROR: app download failed'
  exit 1
fi
if ! printf '%s  %s\n' "$app_hash" "$tmp_file" | sha256sum -c -; then
  rm -f "$tmp_file"
  echo 'ERROR: downloaded app failed SHA-256 verification'
  exit 1
fi
chmod +x "$tmp_file" || exit 1
mv "$tmp_file" /userdata/jetkvm/jetkvm_app.update || exit 1
sync
echo '[OK] verified app update staged; JetKVM is rebooting'
( sleep 2; reboot ) >/dev/null 2>&1 &
'@
}

function Get-MacIdentityProfiles {
    return @(
        [pscustomobject]@{
            Name = "JetFUEL generated (recommended)"
            Prefix = @(0x02, 0x4A, 0x46)
            Description = "Local-administered JetFUEL profile. Safe default."
        },
        [pscustomobject]@{
            Name = "Android / media profile"
            Prefix = @(0x02, 0x41, 0x4E)
            Description = "Local-administered profile label for Android/media-style devices."
        },
        [pscustomobject]@{
            Name = "Fire TV / streaming profile"
            Prefix = @(0x02, 0x46, 0x54)
            Description = "Local-administered profile label for streaming devices."
        },
        [pscustomobject]@{
            Name = "TP-Link smart plug / IoT profile"
            Prefix = @(0x02, 0x54, 0x50)
            Description = "Local-administered profile label for IoT devices."
        },
        [pscustomobject]@{
            Name = "Generic IoT profile"
            Prefix = @(0x02, 0x10, 0x7E)
            Description = "Local-administered profile label for generic IoT devices."
        },
        [pscustomobject]@{
            Name = "Custom MAC"
            Prefix = $null
            Description = "Manual MAC value. Advanced users only."
        }
    )
}

function Format-MacAddress {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $clean = ($Value.Trim() -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($clean.Length -ne 12) { return $Value.Trim().ToUpperInvariant().Replace("-", ":") }

    $parts = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt 12; $i += 2) {
        $parts.Add($clean.Substring($i, 2))
    }
    return ($parts -join ":")
}

function Assert-MacAddress {
    param([AllowEmptyString()][string]$MacAddress)

    if ([string]::IsNullOrWhiteSpace($MacAddress)) {
        throw "Enter or generate a MAC address first."
    }
    if ($MacAddress -notmatch '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$') {
        throw "MAC address must use XX:XX:XX:XX:XX:XX format."
    }
    $upper = $MacAddress.ToUpperInvariant()
    if ($upper -eq "00:00:00:00:00:00" -or $upper -eq "FF:FF:FF:FF:FF:FF") {
        throw "That MAC address is not valid for use on a network."
    }
    $firstOctet = [Convert]::ToInt32($upper.Substring(0, 2), 16)
    if (($firstOctet -band 1) -ne 0) {
        throw "The MAC address is multicast. Use a unicast MAC address."
    }
}

function Test-MacAddressIsLocalAdministered {
    param([Parameter(Mandatory)][string]$MacAddress)
    $firstOctet = [Convert]::ToInt32($MacAddress.Substring(0, 2), 16)
    return (($firstOctet -band 2) -ne 0)
}

function New-MacAddressFromProfile {
    param([Parameter(Mandatory)]$Profile)

    if (-not $Profile.Prefix) {
        throw "Select a generated profile or type a custom MAC address."
    }

    $randomBytes = New-Object byte[] 3
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($randomBytes)
    } finally {
        $rng.Dispose()
    }

    $bytes = @(
        [int]$Profile.Prefix[0],
        [int]$Profile.Prefix[1],
        [int]$Profile.Prefix[2],
        [int]$randomBytes[0],
        [int]$randomBytes[1],
        [int]$randomBytes[2]
    )
    return ("{0:X2}:{1:X2}:{2:X2}:{3:X2}:{4:X2}:{5:X2}" -f $bytes)
}

function ConvertFrom-WmiMonitorString {
    param($Value)

    if (-not $Value) { return "" }
    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($code in $Value) {
        if ([int]$code -eq 0) { continue }
        $chars.Add([char][int]$code)
    }
    return (-join $chars).Trim()
}

function Get-DisplayInstanceKeyFromPath {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $match = [regex]::Match($Path, 'DISPLAY\\([^\\]+)\\([^\\]+)\\Device Parameters', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return "" }
    return ("DISPLAY\{0}\{1}" -f $match.Groups[1].Value, $match.Groups[2].Value).ToUpperInvariant()
}

function Get-LocalDisplayEdidRecords {
    $records = New-Object System.Collections.Generic.List[object]
    $monitorMap = @{}
    try {
        $monitors = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue
        foreach ($monitor in $monitors) {
            $instance = ([string]$monitor.InstanceName -replace '_\d+$', '').ToUpperInvariant()
            $monitorMap[$instance] = [pscustomobject]@{
                FriendlyName = ConvertFrom-WmiMonitorString -Value $monitor.UserFriendlyName
                Manufacturer = ConvertFrom-WmiMonitorString -Value $monitor.ManufacturerName
                Serial = ConvertFrom-WmiMonitorString -Value $monitor.SerialNumberID
                ProductCode = ConvertFrom-WmiMonitorString -Value $monitor.ProductCodeID
            }
        }
    } catch {}

    try {
        $items = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\*\*\Device Parameters' -ErrorAction SilentlyContinue |
            Where-Object { $_.EDID }
        foreach ($item in $items) {
            $bytes = [byte[]]$item.EDID
            $hex = (($bytes | ForEach-Object { "{0:X2}" -f $_ }) -join "")
            $instanceKey = Get-DisplayInstanceKeyFromPath -Path $item.PSPath
            $monitorInfo = if ($monitorMap.ContainsKey($instanceKey)) { $monitorMap[$instanceKey] } else { $null }
            $displayName = if ($monitorInfo -and -not [string]::IsNullOrWhiteSpace($monitorInfo.FriendlyName)) {
                $monitorInfo.FriendlyName
            } elseif (-not [string]::IsNullOrWhiteSpace($instanceKey)) {
                $instanceKey
            } else {
                "Monitor EDID"
            }
            $details = @()
            if ($monitorInfo -and -not [string]::IsNullOrWhiteSpace($monitorInfo.Manufacturer)) { $details += $monitorInfo.Manufacturer }
            if ($monitorInfo -and -not [string]::IsNullOrWhiteSpace($monitorInfo.ProductCode)) { $details += "Product $($monitorInfo.ProductCode)" }
            if ($monitorInfo -and -not [string]::IsNullOrWhiteSpace($monitorInfo.Serial)) { $details += "Serial $($monitorInfo.Serial)" }
            $detailText = ($details -join ", ")
            $displayText = if ([string]::IsNullOrWhiteSpace($detailText)) {
                "$displayName ($($bytes.Length) bytes)"
            } else {
                "$displayName - $detailText ($($bytes.Length) bytes)"
            }
            $records.Add([pscustomobject]@{
                DisplayName = $displayText
                Name = $displayName
                Manufacturer = if ($monitorInfo) { $monitorInfo.Manufacturer } else { "" }
                Serial = if ($monitorInfo) { $monitorInfo.Serial } else { "" }
                ProductCode = if ($monitorInfo) { $monitorInfo.ProductCode } else { "" }
                InstanceKey = $instanceKey
                Source = $item.PSPath
                Bytes = $bytes.Length
                Hex = $hex
            })
        }
    } catch {}
    return $records
}

function Get-LocalUsbInputDevices {
    $devices = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    try {
        $allItems = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)
        $serialByVidPid = @{}
        foreach ($usbItem in $allItems) {
            if ($usbItem.PNPDeviceID -match '^USB\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})\\(.+)$') {
                $key = ("0x{0}|0x{1}" -f $Matches[1].ToLowerInvariant(), $Matches[2].ToLowerInvariant())
                if (-not $serialByVidPid.ContainsKey($key)) {
                    $candidate = ([string]$Matches[3] -replace '[\x00-\x1F\x7F]', '').Trim()
                    if ($candidate.Length -gt 64) { $candidate = $candidate.Substring(0, 64) }
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) { $serialByVidPid[$key] = $candidate }
                }
            }
        }

        $items = $allItems |
            Where-Object {
                $_.PNPDeviceID -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})' -and
                ($_.PNPClass -in @("Keyboard", "Mouse", "HIDClass"))
            }
        foreach ($item in $items) {
            $match = [regex]::Match($item.PNPDeviceID, 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})')
            if ($match.Success) {
                $name = if ([string]::IsNullOrWhiteSpace($item.Name)) { "USB input device" } else { [string]$item.Name }
                $manufacturer = if ([string]::IsNullOrWhiteSpace($item.Manufacturer)) { "Unknown manufacturer" } else { [string]$item.Manufacturer }
                $class = if ([string]::IsNullOrWhiteSpace($item.PNPClass)) { "HIDClass" } else { [string]$item.PNPClass }
                $vendorId = "0x" + $match.Groups[1].Value.ToLowerInvariant()
                $productId = "0x" + $match.Groups[2].Value.ToLowerInvariant()
                $serial = ""
                $serialKey = "$vendorId|$productId"
                if ($serialByVidPid.ContainsKey($serialKey)) {
                    $serial = [string]$serialByVidPid[$serialKey]
                } elseif ($item.PNPDeviceID -match '\\([^\\]+)$') {
                    $serial = ([string]$Matches[1] -replace '[\x00-\x1F\x7F]', '').Trim()
                    if ($serial.Length -gt 64) { $serial = $serial.Substring(0, 64) }
                }
                $dedupeKey = ("{0}|{1}|{2}|{3}|{4}|{5}" -f $vendorId, $productId, $class, $manufacturer, $name, $serial).ToUpperInvariant()
                if ($seen.ContainsKey($dedupeKey)) { continue }
                $seen[$dedupeKey] = $true
                $displayName = "{0}:{1} [{2}] {3} - {4}" -f $vendorId, $productId, $class, $manufacturer, $name
                if (-not [string]::IsNullOrWhiteSpace($serial)) { $displayName += " (serial $serial)" }
                $devices.Add([pscustomobject]@{
                    DisplayName = $displayName
                    Name = $name
                    Manufacturer = $manufacturer
                    Class = $class
                    VendorId = $vendorId
                    ProductId = $productId
                    SerialNumber = $serial
                    PnpDeviceId = $item.PNPDeviceID
                })
            }
        }
    } catch {}
    return $devices
}

function New-JetKvmUsbSerialNumber {
    $hexLength = Get-Random -Minimum 7 -Maximum 8
    $chars = "0123456789abcdef"
    $hex = -join (1..$hexLength | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
    return "{0}&{1}&0&1" -f (Get-Random -Minimum 1 -Maximum 10), $hex
}

function Get-JetKvmEdidPresets {
    # Values mirrored from JetKVM's video settings UI presets.
    return @(
        [pscustomobject]@{
            DisplayName = "JetKVM default - JetKVM v1 1920x1080@60 / 1280x720 (256 bytes)"
            Name = "JetKVM default"
            Source = "JetKVM preset"
            Bytes = 256
            Hex = "00FFFFFFFFFFFF0028B4010001EEFFC0302301038047287856EE91A3544C99260F5054000000D1C081C0318001010101010101010101023A801871382D40582C4500C48E2100001E773300A050D02B2030203500122C2100001A000000FD00174C0F5111000A202020202020000000FC004A65744B564D2076310A20202001D5020322D1431004012309070783010000E200CFE40D100401E305000065030C001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000CF"
            IsPreset = $true
        },
        [pscustomobject]@{
            DisplayName = "JetKVM preset - Acer B246WL (256 bytes)"
            Name = "Acer B246WL"
            Source = "JetKVM preset"
            Bytes = 256
            Hex = "00FFFFFFFFFFFF00047265058A3F6101101E0104A53420783FC125A8554EA0260D5054BFEF80714F8140818081C081008B009500B300283C80A070B023403020360006442100001A000000FD00304C575716010A202020202020000000FC0042323436574C0A202020202020000000FF0054384E4545303033383532320A01F802031CF14F90020304050607011112131415161F2309070783010000011D8018711C1620582C250006442100009E011D007251D01E206E28550006442100001E8C0AD08A20E02D10103E9600064421000018C344806E70B028401720A80406442100001E00000000000000000000000000000000000000000000000000000096"
            IsPreset = $true
        },
        [pscustomobject]@{
            DisplayName = "JetKVM preset - ASUS PA248QV (256 bytes)"
            Name = "ASUS PA248QV"
            Source = "JetKVM preset"
            Bytes = 256
            Hex = "00FFFFFFFFFFFF0006B3872401010101021F010380342078EA6DB5A7564EA0250D5054BF6F00714F8180814081C0A9409500B300D1C0283C80A070B023403020360006442100001A000000FD00314B1E5F19000A202020202020000000FC00504132343851560A2020202020000000FF004D314C4D51533035323135370A014D02032AF14B900504030201111213141F230907078301000065030C001000681A00000101314BE6E2006A023A801871382D40582C450006442100001ECD5F80B072B0374088D0360006442100001C011D007251D01E206E28550006442100001E8C0AD08A20E02D10103E960006442100001800000000000000000000000000DC"
            IsPreset = $true
        },
        [pscustomobject]@{
            DisplayName = "JetKVM preset - Dell D2721H (256 bytes)"
            Name = "Dell D2721H"
            Source = "JetKVM preset"
            Bytes = 256
            Hex = "00FFFFFFFFFFFF0010AC132045393639201E0103803C22782ACD25A3574B9F270D5054A54B00714F8180A9C0D1C00101010101010101023A801871382D40582C450056502100001E000000FF00335335475132330A2020202020000000FC0044454C4C204432373231480A20000000FD00384C1E5311000A202020202020018102031AB14F90050403020716010611121513141F65030C001000023A801871382D40582C450056502100001E011D8018711C1620582C250056502100009E011D007251D01E206E28550056502100001E8C0AD08A20E02D10103E960056502100001800000000000000000000000000000000000000000000000000000000004F"
            IsPreset = $true
        },
        [pscustomobject]@{
            DisplayName = "JetKVM preset - Dell iDRAC (128 bytes)"
            Name = "Dell iDRAC"
            Source = "JetKVM preset"
            Bytes = 128
            Hex = "00FFFFFFFFFFFF0010AC0100020000000111010380221BFF0A00000000000000000000ADCE0781800101010101010101010101010101000000FF0030303030303030303030303030000000FF0030303030303030303030303030000000FD00384C1F530B000A000000000000000000FC0044454C4C2049445241430A2020000A"
            IsPreset = $true
        }
    )
}

function Get-JetKvmUsbIdentityPresets {
    # Values mirrored from JetKVM's Hardware > USB identifiers presets.
    return @(
        [pscustomobject]@{
            DisplayName = "JetKVM default - USB Emulation Device (0x1d6b:0x0104)"
            Name = "USB Emulation Device"
            Manufacturer = "JetKVM"
            Class = "JetKVM preset"
            VendorId = "0x1d6b"
            ProductId = "0x0104"
            SerialNumber = ""
            Source = "JetKVM preset"
            IsPreset = $true
        },
        [pscustomobject]@{
            DisplayName = "JetKVM preset - Logitech USB Input Device (0x046d:0xc52b)"
            Name = "Logitech USB Input Device"
            Manufacturer = "Logitech (x64)"
            Class = "JetKVM preset"
            VendorId = "0x046d"
            ProductId = "0xc52b"
            SerialNumber = New-JetKvmUsbSerialNumber
            Source = "JetKVM preset"
            IsPreset = $true
        },
        [pscustomobject]@{
            DisplayName = "JetKVM preset - Microsoft Wireless MultiMedia Keyboard (0x045e:0x005f)"
            Name = "Wireless MultiMedia Keyboard"
            Manufacturer = "Microsoft"
            Class = "JetKVM preset"
            VendorId = "0x045e"
            ProductId = "0x005f"
            SerialNumber = New-JetKvmUsbSerialNumber
            Source = "JetKVM preset"
            IsPreset = $true
        },
        [pscustomobject]@{
            DisplayName = "JetKVM preset - Dell Multimedia Pro Keyboard (0x413c:0x2011)"
            Name = "Multimedia Pro Keyboard"
            Manufacturer = "Dell Inc."
            Class = "JetKVM preset"
            VendorId = "0x413c"
            ProductId = "0x2011"
            SerialNumber = New-JetKvmUsbSerialNumber
            Source = "JetKVM preset"
            IsPreset = $true
        }
    )
}

function Assert-EdidHex {
    param([AllowEmptyString()][string]$Hex)

    if ([string]::IsNullOrWhiteSpace($Hex)) {
        throw "Select a display EDID first."
    }

    $clean = ($Hex -replace '\s', '').ToUpperInvariant()
    if ($clean -notmatch '^[0-9A-F]+$') {
        throw "EDID must be hex only."
    }
    if ($clean.Length -ne 256 -and $clean.Length -ne 512) {
        throw "EDID must be 128 or 256 bytes. The selected EDID is $($clean.Length / 2) bytes."
    }
    if (-not $clean.StartsWith("00FFFFFFFFFFFF00")) {
        throw "EDID header is invalid. Expected 00FFFFFFFFFFFF00."
    }

    for ($blockStart = 0; $blockStart -lt $clean.Length; $blockStart += 256) {
        $sum = 0
        for ($i = $blockStart; $i -lt ($blockStart + 256); $i += 2) {
            $sum = ($sum + [Convert]::ToInt32($clean.Substring($i, 2), 16)) -band 0xFF
        }
        if ($sum -ne 0) {
            $blockNumber = [int](($blockStart / 256) + 1)
            throw "EDID block $blockNumber checksum is invalid."
        }
    }

    return $clean
}

function Set-JsonObjectProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Value
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        $property.Value = $Value
    } else {
        Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-JetKvmConfigObject {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath
    )

    $result = Invoke-JetKvmSshCommand -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Command "cat /userdata/kvm_config.json 2>/dev/null || echo '{}'" -TimeoutSeconds 20
    if ($result.ExitCode -ne 0) {
        throw "Could not read JetKVM config with SSH. Exit code $($result.ExitCode)."
    }

    $text = [string]$result.Output
    if ([string]::IsNullOrWhiteSpace($text)) { $text = "{}" }
    $start = $text.IndexOf("{")
    $end = $text.LastIndexOf("}")
    if ($start -lt 0 -or $end -lt $start) {
        throw "JetKVM config output did not contain JSON."
    }

    $json = $text.Substring($start, $end - $start + 1)
    try {
        $config = $json | ConvertFrom-Json
    } catch {
        throw "JetKVM config JSON could not be parsed: $($_.Exception.Message)"
    }
    if (-not $config) { $config = [pscustomobject]@{} }
    return $config
}

function ConvertTo-WindowsProcessArgument {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') {
            $backslashes++
            continue
        }
        if ($char -eq '"') {
            [void]$builder.Append('\' * (($backslashes * 2) + 1))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append('\' * $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($char)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append('\' * ($backslashes * 2))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Copy-TextToJetKvmFile {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$RemotePath,
        [int]$TimeoutSeconds = 30
    )

    $ssh = Get-CommandPath -Name "ssh.exe"
    if (-not $ssh) { $ssh = Get-CommandPath -Name "ssh" }
    if (-not $ssh) { throw "OpenSSH client was not found. Enable Windows OpenSSH Client and try again." }

    $sshArgs = @(
        "-i", $KeyPath,
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "IdentitiesOnly=yes",
        "-o", "IgnoreUnknown=WarnWeakCrypto",
        "-o", "WarnWeakCrypto=no-pq-kex",
        "root@$JetKvmAddress",
        "umask 077; cat > $(ConvertTo-ShellSingleQuoted $RemotePath)"
    )

    $process = $null
    try {
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $ssh
        $psi.Arguments = (($sshArgs | ForEach-Object { ConvertTo-WindowsProcessArgument $_ }) -join " ")
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $process = [Diagnostics.Process]::Start($psi)
        $process.StandardInput.Write($Content)
        $process.StandardInput.Close()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            return @{
                ExitCode = 124
                TimedOut = $true
                Output = "SSH write timed out after $TimeoutSeconds seconds."
            }
        }

        $output = (($process.StandardOutput.ReadToEnd(), $process.StandardError.ReadToEnd()) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
        return @{
            ExitCode = $process.ExitCode
            TimedOut = $false
            Output = $output.Trim()
        }
    } finally {
        if ($process) { $process.Dispose() }
    }
}

function Set-JetKvmTailscaleInitHook {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath,
        [scriptblock]$Log
    )

    if ($Log) { & $Log "Writing robust JetFUEL Tailscale boot hook to /userdata/init.d/S22tailscale..." }
    $write = Copy-TextToJetKvmFile -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Content (Get-JetKvmTailscaleInitScript) -RemotePath "/userdata/init.d/S22tailscale" -TimeoutSeconds 30
    if ($write.ExitCode -ne 0) {
        throw "Failed to write robust Tailscale boot hook: $($write.Output)"
    }

    $chmod = Invoke-JetKvmSshCommand -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Command "chmod +x /userdata/init.d/S22tailscale 2>&1 && /userdata/init.d/S22tailscale reload-watchdog 2>&1 && echo '[OK] robust boot hook installed and watchdog reloaded'" -TimeoutSeconds 20
    if ($chmod.Output -and $Log) { $chmod.Output -split "`n" | ForEach-Object { & $Log $_ } }
    if ($chmod.ExitCode -ne 0) {
        throw "Failed to make Tailscale boot hook executable: $($chmod.Output)"
    }
}

function Invoke-JetKvmTailscaleStartGuard {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath,
        [scriptblock]$Log,
        [int]$TimeoutSeconds = 50
    )

    $remotePath = "/tmp/jetfuel-start-tailscale.sh"
    $write = Copy-TextToJetKvmFile -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Content (Get-JetKvmTailscaleRemoteStartBlock) -RemotePath $remotePath -TimeoutSeconds 30
    if ($write.ExitCode -ne 0) {
        throw "Failed to write tailscaled start guard: $($write.Output)"
    }

    $result = Invoke-JetKvmSshCommand -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Command "chmod +x $remotePath && sh $remotePath 2>&1" -TimeoutSeconds $TimeoutSeconds
    if ($result.Output -and $Log) { $result.Output -split "`n" | ForEach-Object { & $Log $_ } }
    return $result
}

function Save-JetKvmConfigObject {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)]$Config,
        [scriptblock]$Log
    )

    $json = $Config | ConvertTo-Json -Depth 30

    $backupCmd = "if [ -f /userdata/kvm_config.json ]; then cp /userdata/kvm_config.json /userdata/kvm_config.json.jetfuel.bak.`$(date +%Y%m%d%H%M%S); fi"
    $backup = Invoke-JetKvmSshCommand -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Command $backupCmd -TimeoutSeconds 20
    if ($backup.Output -and $Log) { $backup.Output -split "`n" | ForEach-Object { & $Log $_ } }
    if ($backup.ExitCode -ne 0) {
        throw "Could not back up JetKVM config. Exit code $($backup.ExitCode)."
    }

    $copy = Copy-TextToJetKvmFile -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Content ($json + "`n") -RemotePath "/userdata/kvm_config.json" -TimeoutSeconds 30
    if ($copy.Output -and $Log) { $copy.Output -split "`n" | ForEach-Object { & $Log $_ } }
    if ($copy.ExitCode -ne 0) {
        throw "Could not write JetKVM config. Exit code $($copy.ExitCode)."
    }

    $sync = Invoke-JetKvmSshCommand -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Command "sync && echo '[OK] /userdata/kvm_config.json updated'" -TimeoutSeconds 20
    if ($sync.Output -and $Log) { $sync.Output -split "`n" | ForEach-Object { & $Log $_ } }
    if ($sync.ExitCode -ne 0) {
        throw "JetKVM config was copied, but sync verification failed with exit code $($sync.ExitCode)."
    }
}

function Update-JetKvmConfig {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][scriptblock]$Update,
        [scriptblock]$Log
    )

    $config = Get-JetKvmConfigObject -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath
    & $Update $config
    Save-JetKvmConfigObject -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Config $config -Log $Log
}

function Update-JetKvmConfigProperty {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Value,
        [scriptblock]$Log
    )

    $config = Get-JetKvmConfigObject -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath
    Set-JsonObjectProperty -Object $config -Name $Name -Value $Value
    Save-JetKvmConfigObject -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Config $config -Log $Log
}

function Test-IPv4Address {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Value.Trim(), [ref]$ip)) { return $false }
    return $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
}

function Get-IPv4BroadcastAddress {
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][int]$PrefixLength
    )

    if (-not (Test-IPv4Address -Value $IPAddress)) { return "" }
    if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) { return "" }

    $bytes = [Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
    [Array]::Reverse($bytes)
    $ipInt = [BitConverter]::ToUInt32($bytes, 0)
    $hostMask = if ($PrefixLength -eq 32) { [uint32]0 } else { [uint32]([Math]::Pow(2, 32 - $PrefixLength) - 1) }
    $broadcast = [uint32]($ipInt -bor $hostMask)
    $outBytes = [BitConverter]::GetBytes($broadcast)
    [Array]::Reverse($outBytes)
    return (($outBytes | ForEach-Object { $_.ToString() }) -join ".")
}

function Get-LocalWakeOnLanAdapters {
    $getNetAdapter = Get-Command Get-NetAdapter -ErrorAction SilentlyContinue
    if (-not $getNetAdapter) {
        throw "Get-NetAdapter is not available on this Windows system."
    }

    $defaultIndexes = @()
    try {
        $defaultIndexes = @(
            Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                Sort-Object RouteMetric, InterfaceMetric |
                Select-Object -ExpandProperty ifIndex -Unique
        )
    } catch {}

    $adapters = @(
        Get-NetAdapter -Physical -ErrorAction Stop |
            Where-Object { $_.MacAddress -and $_.Status -ne "Disabled" }
    )

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($adapter in $adapters) {
        $ipAddress = ""
        $prefixLength = $null
        $gateway = ""
        $broadcast = ""
        try {
            $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
            $ipv4 = @($ipConfig.IPv4Address | Where-Object {
                $_.IPAddress -and $_.IPAddress -notlike "169.254.*"
            } | Select-Object -First 1)
            if ($ipv4.Count -gt 0) {
                $ipAddress = [string]$ipv4[0].IPAddress
                $prefixLength = [int]$ipv4[0].PrefixLength
                $broadcast = Get-IPv4BroadcastAddress -IPAddress $ipAddress -PrefixLength $prefixLength
            }
            if ($ipConfig.IPv4DefaultGateway -and $ipConfig.IPv4DefaultGateway.NextHop) {
                $gateway = [string]$ipConfig.IPv4DefaultGateway.NextHop
            }
        } catch {}

        $isDefault = $defaultIndexes -contains $adapter.ifIndex
        $isWireless = (
            $adapter.Name -match 'wi-?fi|wireless|wlan' -or
            $adapter.InterfaceDescription -match 'wi-?fi|wireless|wlan|802\.11'
        )
        $score = 0
        if ($adapter.Status -eq "Up") { $score += 50 }
        if ($isDefault) { $score += 100 }
        if (-not [string]::IsNullOrWhiteSpace($ipAddress)) { $score += 25 }
        if (-not $isWireless) { $score += 20 }

        $mac = Format-MacAddress -Value $adapter.MacAddress
        $displayParts = @($adapter.Name, $mac)
        if ($ipAddress) { $displayParts += $ipAddress }
        if ($isDefault) { $displayParts += "default route" }
        if ($isWireless) { $displayParts += "wireless" }

        $results.Add([pscustomobject]@{
            Name = [string]$adapter.Name
            InterfaceDescription = [string]$adapter.InterfaceDescription
            InterfaceIndex = [int]$adapter.ifIndex
            Status = [string]$adapter.Status
            MacAddress = $mac
            IPAddress = $ipAddress
            PrefixLength = $prefixLength
            BroadcastIP = $broadcast
            Gateway = $gateway
            IsDefaultRoute = [bool]$isDefault
            IsWireless = [bool]$isWireless
            Score = $score
            DisplayName = ($displayParts -join " | ")
        }) | Out-Null
    }

    return @($results | Sort-Object -Property @{ Expression = "Score"; Descending = $true }, "Name")
}

function Enable-LocalAdapterWakeOnLan {
    param(
        [Parameter(Mandatory)][string]$AdapterName,
        [Parameter(Mandatory)][string]$AdapterDescription,
        [scriptblock]$Log
    )

    if (-not (Test-IsAdministrator)) {
        throw "Enabling Wake-on-LAN on this Windows PC requires PowerShell to be running as Administrator."
    }

    $changes = 0

    if (Get-Command Set-NetAdapterPowerManagement -ErrorAction SilentlyContinue) {
        try {
            Set-NetAdapterPowerManagement -Name $AdapterName -WakeOnMagicPacket Enabled -ErrorAction Stop
            if ($Log) { & $Log "Enabled Windows adapter WakeOnMagicPacket for '$AdapterName'." }
            $changes++
        } catch {
            if ($Log) { & $Log "Warning: could not set WakeOnMagicPacket on '$AdapterName': $(Get-CleanExceptionMessage -ErrorRecord $_)" }
        }
    }

    if (Get-Command Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue) {
        $advanced = @()
        try { $advanced = @(Get-NetAdapterAdvancedProperty -Name $AdapterName -ErrorAction SilentlyContinue) } catch {}
        foreach ($pattern in @('^Wake on Magic Packet$', '^Shutdown Wake[- ]On[- ]Lan$', '^Wake on Magic Packet from power off state$')) {
            $property = $advanced | Where-Object { $_.DisplayName -match $pattern } | Select-Object -First 1
            if ($property) {
                try {
                    Set-NetAdapterAdvancedProperty -Name $AdapterName -DisplayName $property.DisplayName -DisplayValue "Enabled" -ErrorAction Stop
                    if ($Log) { & $Log "Enabled adapter advanced property '$($property.DisplayName)'." }
                    $changes++
                } catch {
                    if ($Log) { & $Log "Warning: could not enable '$($property.DisplayName)': $(Get-CleanExceptionMessage -ErrorRecord $_)" }
                }
            }
        }
    }

    $powercfg = Get-Command powercfg.exe -ErrorAction SilentlyContinue
    if ($powercfg -and -not [string]::IsNullOrWhiteSpace($AdapterDescription)) {
        try {
            $output = & $powercfg.Source /deviceenablewake "$AdapterDescription" 2>&1
            if ($LASTEXITCODE -eq 0) {
                if ($Log) { & $Log "Enabled wake permission with powercfg for '$AdapterDescription'." }
                $changes++
            } elseif ($Log) {
                & $Log "Warning: powercfg could not enable wake for '$AdapterDescription': $($output -join ' ')"
            }
        } catch {
            if ($Log) { & $Log "Warning: powercfg wake enable failed: $(Get-CleanExceptionMessage -ErrorRecord $_)" }
        }
    }

    if ($changes -eq 0) {
        throw "No Wake-on-LAN setting could be enabled for '$AdapterName'. The adapter driver may not expose WoL settings, or BIOS/UEFI may need manual configuration."
    }

    if ($Log) {
        & $Log "Windows WoL configuration attempted for '$AdapterName'. Confirm BIOS/UEFI also has Wake-on-LAN enabled."
    }
}

function ConvertTo-WakeOnLanDeviceName {
    param([AllowEmptyString()][string]$Value)

    $clean = ([string]$Value -replace '[\x00-\x1F\x7F]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = $env:COMPUTERNAME }
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = "Windows PC" }
    if ($clean.Length -gt 64) { $clean = $clean.Substring(0, 64) }
    return $clean
}

function Update-JetKvmWakeOnLanDevice {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$DeviceName,
        [Parameter(Mandatory)][string]$MacAddress,
        [AllowEmptyString()][string]$BroadcastIP,
        [scriptblock]$Log
    )

    $DeviceName = ConvertTo-WakeOnLanDeviceName -Value $DeviceName
    $MacAddress = Format-MacAddress -Value $MacAddress
    Assert-MacAddress -MacAddress $MacAddress
    if (-not [string]::IsNullOrWhiteSpace($BroadcastIP) -and -not (Test-IPv4Address -Value $BroadcastIP)) {
        throw "Broadcast IP must be a valid IPv4 address, or left blank."
    }

    $config = Get-JetKvmConfigObject -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath
    $existing = @()
    if ($config.PSObject.Properties["wake_on_lan_devices"] -and $null -ne $config.wake_on_lan_devices) {
        $existing = @($config.wake_on_lan_devices)
    }

    $devices = New-Object System.Collections.Generic.List[object]
    foreach ($device in $existing) {
        $existingMac = ""
        $existingName = ""
        if ($device.PSObject.Properties["macAddress"]) { $existingMac = [string]$device.macAddress }
        if ($device.PSObject.Properties["name"]) { $existingName = [string]$device.name }
        if ($existingMac -and ((Format-MacAddress -Value $existingMac) -ieq $MacAddress)) { continue }
        if ($existingName -and ($existingName -ieq $DeviceName)) { continue }
        $devices.Add($device) | Out-Null
    }

    $newDevice = [pscustomobject]@{
        name = $DeviceName
        macAddress = $MacAddress
    }
    if (-not [string]::IsNullOrWhiteSpace($BroadcastIP)) {
        Set-JsonObjectProperty -Object $newDevice -Name "broadcastIP" -Value $BroadcastIP.Trim()
    }
    $devices.Add($newDevice) | Out-Null

    Set-JsonObjectProperty -Object $config -Name "wake_on_lan_devices" -Value ([object[]]@($devices))
    Save-JetKvmConfigObject -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Config $config -Log $Log
}

function ConvertTo-PowerShellSingleQuoted {
    param([AllowEmptyString()][string]$Value)
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Get-LocalBiosVendorInfo {
    $system = $null
    $bios = $null
    try { $system = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch {}
    try { $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue } catch {}

    $manufacturer = if ($system) { ([string]$system.Manufacturer).Trim() } else { "" }
    $model = if ($system) { ([string]$system.Model).Trim() } else { "" }
    $biosVersion = if ($bios) { ((@($bios.SMBIOSBIOSVersion, $bios.Version) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) -as [string]) } else { "" }
    $serial = if ($bios) { ([string]$bios.SerialNumber).Trim() } else { "" }

    $vendorKey = "Unsupported"
    $displayVendor = "Unsupported"
    if ($manufacturer -match 'Dell') {
        $vendorKey = "Dell"
        $displayVendor = "Dell"
    } elseif ($manufacturer -match 'HP|Hewlett-Packard') {
        $vendorKey = "HP"
        $displayVendor = "HP"
    } elseif ($manufacturer -match 'Lenovo') {
        $vendorKey = "Lenovo"
        $displayVendor = "Lenovo"
    }

    return [pscustomobject]@{
        Manufacturer = $manufacturer
        Model = $model
        BiosVersion = $biosVersion
        SerialNumber = $serial
        VendorKey = $vendorKey
        DisplayVendor = $displayVendor
        Supported = ($vendorKey -ne "Unsupported")
    }
}

function Get-ConfigJonBiosRoot {
    $root = Get-JetFuelScriptRoot
    return (Join-Path $root "third_party\ConfigJon-Firmware-Management")
}

function Get-ConfigJonBiosManifest {
    $path = Join-Path (Get-ConfigJonBiosRoot) "metadata.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-ConfigJonBiosScriptPath {
    param([Parameter(Mandatory)][ValidateSet("Dell", "HP", "Lenovo")] [string]$VendorKey)

    $root = Get-ConfigJonBiosRoot
    $relative = switch ($VendorKey) {
        "Dell" { "Dell\Manage-DellBiosSettings-WMI.ps1" }
        "HP" { "HP\Manage-HPBiosSettings-WMI.ps1" }
        "Lenovo" { "Lenovo\Manage-LenovoBiosSettings.ps1" }
    }
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Bundled ConfigJon BIOS script is missing: $path"
    }
    return $path
}

function Get-BiosWorkDirectory {
    $path = Join-Path $env:TEMP "JetFUEL\BIOS"
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

function Redact-BiosText {
    param(
        [AllowEmptyString()][string]$Text,
        [AllowEmptyString()][string[]]$Secrets
    )

    $clean = [string]$Text
    foreach ($secret in @($Secrets)) {
        if (-not [string]::IsNullOrWhiteSpace($secret)) {
            $clean = $clean.Replace($secret, "<redacted>")
        }
    }
    return $clean
}

function Invoke-ConfigJonBiosScript {
    param(
        [Parameter(Mandatory)][ValidateSet("Dell", "HP", "Lenovo")] [string]$VendorKey,
        [Parameter(Mandatory)][ValidateSet("Get", "Set")] [string]$Mode,
        [Parameter(Mandatory)][string]$CsvPath,
        [Parameter(Mandatory)][string]$LogFile,
        [AllowEmptyString()][string]$BiosPassword,
        [AllowEmptyString()][string]$SystemManagementPassword,
        [int]$TimeoutSeconds = 180
    )

    $scriptPath = Get-ConfigJonBiosScriptPath -VendorKey $VendorKey
    $scriptArg = ConvertTo-PowerShellSingleQuoted $scriptPath
    $csvArg = ConvertTo-PowerShellSingleQuoted $CsvPath
    $logArg = ConvertTo-PowerShellSingleQuoted $LogFile

    $modeArg = if ($Mode -eq "Get") { "-GetSettings" } else { "-SetSettings" }
    $passwordArgs = ""
    if ($Mode -eq "Set" -and -not [string]::IsNullOrWhiteSpace($BiosPassword)) {
        if ($VendorKey -eq "Dell") {
            $passwordArgs += " -AdminPassword `$env:JETFUEL_BIOS_PASSWORD"
        } elseif ($VendorKey -eq "HP") {
            $passwordArgs += " -SetupPassword `$env:JETFUEL_BIOS_PASSWORD"
        } elseif ($VendorKey -eq "Lenovo") {
            $passwordArgs += " -SupervisorPassword `$env:JETFUEL_BIOS_PASSWORD"
        }
    }
    if ($Mode -eq "Set" -and $VendorKey -eq "Lenovo" -and -not [string]::IsNullOrWhiteSpace($SystemManagementPassword)) {
        $passwordArgs += " -SystemManagementPassword `$env:JETFUEL_BIOS_SM_PASSWORD"
    }

    $command = @"
`$ErrorActionPreference = 'Continue'
& $scriptArg $modeArg -CsvPath $csvArg -LogFile $logArg$passwordArgs
if (`$global:LASTEXITCODE -is [int]) { exit `$global:LASTEXITCODE }
exit 0
"@

    $powershell = Get-CommandPath -Name "powershell.exe"
    if (-not $powershell) { throw "powershell.exe was not found." }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $powershell
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($BiosPassword)) {
        $psi.EnvironmentVariables["JETFUEL_BIOS_PASSWORD"] = $BiosPassword
    }
    if (-not [string]::IsNullOrWhiteSpace($SystemManagementPassword)) {
        $psi.EnvironmentVariables["JETFUEL_BIOS_SM_PASSWORD"] = $SystemManagementPassword
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch {}
        return [pscustomobject]@{
            ExitCode = 124
            TimedOut = $true
            Output = "ConfigJon BIOS script timed out after $TimeoutSeconds seconds."
            LogText = ""
        }
    }
    try { $process.WaitForExit() } catch {}

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $logText = ""
    if (Test-Path -LiteralPath $LogFile) {
        try { $logText = Get-Content -LiteralPath $LogFile -Raw } catch {}
    }

    $combined = (($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    $combined = Redact-BiosText -Text $combined -Secrets @($BiosPassword, $SystemManagementPassword)
    $logText = Redact-BiosText -Text $logText -Secrets @($BiosPassword, $SystemManagementPassword)

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        TimedOut = $false
        Output = $combined.Trim()
        LogText = $logText.Trim()
    }
}

function Get-BiosSettingValue {
    param(
        [Parameter(Mandatory)]$Setting,
        [Parameter(Mandatory)][string]$PropertyName
    )

    if ($Setting.PSObject.Properties[$PropertyName]) {
        return ([string]$Setting.$PropertyName).Trim()
    }
    return ""
}

function Get-BiosSettingPossibleValues {
    param([Parameter(Mandatory)]$Setting)

    $possibleText = ""
    foreach ($name in @("PossibleValue", "PossibleValues", "Possible Values")) {
        if ($Setting.PSObject.Properties[$name]) {
            $possibleText = [string]$Setting.$name
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($possibleText)) { return @() }

    return @(
        $possibleText -split '[,;|]' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '^(N/A|None)$' }
    )
}

function New-BiosCandidate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Reason
    )

    return [pscustomobject]@{
        Name = $Name
        Value = $Value
        Reason = $Reason
    }
}

function Get-BiosTargetCandidates {
    param(
        [Parameter(Mandatory)][ValidateSet("Dell", "HP", "Lenovo")] [string]$VendorKey,
        [bool]$EnableWakeOnLan = $true,
        [bool]$PowerOnAfterAc = $true,
        [bool]$DisablePowerBlockers = $true
    )

    $items = New-Object System.Collections.Generic.List[object]
    if ($VendorKey -eq "Dell") {
        if ($EnableWakeOnLan) { $items.Add((New-BiosCandidate "WakeOnLan" "LanOnly" "Enable Wake-on-LAN on wired LAN")) | Out-Null }
        if ($PowerOnAfterAc) { $items.Add((New-BiosCandidate "WakeOnAc" "Enabled" "Power on after AC power is restored")) | Out-Null }
    } elseif ($VendorKey -eq "HP") {
        if ($EnableWakeOnLan) {
            $items.Add((New-BiosCandidate "Wake On LAN" "Boot to Hard Drive" "Enable Wake-on-LAN")) | Out-Null
            $items.Add((New-BiosCandidate "Wake on LAN" "Follow Boot Order" "Enable Wake-on-LAN")) | Out-Null
            $items.Add((New-BiosCandidate "S5 Wake on LAN" "Enable" "Allow WOL from soft-off/S5")) | Out-Null
            $items.Add((New-BiosCandidate "S4/S5 Wake on LAN" "Enable" "Allow WOL from sleep/soft-off")) | Out-Null
            $items.Add((New-BiosCandidate "Remote Wakeup Boot Source" "Local Hard Drive" "Boot locally after remote wake")) | Out-Null
        }
        if ($PowerOnAfterAc) {
            $items.Add((New-BiosCandidate "After Power Loss" "On" "Power on after AC power is restored")) | Out-Null
            $items.Add((New-BiosCandidate "Power state after power loss" "Power On" "Power on after AC power is restored")) | Out-Null
        }
        if ($DisablePowerBlockers) {
            $items.Add((New-BiosCandidate "Deep Sleep" "Off" "Disable deep sleep that can block WOL")) | Out-Null
            $items.Add((New-BiosCandidate "S4/S5 Max Power Savings" "Disable" "Disable S4/S5 power saving that can block WOL")) | Out-Null
            $items.Add((New-BiosCandidate "S5 Maximum Power Savings" "Disable" "Disable S5 power saving that can block WOL")) | Out-Null
        }
    } elseif ($VendorKey -eq "Lenovo") {
        if ($EnableWakeOnLan) { $items.Add((New-BiosCandidate "Wake on LAN" "Primary" "Enable Wake-on-LAN")) | Out-Null }
        if ($PowerOnAfterAc) {
            $items.Add((New-BiosCandidate "After Power Loss" "Power On" "Power on after AC power is restored")) | Out-Null
            $items.Add((New-BiosCandidate "Power On with AC Attach" "Enabled" "Power on after AC power is restored")) | Out-Null
            $items.Add((New-BiosCandidate "Restore on AC Power Loss" "Power On" "Power on after AC power is restored")) | Out-Null
        }
        if ($DisablePowerBlockers) { $items.Add((New-BiosCandidate "Enhanced Power Saving Mode" "Disabled" "Disable power saving that can block WOL")) | Out-Null }
    }

    return @($items.ToArray())
}

function Resolve-BiosTargetSettings {
    param(
        [Parameter(Mandatory)][ValidateSet("Dell", "HP", "Lenovo")] [string]$VendorKey,
        [Parameter(Mandatory)]$Settings,
        [bool]$EnableWakeOnLan = $true,
        [bool]$PowerOnAfterAc = $true,
        [bool]$DisablePowerBlockers = $true
    )

    $settingMap = @{}
    foreach ($setting in @($Settings)) {
        $name = Get-BiosSettingValue -Setting $setting -PropertyName "Name"
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $key = $name.ToLowerInvariant()
            if (-not $settingMap.ContainsKey($key)) { $settingMap[$key] = $setting }
        }
    }

    $apply = New-Object System.Collections.Generic.List[object]
    $already = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[object]
    $used = @{}

    foreach ($candidate in (Get-BiosTargetCandidates -VendorKey $VendorKey -EnableWakeOnLan $EnableWakeOnLan -PowerOnAfterAc $PowerOnAfterAc -DisablePowerBlockers $DisablePowerBlockers)) {
        $lookup = $candidate.Name.ToLowerInvariant()
        if ($used.ContainsKey($lookup)) { continue }
        if (-not $settingMap.ContainsKey($lookup)) {
            $missing.Add([pscustomobject]@{
                Name = $candidate.Name
                TargetValue = $candidate.Value
                CurrentValue = ""
                Reason = $candidate.Reason
                Status = "Not exposed on this model"
            }) | Out-Null
            continue
        }

        $setting = $settingMap[$lookup]
        $actualName = Get-BiosSettingValue -Setting $setting -PropertyName "Name"
        $current = Get-BiosSettingValue -Setting $setting -PropertyName "Value"
        $possible = @(Get-BiosSettingPossibleValues -Setting $setting)
        if ($possible.Count -gt 0 -and -not ($possible | Where-Object { $_ -ieq $candidate.Value })) {
            $missing.Add([pscustomobject]@{
                Name = $actualName
                TargetValue = $candidate.Value
                CurrentValue = $current
                Reason = $candidate.Reason
                Status = "Value not listed by BIOS as available"
            }) | Out-Null
            continue
        }

        $row = [pscustomobject]@{
            Name = $actualName
            Value = $candidate.Value
            CurrentValue = $current
            Reason = $candidate.Reason
            Status = if ($current -ieq $candidate.Value) { "Already set" } else { "Will change" }
        }
        $used[$lookup] = $true
        if ($current -ieq $candidate.Value) {
            $already.Add($row) | Out-Null
        } else {
            $apply.Add($row) | Out-Null
        }
    }

    return [pscustomobject]@{
        ApplyRows = @($apply.ToArray())
        AlreadyRows = @($already.ToArray())
        MissingRows = @($missing.ToArray())
    }
}

function Format-BiosTargetReport {
    param(
        [Parameter(Mandatory)]$VendorInfo,
        [AllowNull()]$Targets
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Detected system: $($VendorInfo.Manufacturer) $($VendorInfo.Model)") | Out-Null
    $lines.Add("BIOS version: $($VendorInfo.BiosVersion)") | Out-Null
    $lines.Add("Vendor support: $($VendorInfo.DisplayVendor)") | Out-Null
    $lines.Add("") | Out-Null

    if (-not $VendorInfo.Supported) {
        $lines.Add("This BIOS tab supports Dell, HP, and Lenovo only. No BIOS settings will be changed.") | Out-Null
        return ($lines -join [Environment]::NewLine)
    }

    if (-not $Targets) {
        $lines.Add("Run Scan BIOS to list supported WOL and power-recovery settings for this model.") | Out-Null
        return ($lines -join [Environment]::NewLine)
    }

    if ($Targets.ApplyRows.Count -gt 0) {
        $lines.Add("Settings that will change:") | Out-Null
        foreach ($row in $Targets.ApplyRows) {
            $lines.Add("  - $($row.Name): '$($row.CurrentValue)' -> '$($row.Value)' ($($row.Reason))") | Out-Null
        }
    } else {
        $lines.Add("Settings that will change: none") | Out-Null
    }
    $lines.Add("") | Out-Null

    if ($Targets.AlreadyRows.Count -gt 0) {
        $lines.Add("Already correct:") | Out-Null
        foreach ($row in $Targets.AlreadyRows) {
            $lines.Add("  - $($row.Name): '$($row.Value)'") | Out-Null
        }
        $lines.Add("") | Out-Null
    }

    if ($Targets.MissingRows.Count -gt 0) {
        $lines.Add("Not changed / not available on this model:") | Out-Null
        foreach ($row in $Targets.MissingRows) {
            $lines.Add("  - $($row.Name): $($row.Status)") | Out-Null
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function Invoke-BiosSettingsScan {
    param(
        [bool]$EnableWakeOnLan = $true,
        [bool]$PowerOnAfterAc = $true,
        [bool]$DisablePowerBlockers = $true,
        [scriptblock]$Log
    )

    $vendor = Get-LocalBiosVendorInfo
    if ($Log) {
        & $Log "BIOS detected: $($vendor.Manufacturer) $($vendor.Model); BIOS $($vendor.BiosVersion)"
    }
    if (-not $vendor.Supported) {
        return [pscustomobject]@{
            VendorInfo = $vendor
            Settings = @()
            Targets = $null
            CsvPath = ""
            LogFile = ""
        }
    }

    $workDir = Get-BiosWorkDirectory
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $csvPath = Join-Path $workDir "$($vendor.VendorKey)-bios-settings-$stamp.csv"
    $logFile = Join-Path $workDir "$($vendor.VendorKey)-bios-scan-$stamp.log"

    if ($Log) { & $Log "Running ConfigJon $($vendor.VendorKey) BIOS settings scan..." }
    $result = Invoke-ConfigJonBiosScript -VendorKey $vendor.VendorKey -Mode Get -CsvPath $csvPath -LogFile $logFile
    foreach ($line in (($result.Output + "`n" + $result.LogText) -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 80)) {
        if ($Log) { & $Log ("BIOS: " + $line.Trim()) }
    }
    if ($result.ExitCode -ne 0) {
        throw "BIOS settings scan failed with exit code $($result.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $csvPath)) {
        throw "BIOS settings scan did not create the expected CSV: $csvPath"
    }

    $settings = @(Import-Csv -LiteralPath $csvPath)
    $targets = Resolve-BiosTargetSettings -VendorKey $vendor.VendorKey -Settings $settings -EnableWakeOnLan $EnableWakeOnLan -PowerOnAfterAc $PowerOnAfterAc -DisablePowerBlockers $DisablePowerBlockers
    if ($Log) {
        & $Log "BIOS scan complete. Settings found: $($settings.Count); changes available: $($targets.ApplyRows.Count); already correct: $($targets.AlreadyRows.Count); unavailable: $($targets.MissingRows.Count)"
    }

    return [pscustomobject]@{
        VendorInfo = $vendor
        Settings = $settings
        Targets = $targets
        CsvPath = $csvPath
        LogFile = $logFile
    }
}

function New-BiosSettingsCsv {
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)][string]$Path
    )

    $outRows = @(
        foreach ($row in @($Rows)) {
            [pscustomobject]@{
                Name = [string]$row.Name
                Value = [string]$row.Value
            }
        }
    )
    if ($outRows.Count -eq 0) {
        throw "No BIOS setting rows were selected for apply."
    }
    $outRows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding ASCII
}

function Invoke-BiosSettingsApply {
    param(
        [Parameter(Mandatory)]$Scan,
        [bool]$EnableWakeOnLan = $true,
        [bool]$PowerOnAfterAc = $true,
        [bool]$DisablePowerBlockers = $true,
        [AllowEmptyString()][string]$BiosPassword,
        [AllowEmptyString()][string]$SystemManagementPassword,
        [scriptblock]$Log
    )

    if (-not (Test-IsAdministrator)) {
        throw "Applying BIOS settings requires PowerShell to be running as Administrator."
    }
    if (-not $Scan -or -not $Scan.VendorInfo -or -not $Scan.VendorInfo.Supported) {
        throw "Run Scan BIOS on a supported Dell, HP, or Lenovo system before applying BIOS prep."
    }

    $targets = Resolve-BiosTargetSettings -VendorKey $Scan.VendorInfo.VendorKey -Settings $Scan.Settings -EnableWakeOnLan $EnableWakeOnLan -PowerOnAfterAc $PowerOnAfterAc -DisablePowerBlockers $DisablePowerBlockers
    if ($targets.ApplyRows.Count -eq 0) {
        return [pscustomobject]@{
            Changed = $false
            Targets = $targets
            Message = "No BIOS changes are needed or supported for the selected options."
        }
    }

    $workDir = Get-BiosWorkDirectory
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $csvPath = Join-Path $workDir "$($Scan.VendorInfo.VendorKey)-bios-apply-$stamp.csv"
    $logFile = Join-Path $workDir "$($Scan.VendorInfo.VendorKey)-bios-apply-$stamp.log"
    New-BiosSettingsCsv -Rows $targets.ApplyRows -Path $csvPath

    if ($Log) { & $Log "Applying $($targets.ApplyRows.Count) BIOS setting(s) with ConfigJon $($Scan.VendorInfo.VendorKey) script..." }
    $result = Invoke-ConfigJonBiosScript -VendorKey $Scan.VendorInfo.VendorKey -Mode Set -CsvPath $csvPath -LogFile $logFile -BiosPassword $BiosPassword -SystemManagementPassword $SystemManagementPassword
    foreach ($line in (($result.Output + "`n" + $result.LogText) -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 120)) {
        if ($Log) { & $Log ("BIOS: " + $line.Trim()) }
    }
    if ($result.ExitCode -ne 0) {
        throw "BIOS settings apply failed with exit code $($result.ExitCode)."
    }

    return [pscustomobject]@{
        Changed = $true
        Targets = $targets
        Message = "BIOS prep applied. Reboot the PC, then test Wake-on-LAN and AC power recovery."
        CsvPath = $csvPath
        LogFile = $logFile
    }
}

function Assert-JetKvmDomain {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "Custom domain is empty." }
    $clean = $Value.Trim().ToLowerInvariant()
    if ($clean -eq "dhcp" -or $clean -eq "local") { return }
    $label = '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
    if ($clean -notmatch "^$label(\.$label)*$") {
        throw "Custom domain must be lowercase DNS labels separated by dots, with no spaces or underscores."
    }
}

function Set-JetKvmRuntimeHostname {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Hostname,
        [AllowEmptyString()][string]$Domain,
        [scriptblock]$Log
    )

    $hostsLine = $Hostname
    if (-not [string]::IsNullOrWhiteSpace($Domain) -and $Domain -ne "dhcp") {
        $hostsLine = "$Hostname.$Domain $Hostname"
    }

    $quotedHostname = ConvertTo-ShellSingleQuoted $Hostname
    $quotedHostsLine = ConvertTo-ShellSingleQuoted $hostsLine
    $cmd = "printf '%s\n' $quotedHostname > /etc/hostname && { grep -v '^127[.]0[.]1[.]1[[:space:]]' /etc/hosts 2>/dev/null; printf '127.0.1.1\t%s\n' $quotedHostsLine; } > /tmp/jetfuel-hosts && cat /tmp/jetfuel-hosts > /etc/hosts && rm -f /tmp/jetfuel-hosts && hostname -F /etc/hostname && echo '[OK] runtime hostname set:' && hostname"
    $result = Invoke-JetKvmSshCommand -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Command $cmd -TimeoutSeconds 20
    if ($result.ExitCode -ne 0) {
        throw "Could not update JetKVM runtime hostname. Exit code $($result.ExitCode). $($result.Output)"
    }
    if ($Log) { & $Log $result.Output }
}

function Update-JetKvmDeviceSettings {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][bool]$AutoUpdateEnabled,
        [Parameter(Mandatory)][string]$KeyboardLayout,
        [Parameter(Mandatory)][int]$DisplayMaxBrightness,
        [Parameter(Mandatory)][int]$DisplayDimAfterSec,
        [Parameter(Mandatory)][int]$DisplayOffAfterSec,
        [Parameter(Mandatory)][int]$VideoSleepAfterSec,
        [Parameter(Mandatory)][bool]$SetNetworkHostname,
        [AllowEmptyString()][string]$NetworkHostname,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$MDNSMode,
        [Parameter(Mandatory)][string]$IPv6Mode,
        [scriptblock]$Log
    )

    $config = Get-JetKvmConfigObject -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath
    Set-JsonObjectProperty -Object $config -Name "auto_update_enabled" -Value $AutoUpdateEnabled
    Set-JsonObjectProperty -Object $config -Name "keyboard_layout" -Value $KeyboardLayout
    Set-JsonObjectProperty -Object $config -Name "display_max_brightness" -Value $DisplayMaxBrightness
    Set-JsonObjectProperty -Object $config -Name "display_dim_after_sec" -Value $DisplayDimAfterSec
    Set-JsonObjectProperty -Object $config -Name "display_off_after_sec" -Value $DisplayOffAfterSec
    Set-JsonObjectProperty -Object $config -Name "video_sleep_after_sec" -Value $VideoSleepAfterSec

    if (-not $config.PSObject.Properties["network_config"] -or $null -eq $config.network_config) {
        Set-JsonObjectProperty -Object $config -Name "network_config" -Value ([pscustomobject]@{})
    }

    $network = $config.network_config
    if ($SetNetworkHostname) {
        Set-JsonObjectProperty -Object $network -Name "hostname" -Value $NetworkHostname
    }
    Set-JsonObjectProperty -Object $network -Name "domain" -Value $Domain
    Set-JsonObjectProperty -Object $network -Name "mdns_mode" -Value $MDNSMode
    Set-JsonObjectProperty -Object $network -Name "ipv6_mode" -Value $IPv6Mode

    Save-JetKvmConfigObject -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Config $config -Log $Log

    if ($SetNetworkHostname) {
        Set-JetKvmRuntimeHostname -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Hostname $NetworkHostname -Domain $Domain -Log $Log
    }
}

function ConvertTo-JetKvmUsbConfig {
    param([Parameter(Mandatory)]$Device)

    if ($Device.VendorId -notmatch '^0x[0-9a-f]{4}$' -or $Device.ProductId -notmatch '^0x[0-9a-f]{4}$') {
        throw "Selected USB device does not contain a valid VID/PID."
    }

    $manufacturer = ([string]$Device.Manufacturer -replace '[\x00-\x1F\x7F]', '').Trim()
    $product = ([string]$Device.Name -replace '[\x00-\x1F\x7F]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($manufacturer)) { $manufacturer = "USB" }
    if ([string]::IsNullOrWhiteSpace($product)) { $product = "USB Input Device" }
    if ($manufacturer.Length -gt 64) { $manufacturer = $manufacturer.Substring(0, 64) }
    if ($product.Length -gt 64) { $product = $product.Substring(0, 64) }
    $serial = ""
    if ($Device.PSObject.Properties["SerialNumber"]) {
        $serial = ([string]$Device.SerialNumber -replace '[\x00-\x1F\x7F]', '').Trim()
        if ($serial.Length -gt 64) { $serial = $serial.Substring(0, 64) }
    }

    return [pscustomobject]@{
        vendor_id = $Device.VendorId
        product_id = $Device.ProductId
        serial_number = $serial
        manufacturer = $manufacturer
        product = $product
    }
}

function Assert-TailscaleAuthKeyLooksUsable {
    param([AllowEmptyString()][string]$AuthKey)

    if ([string]::IsNullOrWhiteSpace($AuthKey)) {
        throw "Paste the full Tailscale pre-authentication key. It should start with tskey-auth-."
    }

    if ($AuthKey -match '\s') {
        throw "The Tailscale auth key contains whitespace. Paste only the single full key value."
    }

    if ($AuthKey -match 'CNTRL$' -and $AuthKey -notmatch '^tskey-auth-') {
        throw "This looks like a Tailscale auth key ID from the admin table, not the full secret. Generate a new auth key and copy the full tskey-auth-... value shown at creation time."
    }

    if ($AuthKey -match '^tskey-api-') {
        throw "This is a Tailscale API key, not a pre-authentication key. Generate an auth key that starts with tskey-auth-."
    }

    if ($AuthKey -notmatch '^tskey-auth-') {
        throw "This does not look like a Tailscale pre-authentication key. It should start with tskey-auth-."
    }

    if ($AuthKey.Length -lt 40) {
        throw "This Tailscale auth key looks too short. Generate a new key and paste the full tskey-auth-... secret."
    }
}

function ConvertTo-TailscaleHostname {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }

    $name = $Value.Trim().ToLowerInvariant()
    $name = [regex]::Replace($name, '[^a-z0-9-]+', '-')
    $name = [regex]::Replace($name, '-{2,}', '-')
    $name = $name.Trim('-')
    if ($name.Length -gt 63) {
        $name = $name.Substring(0, 63).Trim('-')
    }
    return $name
}

function Assert-TailscaleHostname {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    if ($Value -cne $Value.ToLowerInvariant()) {
        throw "Tailscale hostname must be lowercase. Use letters, numbers, and hyphens only."
    }
    if ($Value.Length -gt 63) {
        throw "Tailscale hostname must be 63 characters or less."
    }
    if ($Value -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$') {
        throw "Tailscale hostname can only contain lowercase letters, numbers, and hyphens, and cannot start or end with a hyphen."
    }
}

function Open-TailscaleLoginUrlFromText {
    param(
        [AllowEmptyString()][string]$Text,
        [scriptblock]$Log
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $match = [regex]::Match($Text, 'https://login\.tailscale\.com/[^\s''"]+')
    if (-not $match.Success) {
        $match = [regex]::Match($Text, 'https://[^\\s''"]*tailscale\.com/[^\s''"]+')
    }
    if (-not $match.Success) { return $false }

    $url = $match.Value.TrimEnd('.', ',', ';', ')', ']')
    & $Log "Tailscale login URL detected: $url"
    $answer = [Windows.Forms.MessageBox]::Show(
        "Tailscale needs browser authentication. Open the login page now?`r`n`r`n$url",
        "Tailscale login required",
        "YesNo",
        "Question"
    )
    if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
        Start-Process $url
    }
    return $true
}

function Get-TailscaleLoginUrlFromText {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, 'https://login\.tailscale\.com/[^\s''"]+')
    if (-not $match.Success) {
        $match = [regex]::Match($Text, 'https://[^\s''"]*tailscale\.com/[^\s''"]+')
    }
    if (-not $match.Success) { return $null }
    return $match.Value.TrimEnd('.', ',', ';', ')', ']')
}

function Wait-JetKvmTailscaleOnline {
    param(
        [Parameter(Mandatory)][string]$JetKvmAddress,
        [Parameter(Mandatory)][string]$KeyPath,
        [scriptblock]$Log,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $result = Invoke-JetKvmSshCommand -JetKvmAddress $JetKvmAddress -KeyPath $KeyPath -Command "tailscale status 2>&1; echo '--- ip ---'; tailscale ip -4 2>&1" -TimeoutSeconds 20
        if ($result.Output) { $result.Output -split "`n" | ForEach-Object { & $Log $_ } }
        if ($result.Output -match '\b\d{1,3}(\.\d{1,3}){3}\b' -and $result.Output -notmatch 'NeedsLogin|Logged out|no current Tailscale IPs') {
            return $true
        }
        [Windows.Forms.Application]::DoEvents()
    }
    return $false
}

function Start-JetFuelGui {
    $form = [Windows.Forms.Form]::new()
    $form.Text = "JetFUEL - JetKVM Tailscale Setup"
    $form.Size = [Drawing.Size]::new(940, 960)
    $form.StartPosition = "CenterScreen"
    $form.MinimumSize = [Drawing.Size]::new(840, 760)
    $form.AutoScroll = $true
    $form.BackColor = [Drawing.Color]::FromArgb(248, 250, 252)

    $font = [Drawing.Font]::new("Segoe UI", 9)
    $form.Font = $font

    $title = [Windows.Forms.Label]::new()
    $title.Text = "JetKVM Tailscale setup"
    $title.Font = [Drawing.Font]::new("Segoe UI", 16, [Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = [Drawing.Point]::new(22, 16)
    $form.Controls.Add($title)

    $subtitle = [Windows.Forms.Label]::new()
    $subtitle.Text = "Follow the steps from top to bottom. Use Preflight first to confirm this PC can see the JetKVM."
    $subtitle.AutoSize = $true
    $subtitle.Location = [Drawing.Point]::new(24, 50)
    $form.Controls.Add($subtitle)

    $precheckGroup = [Windows.Forms.GroupBox]::new()
    $precheckGroup.Text = "Step 1 - Prechecks"
    $precheckGroup.Location = [Drawing.Point]::new(22, 84)
    $precheckGroup.Size = [Drawing.Size]::new(780, 140)
    $precheckGroup.BackColor = [Drawing.Color]::White
    $form.Controls.Add($precheckGroup)

    $bashStatus = [Windows.Forms.Label]::new()
    $bashStatus.Text = "[ ] Git Bash: not checked"
    $bashStatus.Location = [Drawing.Point]::new(14, 26)
    $bashStatus.Size = [Drawing.Size]::new(300, 22)
    $precheckGroup.Controls.Add($bashStatus)

    $sshStatus = [Windows.Forms.Label]::new()
    $sshStatus.Text = "[ ] SSH tools: not checked"
    $sshStatus.Location = [Drawing.Point]::new(14, 52)
    $sshStatus.Size = [Drawing.Size]::new(300, 22)
    $precheckGroup.Controls.Add($sshStatus)

    $kvmStatus = [Windows.Forms.Label]::new()
    $kvmStatus.Text = "[ ] JetKVM network: enter IP, then preflight"
    $kvmStatus.Location = [Drawing.Point]::new(330, 26)
    $kvmStatus.Size = [Drawing.Size]::new(300, 22)
    $precheckGroup.Controls.Add($kvmStatus)

    $httpStatus = [Windows.Forms.Label]::new()
    $httpStatus.Text = "[ ] JetKVM web UI: not checked"
    $httpStatus.Location = [Drawing.Point]::new(330, 52)
    $httpStatus.Size = [Drawing.Size]::new(300, 22)
    $precheckGroup.Controls.Add($httpStatus)

    $sshLoginStatus = [Windows.Forms.Label]::new()
    $sshLoginStatus.Text = "[ ] JetKVM SSH login: enable Developer Mode first"
    $sshLoginStatus.Location = [Drawing.Point]::new(14, 80)
    $sshLoginStatus.Size = [Drawing.Size]::new(460, 22)
    $precheckGroup.Controls.Add($sshLoginStatus)

    $preflightButton = [Windows.Forms.Button]::new()
    $preflightButton.Text = "Run preflight"
    $preflightButton.Location = [Drawing.Point]::new(488, 102)
    $preflightButton.Size = [Drawing.Size]::new(150, 28)
    $precheckGroup.Controls.Add($preflightButton)

    $step2Group = [Windows.Forms.GroupBox]::new()
    $step2Group.Text = "Step 2 - JetKVM and SSH"
    $step2Group.Location = [Drawing.Point]::new(22, 234)
    $step2Group.Size = [Drawing.Size]::new(780, 178)
    $step2Group.BackColor = [Drawing.Color]::White
    $form.Controls.Add($step2Group)

    $step3Group = [Windows.Forms.GroupBox]::new()
    $step3Group.Text = "Step 3 - Tailscale options"
    $step3Group.Location = [Drawing.Point]::new(22, 422)
    $step3Group.Size = [Drawing.Size]::new(780, 270)
    $step3Group.BackColor = [Drawing.Color]::White
    $form.Controls.Add($step3Group)

    $y = 26
    function Add-Label([string]$Text, [int]$Top) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = $Text
        $label.Location = [Drawing.Point]::new(14, $Top)
        $label.Size = [Drawing.Size]::new(190, 24)
        $step2Group.Controls.Add($label)
        return $label
    }

    function Add-TextBox([Windows.Forms.Control]$Parent, [int]$Top, [string]$Text = "") {
        $box = [Windows.Forms.TextBox]::new()
        $box.Location = [Drawing.Point]::new(190, $Top)
        $box.Size = [Drawing.Size]::new(450, 24)
        $box.Text = $Text
        $box.SelectionStart = 0
        $Parent.Controls.Add($box)
        return $box
    }

    Add-Label "JetKVM IP or hostname" $y | Out-Null
    $ipBox = Add-TextBox $step2Group $y
    $openUiButton = [Windows.Forms.Button]::new()
    $openUiButton.Text = "Open UI"
    $openUiButton.Location = [Drawing.Point]::new(654, $y - 1)
    $openUiButton.Size = [Drawing.Size]::new(96, 28)
    $step2Group.Controls.Add($openUiButton)

    $y += 38
    Add-Label "SSH private key path" $y | Out-Null
    $defaultKey = Join-Path $HOME ".ssh\id_rsa_jetkvm"
    $keyBox = Add-TextBox $step2Group $y $defaultKey
    $browseButton = [Windows.Forms.Button]::new()
    $browseButton.Text = "Browse"
    $browseButton.Location = [Drawing.Point]::new(654, $y - 1)
    $browseButton.Size = [Drawing.Size]::new(96, 28)
    $step2Group.Controls.Add($browseButton)

    $y += 38
    $createKeyCheck = [Windows.Forms.CheckBox]::new()
    $createKeyCheck.Text = "Create this SSH key if it does not exist"
    $createKeyCheck.Checked = $true
    $createKeyCheck.Location = [Drawing.Point]::new(190, $y)
    $createKeyCheck.Size = [Drawing.Size]::new(280, 24)
    $step2Group.Controls.Add($createKeyCheck)

    $y += 34
    Add-Label "SSH key passphrase" $y | Out-Null
    $passBox = Add-TextBox $step2Group $y
    $passBox.UseSystemPasswordChar = $true
    $noPassCheck = [Windows.Forms.CheckBox]::new()
    $noPassCheck.Text = "No passphrase"
    $noPassCheck.Checked = $true
    $noPassCheck.Location = [Drawing.Point]::new(654, $y)
    $noPassCheck.Size = [Drawing.Size]::new(140, 24)
    $step2Group.Controls.Add($noPassCheck)
    $passBox.Enabled = $false

    $y = 28
    $useAuthKeyCheck = [Windows.Forms.CheckBox]::new()
    $useAuthKeyCheck.Text = "Use a Tailscale auth key to connect automatically"
    $useAuthKeyCheck.Location = [Drawing.Point]::new(190, $y)
    $useAuthKeyCheck.Size = [Drawing.Size]::new(360, 24)
    $step3Group.Controls.Add($useAuthKeyCheck)

    $y += 34
    $authLabel = [Windows.Forms.Label]::new()
    $authLabel.Text = "Tailscale auth key"
    $authLabel.Location = [Drawing.Point]::new(14, $y)
    $authLabel.Size = [Drawing.Size]::new(190, 24)
    $step3Group.Controls.Add($authLabel)
    $authBox = Add-TextBox $step3Group $y
    $authBox.UseSystemPasswordChar = $true
    $authBox.Enabled = $false

    $authHelp = [Windows.Forms.Label]::new()
    $authHelp.Text = "Paste the full tskey-auth-... secret shown when creating the key. The key ID ending CNTRL in the admin table is not enough."
    $authHelp.Location = [Drawing.Point]::new(190, $y + 26)
    $authHelp.Size = [Drawing.Size]::new(540, 40)
    $step3Group.Controls.Add($authHelp)

    $y += 78
    $hostLabel = [Windows.Forms.Label]::new()
    $hostLabel.Text = "Tailscale hostname"
    $hostLabel.Location = [Drawing.Point]::new(14, $y)
    $hostLabel.Size = [Drawing.Size]::new(190, 24)
    $step3Group.Controls.Add($hostLabel)
    $hostBox = Add-TextBox $step3Group $y

    $y += 38
    $versionLabel = [Windows.Forms.Label]::new()
    $versionLabel.Text = "Tailscale version"
    $versionLabel.Location = [Drawing.Point]::new(14, $y)
    $versionLabel.Size = [Drawing.Size]::new(190, 24)
    $step3Group.Controls.Add($versionLabel)
    $versionBox = Add-TextBox $step3Group $y "1.96.4"
    $versionNote = [Windows.Forms.Label]::new()
    $versionNote.Text = "Default is pinned for JetKVM compatibility. Change only if you know the version works on your device."
    $versionNote.Location = [Drawing.Point]::new(190, $y + 26)
    $versionNote.Size = [Drawing.Size]::new(540, 34)
    $step3Group.Controls.Add($versionNote)

    $cleanCheck = [Windows.Forms.CheckBox]::new()
    $cleanCheck.Text = "Clean Tailscale install on JetKVM (creates a new Tailscale machine identity)"
    $cleanCheck.Location = [Drawing.Point]::new(190, 242)
    $cleanCheck.Size = [Drawing.Size]::new(540, 24)
    $step3Group.Controls.Add($cleanCheck)

    $manualSteps = [Windows.Forms.GroupBox]::new()
    $manualSteps.Text = "Step 4 - Required JetKVM UI steps"
    $manualSteps.Location = [Drawing.Point]::new(22, 704)
    $manualSteps.Size = [Drawing.Size]::new(780, 110)
    $manualSteps.BackColor = [Drawing.Color]::White
    $form.Controls.Add($manualSteps)

    $stepsText = [Windows.Forms.Label]::new()
    $stepsText.Text = "1. Open the JetKVM UI, set or confirm the local password if wanted, and install any JetKVM system updates from Settings.`r`n2. In Settings > Advanced, enable Developer Mode and paste the public SSH key.`r`n3. Save the JetKVM settings before running the Tailscale install."
    $stepsText.Location = [Drawing.Point]::new(12, 24)
    $stepsText.Size = [Drawing.Size]::new(590, 76)
    $manualSteps.Controls.Add($stepsText)

    $copyKeyButton = [Windows.Forms.Button]::new()
    $copyKeyButton.Text = "Copy public key"
    $copyKeyButton.Location = [Drawing.Point]::new(622, 28)
    $copyKeyButton.Size = [Drawing.Size]::new(130, 30)
    $manualSteps.Controls.Add($copyKeyButton)

    $openUiButton2 = [Windows.Forms.Button]::new()
    $openUiButton2.Text = "Open JetKVM UI"
    $openUiButton2.Location = [Drawing.Point]::new(622, 64)
    $openUiButton2.Size = [Drawing.Size]::new(130, 30)
    $manualSteps.Controls.Add($openUiButton2)

    $runButton = [Windows.Forms.Button]::new()
    $runButton.Text = "Step 5 - Run install"
    $runButton.Size = [Drawing.Size]::new(150, 34)
    $form.Controls.Add($runButton)

    $logBox = [Windows.Forms.RichTextBox]::new()
    $logBox.Multiline = $true
    $logBox.ScrollBars = "Vertical"
    $logBox.ReadOnly = $true
    $logBox.BorderStyle = "FixedSingle"
    $logBox.BackColor = [Drawing.Color]::FromArgb(253, 253, 253)
    $logBox.Font = [Drawing.Font]::new("Consolas", 9)
    $logBox.Location = [Drawing.Point]::new(770, 118)
    $logBox.Size = [Drawing.Size]::new(360, 560)
    $logBox.Anchor = "None"
    $form.Controls.Add($logBox)

    $logTitle = [Windows.Forms.Label]::new()
    $logTitle.Text = "Status log"
    $logTitle.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $logTitle.Location = [Drawing.Point]::new(770, 88)
    $logTitle.Size = [Drawing.Size]::new(160, 24)
    $form.Controls.Add($logTitle)

    $statusLabel = [Windows.Forms.Label]::new()
    $statusLabel.Text = "Ready"
    $statusLabel.Size = [Drawing.Size]::new(220, 24)
    $form.Controls.Add($statusLabel)

    $layoutControls = {
        $clientWidth = $form.ClientSize.Width
        $clientHeight = $form.ClientSize.Height
        $margin = 22
        $availableWidth = $clientWidth - ($margin * 2) - 18
        $groupWidth = [Math]::Min(920, [Math]::Max(760, $availableWidth))
        $top = 120

        $precheckGroup.SetBounds($margin, $top, $groupWidth, 140)
        $step2Group.SetBounds($margin, $precheckGroup.Bottom + 12, $groupWidth, 178)
        $step3Group.SetBounds($margin, $step2Group.Bottom + 12, $groupWidth, 270)
        $manualSteps.SetBounds($margin, $step3Group.Bottom + 12, $groupWidth, 110)
        $runButton.SetBounds($margin + $groupWidth - $runButton.Width, $manualSteps.Bottom + 14, $runButton.Width, $runButton.Height)
        $statusLabel.SetBounds($margin, $runButton.Top + 8, [Math]::Max(240, $groupWidth - $runButton.Width - 20), 24)
        $logTitle.SetBounds($margin, $runButton.Bottom + 18, 160, 24)

        $logTop = $logTitle.Bottom + 6
        $logHeight = [Math]::Max(180, $clientHeight - $logTop - $margin)
        $logBox.SetBounds($margin, $logTop, $groupWidth, $logHeight)

        foreach ($group in @($precheckGroup, $step2Group, $step3Group, $manualSteps)) {
            $group.Width = $groupWidth
        }

        $labelWidth = 170
        $fieldX = 150
        $fieldWidth = [Math]::Min(540, [Math]::Max(360, $groupWidth - $fieldX - 160))
        foreach ($box in @($ipBox, $keyBox, $passBox, $authBox, $hostBox, $versionBox)) {
            $box.Left = $fieldX
            $box.Width = $fieldWidth
        }
        foreach ($label in @($authLabel, $hostLabel, $versionLabel)) {
            $label.Width = $labelWidth
        }
        foreach ($button in @($openUiButton, $browseButton)) {
            $button.Left = $fieldX + $fieldWidth + 14
        }
        $noPassCheck.Left = $fieldX + $fieldWidth + 14
        $createKeyCheck.Left = $fieldX
        $useAuthKeyCheck.Left = $fieldX
        $authHelp.Left = $fieldX
        $authHelp.Width = $groupWidth - $fieldX - 24
        $versionNote.Left = $fieldX
        $versionNote.Width = $groupWidth - $fieldX - 24
        $cleanCheck.Left = $fieldX
        $cleanCheck.Width = $groupWidth - $fieldX - 24
        $copyKeyButton.Left = $groupWidth - 158
        $openUiButton2.Left = $groupWidth - 158
        $stepsText.Width = $groupWidth - 210

        $form.AutoScrollMinSize = [Drawing.Size]::new($clientWidth - 1, $logBox.Bottom + $margin)
    }

    $form.Add_Shown({ & $layoutControls })
    $form.Add_Resize({ & $layoutControls })
    $form.Add_Shown({
        foreach ($box in @($ipBox, $keyBox, $passBox, $authBox, $hostBox, $versionBox)) {
            $box.SelectionStart = 0
            $box.SelectionLength = 0
        }
    })

    $log = {
        param([string]$Message)
        $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
        $colour = $ui.Text
        if ($Message -match '^(ERROR|FAIL)|\bfailed\b|not found|not reachable|cancelled|invalid|authentication failed|permission denied|timed out|Timeout|rejected') {
            $colour = $ui.Bad
        } elseif ($Message -match '^(Warning|WARN)|NeedsLogin|Logged out|no current Tailscale IPs|not confirmed|did not receive|Continuing may still work|manual login|repair') {
            $colour = $ui.Warn
        } elseif ($Message -match 'https?://|login\.tailscale\.com') {
            $colour = $ui.Info
        } elseif ($Message -match '^---|\[[0-9]+/[0-9]+\]|Checking|Using|Downloading|Installing|Configuring|Starting') {
            $colour = $ui.Purple
        } elseif ($Message -match 'OK|confirmed|reachable|complete|found|available|copied|responded|SUCCESS|online|100\.[0-9]+\.[0-9]+\.[0-9]+') {
            $colour = $ui.Good
        }

        $append = {
            param([string]$m, [Drawing.Color]$c)
            $logBox.SelectionStart = $logBox.TextLength
            $logBox.SelectionLength = 0
            $logBox.SelectionColor = $c
            $logBox.AppendText($m + [Environment]::NewLine)
            $logBox.SelectionColor = $logBox.ForeColor
            $logBox.ScrollToCaret()
        }

        if ($logBox.InvokeRequired) {
            $logBox.Invoke([Action[string, System.Drawing.Color]]$append, $line, $colour) | Out-Null
        } else {
            & $append $line $colour
        }
        [Windows.Forms.Application]::DoEvents()
    }

    $setBusy = {
        param([bool]$Busy, [string]$Status)
        $runButton.Enabled = -not $Busy
        $preflightButton.Enabled = -not $Busy
        $checkTailscaleButton.Enabled = -not $Busy
        $repairTailscaleButton.Enabled = -not $Busy
        $statusLabel.Text = $Status
        [Windows.Forms.Application]::DoEvents()
    }

    $setIndicator = {
        param(
            [Windows.Forms.Label]$Label,
            [ValidateSet("Pending", "OK", "Warn", "Fail")][string]$State,
            [string]$Text
        )

        switch ($State) {
            "OK" {
                $Label.Text = "[OK] $Text"
                $Label.ForeColor = [Drawing.Color]::ForestGreen
            }
            "Warn" {
                $Label.Text = "[WARN] $Text"
                $Label.ForeColor = [Drawing.Color]::DarkOrange
            }
            "Fail" {
                $Label.Text = "[FAIL] $Text"
                $Label.ForeColor = [Drawing.Color]::Firebrick
            }
            default {
                $Label.Text = "[ ] $Text"
                $Label.ForeColor = [Drawing.Color]::Black
            }
        }
        [Windows.Forms.Application]::DoEvents()
    }

    $noPassCheck.Add_CheckedChanged({
        $passBox.Enabled = -not $noPassCheck.Checked
        if ($noPassCheck.Checked) { $passBox.Text = "" }
    })

    $useAuthKeyCheck.Add_CheckedChanged({
        $authBox.Enabled = $useAuthKeyCheck.Checked
        if (-not $useAuthKeyCheck.Checked) { $authBox.Text = "" }
    })
    $normalisingHost = $false
    $hostBox.Add_TextChanged({
        if ($normalisingHost) { return }
        $current = $hostBox.Text
        $clean = ConvertTo-TailscaleHostname -Value $current
        if ($current -cne $clean) {
            $normalisingHost = $true
            $cursor = [Math]::Min($hostBox.SelectionStart, $clean.Length)
            $hostBox.Text = $clean
            $hostBox.SelectionStart = $cursor
            $normalisingHost = $false
        }
    })

    $browseButton.Add_Click({
        $dialog = [Windows.Forms.SaveFileDialog]::new()
        $dialog.Title = "Choose SSH private key path"
        $dialog.FileName = [IO.Path]::GetFileName($keyBox.Text)
        $dialog.InitialDirectory = Split-Path -Parent $keyBox.Text
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            $keyBox.Text = $dialog.FileName
        }
    })

    $openAction = {
        try { Open-JetKvmUi -JetKvmAddress $ipBox.Text }
        catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null }
    }
    $openUiButton.Add_Click($openAction)
    $openUiButton2.Add_Click($openAction)

    $copyKeyButton.Add_Click({
        try {
            $keyPath = $keyBox.Text.Trim()
            if ($createKeyCheck.Checked -and -not (Test-Path -LiteralPath "$keyPath.pub")) {
                $passphrase = if ($noPassCheck.Checked) { "" } else { $passBox.Text }
                New-SshKeyPair -KeyPath $keyPath -Passphrase $passphrase -Log $log
            }
            $pub = Get-PublicKeyText -KeyPath $keyPath
            [Windows.Forms.Clipboard]::SetText($pub)
            & $log "Public key copied to clipboard. Paste it into JetKVM Settings > Advanced > Developer Mode."
        } catch {
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $doPreflight = {
        param([bool]$Install)
        try {
            & $setBusy $true "Working..."
            $ip = $ipBox.Text.Trim()
            Assert-ValidIpOrHost -Value $ip

            & $log "Checking Windows prerequisites..."
            $wingetState = Test-WingetAvailable
            if ($wingetState.Ok) {
                & $log $wingetState.Message
            } else {
                & $log ("Warning: " + $wingetState.Message)
            }

            $bashInfo = Select-BashForInstall -Log $log
            $bash = $bashInfo.Path
            $bashKind = $bashInfo.Kind
            & $log "Using $bashKind bash: $bash"
            & $setIndicator $bashStatus "OK" "$bashKind bash selected"

            $ssh = Get-CommandPath -Name "ssh.exe"
            if (-not $ssh) { $ssh = Get-CommandPath -Name "ssh" }
            if (-not $ssh) { throw "OpenSSH client was not found. Enable Windows OpenSSH Client and try again." }
            & $log "Using ssh: $ssh"
            & $setIndicator $sshStatus "OK" "SSH tools found"

            $keyPath = $keyBox.Text.Trim()
            if ($createKeyCheck.Checked -and -not (Test-Path -LiteralPath "$keyPath.pub")) {
                $passphrase = if ($noPassCheck.Checked) { "" } else { $passBox.Text }
                New-SshKeyPair -KeyPath $keyPath -Passphrase $passphrase -Log $log
            }
            $null = Get-PublicKeyText -KeyPath $keyPath
            & $log "SSH public key is available: $keyPath.pub"

            if (-not (Test-Connection -ComputerName $ip -Count 1 -Quiet)) {
                & $log "Warning: Windows ping did not receive a reply from $ip. Continuing may still work if ICMP is blocked."
                & $setIndicator $kvmStatus "Warn" "Ping did not reply"
            } else {
                & $log "JetKVM responded to ping."
                & $setIndicator $kvmStatus "OK" "JetKVM answered ping"
            }

            if (Test-JetKvmWebUi -JetKvmAddress $ip) {
                & $log "JetKVM web UI port is reachable."
                & $setIndicator $httpStatus "OK" "Web UI reachable"
            } else {
                & $log "Warning: JetKVM web UI port 80 was not reachable from this PC."
                & $setIndicator $httpStatus "Warn" "Web UI not reachable"
            }

            $sshLogin = Test-JetKvmSshLogin -JetKvmAddress $ip -KeyPath $keyPath
            if ($sshLogin.Ok) {
                & $log "JetKVM SSH login confirmed with the selected key."
                & $setIndicator $sshLoginStatus "OK" "JetKVM SSH login confirmed"
            } else {
                & $log ("JetKVM SSH login not confirmed: " + $sshLogin.Message)
                & $setIndicator $sshLoginStatus "Warn" "SSH login not confirmed"
            }

            if (-not $Install) {
                & $log "Preflight complete. Finish the JetKVM UI steps, then run setup."
                & $setBusy $false "Preflight complete"
                return
            }

            $authKey = if ($useAuthKeyCheck.Checked) { $authBox.Text.Trim() } else { "" }
            if ($useAuthKeyCheck.Checked -and [string]::IsNullOrWhiteSpace($authKey)) {
                throw "Tailscale auth key is enabled but empty. Paste a key that usually starts with tskey-auth-, or untick the auth key box."
            }
            if ($useAuthKeyCheck.Checked) {
                Assert-TailscaleAuthKeyLooksUsable -AuthKey $authKey
            }
            if ($useAuthKeyCheck.Checked -and $authKey -notmatch '^tskey-auth-') {
                $answer = [Windows.Forms.MessageBox]::Show(
                    "This does not look like a Tailscale auth key. Auth keys usually start with tskey-auth-. Continue anyway?",
                    "JetFUEL",
                    "YesNo",
                    "Warning"
                )
                if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                    throw "Install cancelled so the auth key can be checked."
                }
            }

            Invoke-JetKvmTailscaleInstall `
                -BashPath $bash `
                -BashKind $bashKind `
                -JetKvmAddress $ip `
                -KeyPath $keyPath `
                -TailscaleVersion $versionBox.Text.Trim() `
                -AuthKey $authKey `
                -Hostname $hostBox.Text.Trim() `
                -CleanInstall:($cleanCheck.Checked) `
                -Log $log `
                -LoginUrlHandler {
                    param($url)
                    & $log "Opening Tailscale login URL: $url"
                    Start-Process $url
                    & $setBusy $true "Waiting for browser login..."
                    if (Wait-JetKvmTailscaleOnline -JetKvmAddress $ip -KeyPath $keyPath -Log $log -TimeoutSeconds 180) {
                        & $setBusy $false "Tailscale online"
                    } else {
                        & $setBusy $false "Login wait timed out"
                        throw "Timed out waiting for Tailscale login to complete. Complete the browser login, then click Check Tailscale."
                    }
                }

            & $log "Setup complete. Confirm the new device in the Tailscale admin console."
            & $setBusy $false "Complete"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            if ($_.Exception.Message -match "bash|Git") { & $setIndicator $bashStatus "Fail" "Git Bash problem" }
            if ($_.Exception.Message -match "ssh-keygen") { & $setIndicator $sshStatus "Fail" "SSH key creation failed" }
            elseif ($_.Exception.Message -match "SSH|ssh") { & $setIndicator $sshLoginStatus "Fail" "JetKVM SSH login failed" }
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    }

    $preflightButton.Add_Click({ & $doPreflight $false })
    $runButton.Add_Click({ & $doPreflight $true })

    if (-not (Test-IsAdministrator)) {
        & $log "Running without administrator rights. Git installation via winget may still work per-user; otherwise install Git manually."
    }
    & $log "Use Copy public key, enable Developer Mode in JetKVM, then run setup."

    [void]$form.ShowDialog()
}

function Start-JetFuelGuiV2 {
    function New-UiColor([int]$R, [int]$G, [int]$B) {
        return [Drawing.Color]::FromArgb($R, $G, $B)
    }

    $uiScale = Get-UiScale
    # Scales design-time pixel values to the monitor DPI so the layout and the
    # DPI-scaled fonts grow together instead of clipping each other.
    function S([double]$Value) {
        return [int][Math]::Round($Value * $uiScale)
    }
    function New-ScaledPadding([int]$Left, [int]$Top, [int]$Right, [int]$Bottom) {
        return [Windows.Forms.Padding]::new((S $Left), (S $Top), (S $Right), (S $Bottom))
    }

    $ui = @{
        Window = New-UiColor 15 23 42
        Surface = New-UiColor 30 41 59
        Surface2 = New-UiColor 17 24 39
        Border = New-UiColor 71 85 105
        Text = New-UiColor 226 232 240
        Muted = New-UiColor 148 163 184
        Input = New-UiColor 241 245 249
        InputText = New-UiColor 15 23 42
        Accent = New-UiColor 37 99 235
        AccentHover = New-UiColor 29 78 216
        Good = New-UiColor 34 197 94
        Warn = New-UiColor 245 158 11
        Bad = New-UiColor 239 68 68
        Info = New-UiColor 56 189 248
        Purple = New-UiColor 167 139 250
        Log = New-UiColor 2 6 23
    }

    $form = [Windows.Forms.Form]::new()
    $form.Text = "JetFUEL - JetKVM Tailscale Setup"
    $form.StartPosition = "CenterScreen"
    $form.Size = [Drawing.Size]::new((S 1080), (S 820))
    $form.MinimumSize = [Drawing.Size]::new((S 760), (S 560))
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
    $form.Font = [Drawing.Font]::new("Segoe UI", 8.5)
    $form.BackColor = $ui.Window

    $split = [Windows.Forms.SplitContainer]::new()
    $split.Dock = "Fill"
    $split.Orientation = [Windows.Forms.Orientation]::Horizontal
    $split.SplitterWidth = [Math]::Max(4, (S 7))
    $split.Panel1MinSize = S 300
    $split.Panel2MinSize = S 110
    $split.FixedPanel = [Windows.Forms.FixedPanel]::Panel2
    $split.BackColor = $ui.Border
    $form.Controls.Add($split)
    $setInitialSplitterDistance = {
        try {
            $maxDistance = $split.Height - $split.Panel2MinSize - $split.SplitterWidth
            if ($maxDistance -le $split.Panel1MinSize) { return }
            $targetLogHeight = [Math]::Min((S 220), [Math]::Max((S 120), [Math]::Round($split.Height * 0.26)))
            $targetDistance = $split.Height - $targetLogHeight - $split.SplitterWidth
            $split.SplitterDistance = [Math]::Min($maxDistance, [Math]::Max($split.Panel1MinSize, $targetDistance))
        } catch {}
    }
    $clampSplitterDistance = {
        try {
            $maxDistance = $split.Height - $split.Panel2MinSize - $split.SplitterWidth
            if ($maxDistance -lt $split.Panel1MinSize) { return }
            if ($split.SplitterDistance -gt $maxDistance) {
                $split.SplitterDistance = $maxDistance
            } elseif ($split.SplitterDistance -lt $split.Panel1MinSize) {
                $split.SplitterDistance = $split.Panel1MinSize
            }
        } catch {}
    }
    $split.Add_Resize({ & $clampSplitterDistance })
    $form.Add_Shown({
        & $setInitialSplitterDistance
    })

    $main = [Windows.Forms.TableLayoutPanel]::new()
    $main.Dock = "Fill"
    $main.Padding = [Windows.Forms.Padding]::new((S 12))
    $main.ColumnCount = 1
    $main.RowCount = 2
    $main.AutoScroll = $false
    $main.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $main.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S 62))) | Out-Null
    $main.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $split.Panel1.Controls.Add($main)

    $header = [Windows.Forms.Panel]::new()
    $header.Dock = "Fill"
    $header.BackColor = $ui.Surface2
    $header.Padding = New-ScaledPadding 14 8 14 8
    $iconPath = Join-Path (Get-JetFuelScriptRoot) "assets\icon.ico"
    $logoPath = Join-Path (Get-JetFuelScriptRoot) "assets\icon.png"
    if (Test-Path -LiteralPath $iconPath) {
        try {
            $form.Icon = [Drawing.Icon]::new($iconPath)
        } catch {}
    }
    if (Test-Path -LiteralPath $logoPath) {
        try {
            $logo = [Windows.Forms.PictureBox]::new()
            $logo.Size = [Drawing.Size]::new((S 38), (S 38))
            $logo.Location = [Drawing.Point]::new((S 14), (S 12))
            $logo.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
            $logo.Image = [Drawing.Image]::FromFile($logoPath)
            $header.Controls.Add($logo)
        } catch {}
    }
    $title = [Windows.Forms.Label]::new()
    $title.Text = "JetKVM Tailscale setup"
    $title.Font = [Drawing.Font]::new("Segoe UI", 14, [Drawing.FontStyle]::Bold)
    $title.ForeColor = $ui.Text
    $title.AutoSize = $true
    $title.Location = [Drawing.Point]::new((S 62), (S 9))
    $subtitle = [Windows.Forms.Label]::new()
    $subtitle.Text = "Enter the deployment details, run preflight, enable Developer Mode SSH, then install."
    $subtitle.AutoSize = $true
    $subtitle.ForeColor = $ui.Muted
    $subtitle.Location = [Drawing.Point]::new((S 64), (S 36))
    $header.Controls.AddRange(@($title, $subtitle))
    $main.Controls.Add($header, 0, 0)

    function New-Group([string]$Text) {
        $group = [Windows.Forms.GroupBox]::new()
        $group.Text = $Text
        $group.Dock = "Fill"
        $group.BackColor = $ui.Surface
        $group.ForeColor = $ui.Text
        $group.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
        $group.Padding = New-ScaledPadding 10 8 10 8
        $group.Margin = New-ScaledPadding 0 5 0 0
        return $group
    }

    function New-StepGrid([int]$Rows) {
        $grid = [Windows.Forms.TableLayoutPanel]::new()
        $grid.Dock = "Top"
        $grid.AutoSize = $true
        $grid.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
        $grid.ColumnCount = 3
        $grid.RowCount = $Rows
        $grid.Padding = New-ScaledPadding 4 9 4 3
        $grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 165))) | Out-Null
        $grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
        $grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 132))) | Out-Null
        for ($i = 0; $i -lt $Rows; $i++) {
            $grid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S 32))) | Out-Null
        }
        return $grid
    }

    function New-Field([string]$Text) {
        $box = [Windows.Forms.TextBox]::new()
        $box.Text = $Text
        $box.Dock = "Fill"
        $box.Margin = New-ScaledPadding 0 2 8 2
        $box.BorderStyle = "FixedSingle"
        $box.BackColor = $ui.Input
        $box.ForeColor = $ui.InputText
        $box.Font = [Drawing.Font]::new("Segoe UI", 9)
        $box.SelectionStart = 0
        return $box
    }

    function New-RowLabel([string]$Text) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = $Text
        $label.Dock = "Fill"
        $label.TextAlign = "MiddleLeft"
        $label.Margin = New-ScaledPadding 0 0 8 0
        $label.ForeColor = $ui.Text
        $label.Font = [Drawing.Font]::new("Segoe UI", 9)
        return $label
    }

    function Set-ButtonStyle([Windows.Forms.Button]$Button, [string]$Kind = "Secondary") {
        $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
        $Button.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
        $Button.Cursor = [Windows.Forms.Cursors]::Hand
        $Button.UseVisualStyleBackColor = $false
        $Button.AutoSize = $false
        $Button.AutoEllipsis = $true
        $Button.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
        $Button.FlatAppearance.BorderSize = 1
        if ($Kind -eq "Primary") {
            $Button.BackColor = $ui.Accent
            $Button.ForeColor = [Drawing.Color]::White
            $Button.FlatAppearance.BorderColor = $ui.AccentHover
        } elseif ($Kind -eq "Danger") {
            $Button.BackColor = $ui.Bad
            $Button.ForeColor = [Drawing.Color]::White
            $Button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(248, 113, 113)
        } else {
            $Button.BackColor = $ui.Surface2
            $Button.ForeColor = $ui.Text
            $Button.FlatAppearance.BorderColor = $ui.Border
        }
    }

    $exitButton = [Windows.Forms.Button]::new()
    $exitButton.Text = "EXIT"
    $exitButton.Size = [Drawing.Size]::new((S 112), (S 34))
    $exitButton.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
    Set-ButtonStyle $exitButton "Danger"
    $header.Controls.Add($exitButton)
    $positionExitButton = {
        $exitButton.SetBounds(
            [Math]::Max((S 260), $header.ClientSize.Width - $exitButton.Width - (S 14)),
            (S 14),
            $exitButton.Width,
            $exitButton.Height
        )
    }
    $header.Add_Resize({ & $positionExitButton })
    & $positionExitButton

    function Set-CheckStyle([Windows.Forms.CheckBox]$CheckBox) {
        $CheckBox.ForeColor = $ui.Text
        $CheckBox.Font = [Drawing.Font]::new("Segoe UI", 9)
        $CheckBox.BackColor = $ui.Surface
        $CheckBox.Margin = New-ScaledPadding 0 1 8 1
    }

    function New-Option([string]$Label, [object]$Value) {
        return [pscustomobject]@{
            Label = $Label
            Value = $Value
        }
    }

    function New-OptionBox([object[]]$Options, [object]$SelectedValue = $null) {
        $box = [Windows.Forms.ComboBox]::new()
        $box.Dock = "Fill"
        $box.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
        $box.Margin = New-ScaledPadding 0 2 8 2
        $box.BackColor = $ui.Input
        $box.ForeColor = $ui.InputText
        $box.Font = [Drawing.Font]::new("Segoe UI", 9)
        $box.DisplayMember = "Label"
        foreach ($option in $Options) { [void]$box.Items.Add($option) }
        if ($box.Items.Count -gt 0) {
            $box.SelectedIndex = 0
            if ($null -ne $SelectedValue) {
                for ($i = 0; $i -lt $box.Items.Count; $i++) {
                    if ([string]$box.Items[$i].Value -eq [string]$SelectedValue) {
                        $box.SelectedIndex = $i
                        break
                    }
                }
            }
        }
        return $box
    }

    function Get-SelectedOptionValue([Windows.Forms.ComboBox]$Box) {
        if (-not $Box.SelectedItem) { return $null }
        return $Box.SelectedItem.Value
    }

    $pageShell = [Windows.Forms.TableLayoutPanel]::new()
    $pageShell.Dock = "Fill"
    $pageShell.BackColor = $ui.Window
    $pageShell.Margin = New-ScaledPadding 0 7 0 7
    $pageShell.ColumnCount = 1
    $pageShell.RowCount = 2
    $pageShell.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $pageShell.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S 34))) | Out-Null
    $pageShell.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null

    $navPanel = [Windows.Forms.TableLayoutPanel]::new()
    $navPanel.Dock = "Fill"
    $navPanel.BackColor = $ui.Window
    $navPanel.ColumnCount = 10
    $navPanel.RowCount = 1
    foreach ($width in @(72, 72, 72, 68, 86, 110, 74, 60, 82)) {
        $navPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S $width))) | Out-Null
    }
    $navPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null

    $setupTabButton = [Windows.Forms.Button]::new()
    $setupTabButton.Text = "Setup"
    $setupTabButton.Dock = "Fill"
    $setupTabButton.Margin = New-ScaledPadding 0 0 4 0
    $desktopTabButton = [Windows.Forms.Button]::new()
    $desktopTabButton.Text = "Web UI"
    $desktopTabButton.Dock = "Fill"
    $desktopTabButton.Margin = New-ScaledPadding 0 0 4 0
    $tailscaleTabButton = [Windows.Forms.Button]::new()
    $tailscaleTabButton.Text = "Tailscale"
    $tailscaleTabButton.Dock = "Fill"
    $tailscaleTabButton.Margin = New-ScaledPadding 0 0 4 0
    $identityTabButton = [Windows.Forms.Button]::new()
    $identityTabButton.Text = "Identity"
    $identityTabButton.Dock = "Fill"
    $identityTabButton.Margin = New-ScaledPadding 0 0 4 0
    $diagnosticsTabButton = [Windows.Forms.Button]::new()
    $diagnosticsTabButton.Text = "Diagnostics"
    $diagnosticsTabButton.Dock = "Fill"
    $diagnosticsTabButton.Margin = New-ScaledPadding 0 0 4 0
    $biosTabButton = [Windows.Forms.Button]::new()
    $biosTabButton.Text = "BIOS - WARNING"
    $biosTabButton.Dock = "Fill"
    $biosTabButton.Margin = New-ScaledPadding 0 0 4 0
    $settingsTabButton = [Windows.Forms.Button]::new()
    $settingsTabButton.Text = "Settings"
    $settingsTabButton.Dock = "Fill"
    $settingsTabButton.Margin = New-ScaledPadding 0 0 4 0
    $helpTabButton = [Windows.Forms.Button]::new()
    $helpTabButton.Text = "Help"
    $helpTabButton.Dock = "Fill"
    $helpTabButton.Margin = New-ScaledPadding 0 0 4 0
    $inventoryTabButton = [Windows.Forms.Button]::new()
    $inventoryTabButton.Text = "Inventory"
    $inventoryTabButton.Dock = "Fill"
    $inventoryTabButton.Margin = New-ScaledPadding 0 0 4 0
    Set-ButtonStyle $setupTabButton "Primary"
    Set-ButtonStyle $desktopTabButton "Secondary"
    Set-ButtonStyle $tailscaleTabButton "Secondary"
    Set-ButtonStyle $identityTabButton "Secondary"
    Set-ButtonStyle $diagnosticsTabButton "Secondary"
    Set-ButtonStyle $biosTabButton "Danger"
    Set-ButtonStyle $settingsTabButton "Secondary"
    Set-ButtonStyle $helpTabButton "Secondary"
    Set-ButtonStyle $inventoryTabButton "Secondary"
    $navPanel.Controls.Add($setupTabButton, 0, 0)
    $navPanel.Controls.Add($desktopTabButton, 1, 0)
    $navPanel.Controls.Add($tailscaleTabButton, 2, 0)
    $navPanel.Controls.Add($identityTabButton, 3, 0)
    $navPanel.Controls.Add($diagnosticsTabButton, 4, 0)
    $navPanel.Controls.Add($biosTabButton, 5, 0)
    $navPanel.Controls.Add($settingsTabButton, 6, 0)
    $navPanel.Controls.Add($helpTabButton, 7, 0)
    $navPanel.Controls.Add($inventoryTabButton, 8, 0)

    $pageHost = [Windows.Forms.Panel]::new()
    $pageHost.Dock = "Fill"
    $pageHost.BackColor = $ui.Window

    $setupPage = [Windows.Forms.Panel]::new()
    $setupPage.Dock = "Fill"
    $setupPage.BackColor = $ui.Window
    $setupPage.AutoScroll = $true
    $desktopPage = [Windows.Forms.Panel]::new()
    $desktopPage.Dock = "Fill"
    $desktopPage.BackColor = $ui.Window
    $desktopPage.AutoScroll = $false
    $tailscalePage = [Windows.Forms.Panel]::new()
    $tailscalePage.Dock = "Fill"
    $tailscalePage.BackColor = $ui.Window
    $identityPage = [Windows.Forms.Panel]::new()
    $identityPage.Dock = "Fill"
    $identityPage.BackColor = $ui.Window
    $identityPage.AutoScroll = $true
    $diagnosticsPage = [Windows.Forms.Panel]::new()
    $diagnosticsPage.Dock = "Fill"
    $diagnosticsPage.BackColor = $ui.Window
    $diagnosticsPage.AutoScroll = $true
    $biosPage = [Windows.Forms.Panel]::new()
    $biosPage.Dock = "Fill"
    $biosPage.BackColor = $ui.Window
    $biosPage.AutoScroll = $true
    $settingsPage = [Windows.Forms.Panel]::new()
    $settingsPage.Dock = "Fill"
    $settingsPage.BackColor = $ui.Window
    $settingsPage.AutoScroll = $true
    $helpPage = [Windows.Forms.Panel]::new()
    $helpPage.Dock = "Fill"
    $helpPage.BackColor = $ui.Window
    $inventoryPage = [Windows.Forms.Panel]::new()
    $inventoryPage.Dock = "Fill"
    $inventoryPage.BackColor = $ui.Window
    $inventoryPage.AutoScroll = $true

    $setupLayout = [Windows.Forms.TableLayoutPanel]::new()
    $setupLayout.Dock = "Top"
    $setupLayout.AutoSize = $true
    $setupLayout.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $setupLayout.AutoScroll = $false
    $setupLayout.BackColor = $ui.Window
    $setupLayout.ColumnCount = 1
    $setupLayout.RowCount = 4
    $setupLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    # The setup sections size themselves to their content; only the action row is fixed.
    for ($i = 0; $i -lt 3; $i++) {
        $setupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    }
    $setupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S 42))) | Out-Null
    $setupPage.Controls.Add($setupLayout)

    # Groups in the setup column grow to fit their grids instead of using fixed
    # heights, so rows are never clipped when fonts or DPI change.
    $makeGroupAutoHeight = {
        param([Windows.Forms.GroupBox]$Group)
        $Group.Dock = "Top"
        $Group.AutoSize = $true
        $Group.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    }

    $tailscaleLayout = [Windows.Forms.TableLayoutPanel]::new()
    $tailscaleLayout.Dock = "Top"
    $tailscaleLayout.AutoSize = $true
    $tailscaleLayout.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $tailscaleLayout.BackColor = $ui.Window
    $tailscaleLayout.ColumnCount = 1
    $tailscaleLayout.RowCount = 2
    $tailscaleLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $tailscaleLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S 76))) | Out-Null
    $tailscaleLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    $tailscalePage.Controls.Add($tailscaleLayout)

    $desktopLayout = [Windows.Forms.TableLayoutPanel]::new()
    $desktopLayout.Dock = "Fill"
    $desktopLayout.AutoSize = $false
    $desktopLayout.BackColor = $ui.Window
    $desktopLayout.ColumnCount = 1
    $desktopLayout.RowCount = 2
    $desktopLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $desktopLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S 112))) | Out-Null
    $desktopLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $desktopPage.Controls.Add($desktopLayout)

    $settingsLayout = [Windows.Forms.TableLayoutPanel]::new()
    $settingsLayout.Dock = "Top"
    $settingsLayout.AutoSize = $true
    $settingsLayout.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $settingsLayout.BackColor = $ui.Window
    $settingsLayout.ColumnCount = 1
    $settingsLayout.RowCount = 2
    $settingsLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $settingsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    $settingsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    $settingsPage.Controls.Add($settingsLayout)

    $identityLayout = [Windows.Forms.TableLayoutPanel]::new()
    $identityLayout.Dock = "Top"
    $identityLayout.AutoSize = $true
    $identityLayout.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $identityLayout.BackColor = $ui.Window
    $identityLayout.ColumnCount = 1
    $identityLayout.RowCount = 3
    $identityLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $identityLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    $identityLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    $identityLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    $identityPage.Controls.Add($identityLayout)

    $diagnosticsLayout = [Windows.Forms.TableLayoutPanel]::new()
    $diagnosticsLayout.Dock = "Top"
    $diagnosticsLayout.AutoSize = $true
    $diagnosticsLayout.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $diagnosticsLayout.BackColor = $ui.Window
    $diagnosticsLayout.ColumnCount = 1
    $diagnosticsLayout.RowCount = 3
    $diagnosticsLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    for ($i = 0; $i -lt 3; $i++) {
        $diagnosticsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    }
    $diagnosticsPage.Controls.Add($diagnosticsLayout)

    $biosLayout = [Windows.Forms.TableLayoutPanel]::new()
    $biosLayout.Dock = "Top"
    $biosLayout.AutoSize = $true
    $biosLayout.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $biosLayout.BackColor = $ui.Window
    $biosLayout.ColumnCount = 1
    $biosLayout.RowCount = 4
    $biosLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    for ($i = 0; $i -lt 4; $i++) {
        $biosLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    }
    $biosPage.Controls.Add($biosLayout)

    $helpBox = [Windows.Forms.RichTextBox]::new()
    $helpBox.Dock = "Fill"
    $helpBox.ReadOnly = $true
    $helpBox.BorderStyle = "FixedSingle"
    $helpBox.BackColor = $ui.Surface
    $helpBox.ForeColor = $ui.Text
    $helpBox.Font = [Drawing.Font]::new("Segoe UI", 10)
    $helpBox.Text = @"
JetFUEL help

Use the tabs from left to right.

Setup tab
- This is the main guided workflow for installing Tailscale on a JetKVM.
- The commonly used deployment fields are kept together so a normal install does not require scrolling between separate input sections.
- Complete sections 1 through 3, then run section 4.

1 - Deployment details
- Enter the JetKVM IP address or hostname.
- Optionally set the Tailscale device name and provide a full tskey-auth- pre-authentication secret for automatic enrolment.
- Choose the SSH private key path used by the wizard.
- If the key does not exist, the wizard can create it.
- Choose whether the SSH key has no passphrase or a passphrase.
- Select the installer source and whether to perform a clean Tailscale install.
- Hover over a field for concise guidance; Settings contains advanced installer-source details.
- Install script selects which installer section 4 uses:
  - Official JetKVM: downloads JetKVM's current hosted installer script.
  - JetFUEL repo: uses the local copied reference/fallback script stored with this wizard.
  - Custom URL: downloads a custom compatible installer URL from Settings.
  - Local file: uses a custom compatible installer file path from Settings.
- Clean Tailscale install removes the old Tailscale identity on the JetKVM and creates a new machine identity.

2 - Preflight checks
- Checks that this Windows PC has Git Bash, winget, and SSH tools available.
- Checks whether the JetKVM responds on the network and whether the web UI is reachable.
- Checks SSH login after you enable Developer Mode and add the public SSH key.

3 - Developer Mode SSH required
- Developer Mode SSH must be enabled before the install can run.
- Copy public key copies the SSH public key to your clipboard.
- Paste that key into JetKVM Settings > Advanced > Developer Mode, then save the JetKVM settings.
- After Tailscale is online, you can remove the SSH public key or disable Developer Mode again if you do not need SSH access.

4 - Install Tailscale
- Runs preflight checks, downloads or loads the selected installer script, patches SSH handling for the chosen key, and starts the install.
- The JetKVM will reboot during installation.
- If no auth key is supplied, the wizard will look for a Tailscale browser login URL and wait for login to complete.

Exit / cleanup
- The red EXIT button asks whether to exit only, clean up and exit, or cancel.
- Cleanup removes JetFUEL temp folders, the downloaded %LOCALAPPDATA%\JetFUEL bootstrap copy, the private embedded Web UI support files, and its browser cache.
- The shared Microsoft Edge WebView2 Runtime is left installed because Windows and other applications may use it.
- SSH keys are left in place.
- Git for Windows / Git Bash is only uninstalled after a second confirmation because other tools may use it.

Web UI tab
- Embeds the JetKVM's official web interface directly inside JetFUEL, including video and keyboard/mouse input.
- Install Web UI downloads a pinned Microsoft WebView2 SDK package, verifies its SHA-256, and installs only JetFUEL's private support DLLs. If the shared Microsoft Edge WebView2 Runtime is missing, JetFUEL downloads Microsoft's signed Evergreen installer.
- Enter a device address or reuse the Setup address, then select Open. Back, Forward, Refresh, and Open externally provide normal browser controls.
- JetFUEL connects only to the address you specify. This tab does not scan every address on the local subnet and does not depend on mDNS discovery.
- JetKVM authentication remains inside the embedded web session. JetFUEL does not collect or store the JetKVM password.
- Remove support deletes JetFUEL's private SDK files and browser profile. It does not uninstall the shared Edge WebView2 Runtime or change the JetKVM or SSH keys.

Tailscale tab
- Check Tailscale prints status, Tailscale IP, version, routes, DNS, and running Tailscale processes.
- Check Tailscale also verifies the JetKVM boot hook at /userdata/init.d/S22tailscale so you can see whether Tailscale should survive reboot.
- Repair Tailscale recreates JetFUEL's robust boot hook and watchdog, waits for tailscaled to create its socket, then reruns tailscale up with the current auth key/hostname settings or opens the manual login URL when no auth key is used. The watchdog restarts an exited daemon, a daemon with no socket, or a daemon whose LocalAPI health probe hangs three times in succession.
- Remove Tailscale logs out where possible, stops Tailscale, removes /userdata/tailscale, and reboots the JetKVM.

Diagnostics tab
- Quick check collects versions, uptime/load, memory, D-state processes, important services, network, storage, Tailscale, watchdog state, and recent kernel messages.
- Save full report adds the JetKVM application log, crash dumps, process list, HDMI/USB state, thermal readings, persistent-file inventory, and full kernel log. Reports can contain IP/MAC/device identifiers and log content; review them before sharing.
- View app log reads /userdata/jetkvm/last.log. View crash logs reads /userdata/jetkvm/crashdump.
- Reboot requests a normal Linux reboot. Force reboot uses reboot -f and should only be used when a normal reboot does not recover the device.
- A true electrical power cycle cannot be performed by software running on the JetKVM after its own power is removed. Use switched USB/PoE power or an external smart plug.
- Open OTA settings uses the JetKVM web UI, which is the normal update path.
- Manual app update is an advanced fallback using JetKVM's official release API and SHA-256 verification; it bypasses staged rollout and updates the app component only.
- DriverAssistant and SocToolKit are Rockchip DFU recovery tools, not normal Windows device drivers. Recovery flashing can erase/reset the JetKVM and requires physical DFU mode.

Identity tab
- Network MAC identity lets you read the active JetKVM MAC, write a generated/custom user override, or clear the user override.
- MAC profile choices are local-administered generated addresses. They are labels for organization; JetFUEL does not clone this PC MAC and does not use real third-party vendor OUIs by default.
- Applying or clearing a MAC override needs a JetKVM reboot before Ethernet uses the new value.
- Scan this PC identity loads JetKVM's default EDID/USB presets, then adds connected monitor EDID records and local USB input VID/PID candidates.
- If several display or USB candidates are found, choose the one you want from the dropdowns.
- Apply EDID writes the selected EDID hex content to JetKVM's hdmi_edid_string config value. This is the same content JetKVM's Video page calls EDID File.
- Apply USB writes the selected VID/PID/manufacturer/product to JetKVM's usb_config value.
- EDID/USB apply creates a timestamped backup of /userdata/kvm_config.json, writes the new config over SSH, then offers to reboot the JetKVM so the KVM service reloads it.
- USB identity changes the JetKVM composite USB gadget identity. It does not clone every descriptor from a separate physical keyboard or mouse.
- Wake-on-LAN target scans this Windows PC for network adapters, calculates the MAC and broadcast IP, optionally enables Wake-on-LAN on the selected Windows adapter, then saves that target into JetKVM's Wake on LAN device list.
- Enabling WOL on the Windows adapter requires Administrator PowerShell and adapter driver support. BIOS/UEFI Wake-on-LAN may still need to be enabled manually. Wired Ethernet is usually more reliable than Wi-Fi.
- Saving the JetKVM WOL target backs up /userdata/kvm_config.json and offers to reboot JetKVM so the web UI reloads the Wake on LAN device list.

BIOS - WARNING tab
- This is an optional local PC prep tool. It is not part of the JetKVM Tailscale install and never runs automatically.
- It uses bundled pinned copies of ConfigJon Firmware-Management scripts for Dell, HP, and Lenovo systems.
- Credit: BIOS scan/apply is powered by ConfigJon Firmware-Management, bundled under its MIT license.
- Scan BIOS reads local firmware settings and reports what JetFUEL would change before anything is written.
- Apply BIOS prep can enable BIOS Wake-on-LAN, set power-on-after-AC-restore, and disable known deep sleep/power-saving settings that can block Wake-on-LAN.
- JetFUEL does not change PXE/network boot order.
- BIOS passwords are typed for the current run only. They are passed to the child process through environment variables, redacted from logs, and not saved by JetFUEL.
- Firmware setting names vary by model. Unsupported or missing settings are reported and skipped.
- Vendor tooling/resources:
  - BIOS tool: https://github.com/ConfigJon/Firmware-Management
  - ConfigJon site: https://www.configjon.com/
  - Lenovo direct download: https://download.lenovo.com/pccbbs/thinkvantage_en/system_update_5.08.03.59.exe
  - Lenovo download page: https://support.lenovo.com/gb/en/solutions/ht037099
  - HP direct download: https://ftp.hp.com/pub/softpaq/sp143501-144000/sp143621.exe
  - HP download page: https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HP_BCU.html
  - Dell direct download: model-specific; use Dell Support for the target model/service tag.
  - Dell download page: https://www.dell.com/support/contents/en-uk/article/product-support/self-support-knowledgebase/fix-common-issues/bios-uefi

Settings tab
- Custom script URL is only used when Step 3 is set to Custom URL.
- Local script file is only used when Step 3 is set to Local file.
- The JetFUEL repo script is a copied reference/fallback copy of JetKVM's installer. It exists in case JetKVM changes the hosted script later.
- Custom scripts must keep the same command-line contract:
  [-v|--version <tailscale-version>] [-y|--yes] [-c|--clean] <JetKVM-IP> [-- <tailscale up args...>]
- Custom scripts must install/configure Tailscale on the JetKVM, handle reboot/return, and print any Tailscale login URL.
- JetKVM device settings can apply config-backed defaults: auto update, keyboard layout, display brightness/timers, HDMI sleep, network hostname/domain, mDNS, and IPv6 mode.
- When a network hostname is enabled, JetFUEL also writes /etc/hostname and /etc/hosts immediately. Reboot the JetKVM after applying so DHCP startup uses the new name; a simple DHCP renew can keep the old lease hostname on udhcpc.
- The local password is not written by this wizard yet. Set or change it in JetKVM Settings > Access.
- Hide Header and Hide Status Bar are browser UI preferences in the JetKVM web app, not JetKVM device config values, so JetFUEL does not push them over SSH.

Troubleshooting
- If Git Bash is missing, JetFUEL can install Git for Windows only when winget is installed and working.
- If winget reports that the application cannot be started, choose the App Installer repair option to open the Microsoft Store and install/reinstall App Installer, or choose the Git download option and install Git for Windows manually.
- If Wake-on-LAN does not wake the Windows PC, confirm WOL is enabled in BIOS/UEFI, Windows adapter power management, and the NIC advanced driver settings. Prefer wired Ethernet; some Wi-Fi adapters and USB Ethernet adapters cannot wake a fully powered-off PC.
- If the JetKVM stays in NeedsLogin, use Check Tailscale and look for a login URL in the log.
- If Tailscale says "failed to connect to local tailscaled", the daemon did not start, its socket was not ready, or its LocalAPI is hung. Run Repair Tailscale; JetFUEL writes a boot hook that waits for networking and /dev/net/tun before starting tailscaled, then keeps a watchdog running to restart it after an exit, a missing socket, or three consecutive timed-out health probes.
- Tailscale auth keys should be full pre-authentication secrets beginning with tskey-auth-. The key ID ending CNTRL is not enough.
- Newer OpenSSH clients can print "connection is not using a post-quantum key exchange algorithm" when talking to JetKVM SSH. JetFUEL suppresses it where supported; it is an SSH warning and should not be treated as the Tailscale install failure.
- Tailscale installation may fail if the JetKVM itself is set up/authenticated using Google auth. Use local JetKVM authentication for this SSH/Developer Mode flow.
- If SSH login fails, confirm Developer Mode is enabled, the public key was saved in JetKVM Settings > Advanced, and the selected private key matches the public key.

Status log
- Shows the detailed output from preflight, install, repair, remove, and checks.
- Use Copy logs when reporting an issue or saving the output.
- Drag the splitter above the log to make it larger or smaller.

Inventory tab
- Uses the Setup tab JetKVM address and SSH key to collect a concise device record, then reads this Windows PC's make/model, Windows 10/11 edition and build, serial, primary active physical-adapter MAC, CPU, RAM, and external IP.
- Collect details displays both sections without writing a file. Save report opens a standard Save dialog, and Copy details places the formatted report on the clipboard.
- The external-IP lookup uses api.ipify.org with a short timeout. If it is unavailable, the remaining inventory is still displayed and saved.
- Reports include device and network identifiers. Review them before sharing. Cloud credentials, auth keys, passwords, and SSH key contents are never included.
- Open saved report becomes available after an explicit save and opens that report.
"@
    $helpPage.Controls.Add($helpBox)

    $pageHost.Controls.AddRange(@($inventoryPage, $helpPage, $settingsPage, $biosPage, $diagnosticsPage, $identityPage, $tailscalePage, $desktopPage, $setupPage))
    $showPage = {
        param([string]$Name)
        $setupPage.Visible = ($Name -eq "Setup")
        $desktopPage.Visible = ($Name -eq "Desktop")
        $tailscalePage.Visible = ($Name -eq "Tailscale")
        $identityPage.Visible = ($Name -eq "Identity")
        $diagnosticsPage.Visible = ($Name -eq "Diagnostics")
        $biosPage.Visible = ($Name -eq "BIOS")
        $settingsPage.Visible = ($Name -eq "Settings")
        $helpPage.Visible = ($Name -eq "Help")
        $inventoryPage.Visible = ($Name -eq "Inventory")
        Set-ButtonStyle $setupTabButton $(if ($Name -eq "Setup") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $desktopTabButton $(if ($Name -eq "Desktop") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $tailscaleTabButton $(if ($Name -eq "Tailscale") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $identityTabButton $(if ($Name -eq "Identity") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $diagnosticsTabButton $(if ($Name -eq "Diagnostics") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $biosTabButton "Danger"
        Set-ButtonStyle $settingsTabButton $(if ($Name -eq "Settings") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $helpTabButton $(if ($Name -eq "Help") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $inventoryTabButton $(if ($Name -eq "Inventory") { "Primary" } else { "Secondary" })
    }
    $setupTabButton.Add_Click({ & $showPage "Setup" })
    $desktopTabButton.Add_Click({
        if ([string]::IsNullOrWhiteSpace($desktopWebAddressBox.Text) -and -not [string]::IsNullOrWhiteSpace($ipBox.Text)) {
            $desktopWebAddressBox.Text = $ipBox.Text.Trim()
        }
        & $showPage "Desktop"
    })
    $tailscaleTabButton.Add_Click({ & $showPage "Tailscale" })
    $identityTabButton.Add_Click({ & $showPage "Identity" })
    $diagnosticsTabButton.Add_Click({ & $showPage "Diagnostics" })
    $biosTabButton.Add_Click({ & $showPage "BIOS" })
    $settingsTabButton.Add_Click({ & $showPage "Settings" })
    $helpTabButton.Add_Click({ & $showPage "Help" })
    $inventoryTabButton.Add_Click({ & $showPage "Inventory" })

    $pageShell.Controls.Add($navPanel, 0, 0)
    $pageShell.Controls.Add($pageHost, 0, 1)
    $main.Controls.Add($pageShell, 0, 1)
    & $showPage "Setup"

    $setupTips = [Windows.Forms.ToolTip]::new()
    $setupTips.AutoPopDelay = 12000
    $setupTips.InitialDelay = 350
    $setupTips.ReshowDelay = 100

    $deploymentGroup = New-Group "1 - Deployment details"
    & $makeGroupAutoHeight $deploymentGroup
    $deploymentColumns = [Windows.Forms.TableLayoutPanel]::new()
    $deploymentColumns.Dock = "Top"
    $deploymentColumns.AutoSize = $true
    $deploymentColumns.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $deploymentColumns.ColumnCount = 2
    $deploymentColumns.RowCount = 1
    $deploymentColumns.Padding = New-ScaledPadding 4 4 4 1
    $deploymentColumns.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 50)) | Out-Null
    $deploymentColumns.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 50)) | Out-Null
    $deploymentGroup.Controls.Add($deploymentColumns)

    $connectionGrid = New-StepGrid 4
    # Keep the shorter SSH grid pinned to the top instead of stretching its
    # final row to match the taller Tailscale grid beside it.
    $connectionGrid.Dock = "Top"
    $connectionGrid.Padding = New-ScaledPadding 0 0 8 0
    $connectionGrid.ColumnStyles.Clear()
    $connectionGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 122))) | Out-Null
    $connectionGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $connectionGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 124))) | Out-Null
    $connectionGrid.RowStyles.Clear()
    foreach ($height in @(27, 27, 25, 27)) {
        $connectionGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $ipBox = New-Field ""
    $keyBox = New-Field (Join-Path $HOME ".ssh\id_rsa_jetkvm")
    $passBox = New-Field ""
    $passBox.UseSystemPasswordChar = $true
    $passBox.Enabled = $false
    $openUiButton = [Windows.Forms.Button]::new()
    $openUiButton.Text = "Open UI"
    $openUiButton.Dock = "Fill"
    Set-ButtonStyle $openUiButton "Secondary"
    $browseButton = [Windows.Forms.Button]::new()
    $browseButton.Text = "Browse"
    $browseButton.Dock = "Fill"
    Set-ButtonStyle $browseButton "Secondary"
    $createKeyCheck = [Windows.Forms.CheckBox]::new()
    $createKeyCheck.Text = "Create SSH key if missing"
    $createKeyCheck.Checked = $true
    $createKeyCheck.Dock = "Fill"
    $createKeyCheck.AutoEllipsis = $true
    Set-CheckStyle $createKeyCheck
    $noPassCheck = [Windows.Forms.CheckBox]::new()
    $noPassCheck.Text = "No passphrase"
    $noPassCheck.Checked = $true
    $noPassCheck.Dock = "Fill"
    $noPassCheck.AutoEllipsis = $true
    Set-CheckStyle $noPassCheck
    $setupTips.SetToolTip($noPassCheck, "Use no passphrase for the SSH private key.")
    $connectionGrid.Controls.Add((New-RowLabel "JetKVM address"), 0, 0)
    $connectionGrid.Controls.Add($ipBox, 1, 0)
    $connectionGrid.Controls.Add($openUiButton, 2, 0)
    $connectionGrid.Controls.Add((New-RowLabel "SSH private key"), 0, 1)
    $connectionGrid.Controls.Add($keyBox, 1, 1)
    $connectionGrid.Controls.Add($browseButton, 2, 1)
    $connectionGrid.Controls.Add($createKeyCheck, 1, 2)
    $connectionGrid.SetColumnSpan($createKeyCheck, 2)
    $connectionGrid.Controls.Add((New-RowLabel "Key passphrase"), 0, 3)
    $connectionGrid.Controls.Add($passBox, 1, 3)
    $connectionGrid.Controls.Add($noPassCheck, 2, 3)
    $deploymentColumns.Controls.Add($connectionGrid, 0, 0)

    $tailscaleGrid = New-StepGrid 5
    $tailscaleGrid.Dock = "Top"
    $tailscaleGrid.Padding = New-ScaledPadding 8 0 0 0
    $tailscaleGrid.ColumnStyles.Clear()
    $tailscaleGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 120))) | Out-Null
    $tailscaleGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $tailscaleGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 4))) | Out-Null
    $tailscaleGrid.RowStyles.Clear()
    foreach ($height in @(27, 25, 27, 27, 27)) {
        $tailscaleGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $installerSourceBox = [Windows.Forms.ComboBox]::new()
    $installerSourceBox.Dock = "Fill"
    $installerSourceBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $installerSourceBox.Margin = New-ScaledPadding 0 2 8 2
    $installerSourceBox.BackColor = $ui.Input
    $installerSourceBox.ForeColor = $ui.InputText
    $installerSourceBox.Font = [Drawing.Font]::new("Segoe UI", 9)
    [void]$installerSourceBox.Items.AddRange(@("Official JetKVM", "JetFUEL repo", "Custom URL", "Local file"))
    $installerSourceBox.SelectedItem = "Official JetKVM"
    $cleanCheck = [Windows.Forms.CheckBox]::new()
    $cleanCheck.Text = "Clean install (new identity)"
    $cleanCheck.Dock = "Fill"
    $cleanCheck.AutoEllipsis = $true
    Set-CheckStyle $cleanCheck
    $useAuthKeyCheck = [Windows.Forms.CheckBox]::new()
    $useAuthKeyCheck.Text = "Auth key"
    $useAuthKeyCheck.Dock = "Fill"
    $useAuthKeyCheck.AutoEllipsis = $true
    Set-CheckStyle $useAuthKeyCheck
    $authBox = New-Field ""
    $authBox.UseSystemPasswordChar = $true
    $authBox.Enabled = $false
    $hostBox = New-Field ""
    $versionBox = New-Field "1.96.4"
    $installOptions = [Windows.Forms.TableLayoutPanel]::new()
    $installOptions.Dock = "Fill"
    $installOptions.Margin = [Windows.Forms.Padding]::new(0)
    $installOptions.ColumnCount = 2
    $installOptions.RowCount = 1
    $installOptions.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 36)) | Out-Null
    $installOptions.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 64)) | Out-Null
    $installOptions.Controls.Add($useAuthKeyCheck, 0, 0)
    $installOptions.Controls.Add($cleanCheck, 1, 0)
    $tailscaleGrid.Controls.Add((New-RowLabel "Tailscale name"), 0, 0)
    $tailscaleGrid.Controls.Add($hostBox, 1, 0)
    $tailscaleGrid.SetColumnSpan($hostBox, 2)
    $tailscaleGrid.Controls.Add($installOptions, 1, 1)
    $tailscaleGrid.SetColumnSpan($installOptions, 2)
    $tailscaleGrid.Controls.Add((New-RowLabel "Auth key"), 0, 2)
    $tailscaleGrid.Controls.Add($authBox, 1, 2)
    $tailscaleGrid.SetColumnSpan($authBox, 2)
    $tailscaleGrid.Controls.Add((New-RowLabel "Install script"), 0, 3)
    $tailscaleGrid.Controls.Add($installerSourceBox, 1, 3)
    $tailscaleGrid.SetColumnSpan($installerSourceBox, 2)
    $tailscaleGrid.Controls.Add((New-RowLabel "Tailscale version"), 0, 4)
    $tailscaleGrid.Controls.Add($versionBox, 1, 4)
    $tailscaleGrid.SetColumnSpan($versionBox, 2)
    $deploymentColumns.Controls.Add($tailscaleGrid, 1, 0)
    $setupTips.SetToolTip($ipBox, "Enter the JetKVM IPv4 address or resolvable hostname.")
    $setupTips.SetToolTip($keyBox, "Private SSH key used for Developer Mode access. SSH key files are retained during cleanup.")
    $setupTips.SetToolTip($createKeyCheck, "Create the selected SSH key when it does not already exist.")
    $setupTips.SetToolTip($hostBox, "Optional Tailscale device name: lowercase letters, numbers, and hyphens only; no leading or trailing hyphen.")
    $setupTips.SetToolTip($useAuthKeyCheck, "Enable automatic tailnet enrolment. Leave clear to authenticate using the browser login URL.")
    $setupTips.SetToolTip($authBox, "Paste the full tskey-auth-... pre-authentication secret. The key ID ending CNTRL is not sufficient.")
    $setupTips.SetToolTip($cleanCheck, "Remove the existing Tailscale state and create a new machine identity.")
    $setupTips.SetToolTip($installerSourceBox, "Official JetKVM is the default. See Settings for reference, custom URL, and local-file details.")
    $setupTips.SetToolTip($versionBox, "Pinned for JetKVM compatibility. Change only when you have verified another version.")
    $setupLayout.Controls.Add($deploymentGroup, 0, 0)

    $precheckGroup = New-Group "2 - Preflight checks"
    & $makeGroupAutoHeight $precheckGroup
    $preGrid = New-StepGrid 2
    $preGrid.ColumnCount = 4
    $preGrid.ColumnStyles.Clear()
    foreach ($percent in @(23, 25, 29)) {
        $preGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, $percent)) | Out-Null
    }
    $preGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 132))) | Out-Null
    $preGrid.RowStyles.Clear()
    foreach ($height in @(22, 22)) {
        $preGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $precheckGroup.Controls.Add($preGrid)
    $bashStatus = New-RowLabel "[ ] Git Bash: not checked"
    $sshStatus = New-RowLabel "[ ] SSH tools: not checked"
    $wingetStatus = New-RowLabel "[ ] winget: not checked"
    $sshLoginStatus = New-RowLabel "[ ] SSH login: enable Developer Mode first"
    $kvmStatus = New-RowLabel "[ ] JetKVM network: not checked"
    $httpStatus = New-RowLabel "[ ] JetKVM web UI: not checked"
    foreach ($label in @($bashStatus, $sshStatus, $wingetStatus, $sshLoginStatus, $kvmStatus, $httpStatus)) {
        $label.AutoEllipsis = $true
    }
    $preflightButton = [Windows.Forms.Button]::new()
    $preflightButton.Text = "Run preflight"
    $preflightButton.Dock = "Fill"
    $preflightButton.Margin = New-ScaledPadding 8 2 8 2
    Set-ButtonStyle $preflightButton "Secondary"
    $preGrid.Controls.Add($bashStatus, 0, 0)
    $preGrid.Controls.Add($kvmStatus, 1, 0)
    $preGrid.Controls.Add($sshLoginStatus, 2, 0)
    $preGrid.Controls.Add($sshStatus, 0, 1)
    $preGrid.Controls.Add($httpStatus, 1, 1)
    $preGrid.Controls.Add($wingetStatus, 2, 1)
    $preGrid.Controls.Add($preflightButton, 3, 0)
    $preGrid.SetRowSpan($preflightButton, 2)
    $setupLayout.Controls.Add($precheckGroup, 0, 1)

    $manualSteps = New-Group "3 - Developer Mode SSH required"
    & $makeGroupAutoHeight $manualSteps
    $manualSteps.BackColor = [Drawing.Color]::FromArgb(69, 46, 16)
    $manualSteps.ForeColor = [Drawing.Color]::FromArgb(253, 230, 138)
    $manualGrid = New-StepGrid 2
    $manualGrid.RowStyles.Clear()
    foreach ($height in @(22, 22)) {
        $manualGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $manualSteps.Controls.Add($manualGrid)
    $stepsText = [Windows.Forms.Label]::new()
    $stepsText.Text = "Required: open JetKVM Settings > Advanced, enable Developer Mode, paste the public SSH key, and save. Install JetKVM updates first."
    $stepsText.Dock = "Fill"
    $stepsText.ForeColor = [Drawing.Color]::FromArgb(255, 251, 235)
    $stepsText.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
    $securityText = [Windows.Forms.Label]::new()
    $securityText.Text = "After setup: remove the SSH key or disable Developer Mode again if you do not need SSH access."
    $securityText.Dock = "Fill"
    $securityText.ForeColor = [Drawing.Color]::FromArgb(253, 230, 138)
    $securityText.Font = [Drawing.Font]::new("Segoe UI", 9)
    $copyKeyButton = [Windows.Forms.Button]::new()
    $copyKeyButton.Text = "Copy public key"
    $copyKeyButton.Dock = "Fill"
    $copyKeyButton.Margin = New-ScaledPadding 8 1 8 2
    Set-ButtonStyle $copyKeyButton "Secondary"
    $openUiButton2 = [Windows.Forms.Button]::new()
    $openUiButton2.Text = "Open JetKVM UI"
    $openUiButton2.Dock = "Fill"
    $openUiButton2.Margin = New-ScaledPadding 8 1 8 2
    Set-ButtonStyle $openUiButton2 "Secondary"
    $manualGrid.Controls.Add($stepsText, 0, 0)
    $manualGrid.SetColumnSpan($stepsText, 2)
    $manualGrid.Controls.Add($securityText, 0, 1)
    $manualGrid.SetColumnSpan($securityText, 2)
    $manualGrid.Controls.Add($copyKeyButton, 2, 0)
    $manualGrid.Controls.Add($openUiButton2, 2, 1)
    $setupLayout.Controls.Add($manualSteps, 0, 2)

    $statusLabel = [Windows.Forms.Label]::new()
    $statusLabel.Text = "Ready"
    $statusLabel.Dock = "Fill"
    $statusLabel.TextAlign = "MiddleLeft"
    $statusLabel.ForeColor = $ui.Muted
    $statusLabel.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)

    $setupActionPanel = [Windows.Forms.TableLayoutPanel]::new()
    $setupActionPanel.Dock = "Fill"
    $setupActionPanel.BackColor = $ui.Window
    $setupActionPanel.ColumnCount = 2
    $setupActionPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $setupActionPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 184))) | Out-Null
    $runButton = [Windows.Forms.Button]::new()
    $runButton.Text = "4 - Install Tailscale"
    $runButton.Dock = "Fill"
    $runButton.Margin = New-ScaledPadding 8 3 0 3
    Set-ButtonStyle $runButton "Primary"
    $setupActionPanel.Controls.Add($statusLabel, 0, 0)
    $setupActionPanel.Controls.Add($runButton, 1, 0)
    $setupLayout.Controls.Add($setupActionPanel, 0, 3)

    $desktopToolbarGroup = New-Group "Embedded JetKVM Web UI"
    $desktopToolbarGroup.Dock = "Fill"
    $desktopToolbarGrid = [Windows.Forms.TableLayoutPanel]::new()
    $desktopToolbarGrid.Dock = "Fill"
    $desktopToolbarGrid.Padding = New-ScaledPadding 8 5 8 5
    $desktopToolbarGrid.ColumnCount = 7
    $desktopToolbarGrid.RowCount = 2
    $desktopToolbarGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 92))) | Out-Null
    $desktopToolbarGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    foreach ($width in @(76, 48, 48, 76, 132)) {
        $desktopToolbarGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S $width))) | Out-Null
    }
    $desktopToolbarGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S 36))) | Out-Null
    $desktopToolbarGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null

    $desktopAddressLabel = New-RowLabel "Device address"
    $desktopAddressLabel.Dock = "Fill"
    $desktopAddressLabel.TextAlign = "MiddleLeft"
    $desktopWebAddressBox = New-Field ""
    $desktopWebAddressBox.Dock = "Fill"
    $desktopWebAddressBox.Margin = New-ScaledPadding 0 3 8 3
    $openEmbeddedWebButton = [Windows.Forms.Button]::new()
    $openEmbeddedWebButton.Text = "Open"
    $openEmbeddedWebButton.Dock = "Fill"
    $openEmbeddedWebButton.Margin = New-ScaledPadding 0 2 4 2
    Set-ButtonStyle $openEmbeddedWebButton "Primary"
    $webBackButton = [Windows.Forms.Button]::new()
    $webBackButton.Text = "<"
    $webBackButton.Dock = "Fill"
    $webBackButton.Margin = New-ScaledPadding 0 2 4 2
    Set-ButtonStyle $webBackButton "Secondary"
    $setupTips.SetToolTip($webBackButton, "Back")
    $webForwardButton = [Windows.Forms.Button]::new()
    $webForwardButton.Text = ">"
    $webForwardButton.Dock = "Fill"
    $webForwardButton.Margin = New-ScaledPadding 0 2 4 2
    Set-ButtonStyle $webForwardButton "Secondary"
    $setupTips.SetToolTip($webForwardButton, "Forward")
    $webRefreshButton = [Windows.Forms.Button]::new()
    $webRefreshButton.Text = "Refresh"
    $webRefreshButton.Dock = "Fill"
    $webRefreshButton.Margin = New-ScaledPadding 0 2 4 2
    Set-ButtonStyle $webRefreshButton "Secondary"
    $webExternalButton = [Windows.Forms.Button]::new()
    $webExternalButton.Text = "Open externally"
    $webExternalButton.Dock = "Fill"
    $webExternalButton.Margin = New-ScaledPadding 0 2 0 2
    Set-ButtonStyle $webExternalButton "Secondary"

    $desktopStatusLabel = New-RowLabel "Checking embedded browser support..."
    $desktopStatusLabel.Dock = "Fill"
    $desktopStatusLabel.TextAlign = "MiddleLeft"
    $desktopStatusLabel.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
    $installDesktopButton = [Windows.Forms.Button]::new()
    $installDesktopButton.Text = "Install Web UI"
    $installDesktopButton.Dock = "Fill"
    $installDesktopButton.Margin = New-ScaledPadding 0 2 4 2
    Set-ButtonStyle $installDesktopButton "Primary"
    $removeDesktopButton = [Windows.Forms.Button]::new()
    $removeDesktopButton.Text = "Remove support"
    $removeDesktopButton.Dock = "Fill"
    $removeDesktopButton.Margin = New-ScaledPadding 0 2 0 2
    Set-ButtonStyle $removeDesktopButton "Danger"

    $desktopToolbarGrid.Controls.Add($desktopAddressLabel, 0, 0)
    $desktopToolbarGrid.Controls.Add($desktopWebAddressBox, 1, 0)
    $desktopToolbarGrid.Controls.Add($openEmbeddedWebButton, 2, 0)
    $desktopToolbarGrid.Controls.Add($webBackButton, 3, 0)
    $desktopToolbarGrid.Controls.Add($webForwardButton, 4, 0)
    $desktopToolbarGrid.Controls.Add($webRefreshButton, 5, 0)
    $desktopToolbarGrid.Controls.Add($webExternalButton, 6, 0)
    $desktopToolbarGrid.Controls.Add($desktopStatusLabel, 0, 1)
    $desktopToolbarGrid.SetColumnSpan($desktopStatusLabel, 5)
    $desktopToolbarGrid.Controls.Add($installDesktopButton, 5, 1)
    $desktopToolbarGrid.Controls.Add($removeDesktopButton, 6, 1)
    $desktopToolbarGroup.Controls.Add($desktopToolbarGrid)
    $desktopLayout.Controls.Add($desktopToolbarGroup, 0, 0)

    $desktopBrowserHost = [Windows.Forms.Panel]::new()
    $desktopBrowserHost.Dock = "Fill"
    $desktopBrowserHost.Margin = New-ScaledPadding 0 6 0 0
    $desktopBrowserHost.BackColor = $ui.Log
    $desktopPlaceholder = [Windows.Forms.Label]::new()
    $desktopPlaceholder.Text = "Install the embedded Web UI support, then enter or reuse the Setup device address and select Open.\r\n\r\nJetFUEL connects directly to that address. It does not scan the local subnet."
    $desktopPlaceholder.Dock = "Fill"
    $desktopPlaceholder.TextAlign = "MiddleCenter"
    $desktopPlaceholder.ForeColor = $ui.Muted
    $desktopPlaceholder.Font = [Drawing.Font]::new("Segoe UI", 10)
    $desktopBrowserHost.Controls.Add($desktopPlaceholder)
    $desktopLayout.Controls.Add($desktopBrowserHost, 0, 1)

    $webUiState = [pscustomobject]@{
        Control = $null
        Ready = $false
        RemovalPending = $false
    }

    $actionPanel = [Windows.Forms.TableLayoutPanel]::new()
    $actionPanel.Dock = "Top"
    $actionPanel.Height = S 58
    $actionPanel.BackColor = $ui.Surface
    $actionPanel.ColumnCount = 4
    $actionPanel.Padding = [Windows.Forms.Padding]::new((S 10))
    $actionPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    foreach ($width in @(150, 150, 150)) {
        $actionPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S $width))) | Out-Null
    }
    $tailscaleText = [Windows.Forms.Label]::new()
    $tailscaleText.Text = "Tailscale maintenance"
    $tailscaleText.Dock = "Fill"
    $tailscaleText.TextAlign = "MiddleLeft"
    $tailscaleText.ForeColor = $ui.Text
    $tailscaleText.Font = [Drawing.Font]::new("Segoe UI", 12, [Drawing.FontStyle]::Bold)
    $checkTailscaleButton = [Windows.Forms.Button]::new()
    $checkTailscaleButton.Text = "Check Tailscale"
    $checkTailscaleButton.Dock = "Fill"
    $checkTailscaleButton.Margin = New-ScaledPadding 8 3 0 3
    Set-ButtonStyle $checkTailscaleButton "Secondary"
    $repairTailscaleButton = [Windows.Forms.Button]::new()
    $repairTailscaleButton.Text = "Repair Tailscale"
    $repairTailscaleButton.Dock = "Fill"
    $repairTailscaleButton.Margin = New-ScaledPadding 8 3 0 3
    Set-ButtonStyle $repairTailscaleButton "Secondary"
    $removeTailscaleButton = [Windows.Forms.Button]::new()
    $removeTailscaleButton.Text = "Remove Tailscale"
    $removeTailscaleButton.Dock = "Fill"
    $removeTailscaleButton.Margin = New-ScaledPadding 8 3 0 3
    Set-ButtonStyle $removeTailscaleButton "Secondary"
    $actionPanel.Controls.Add($tailscaleText, 0, 0)
    $actionPanel.Controls.Add($checkTailscaleButton, 1, 0)
    $actionPanel.Controls.Add($repairTailscaleButton, 2, 0)
    $actionPanel.Controls.Add($removeTailscaleButton, 3, 0)
    $tailscaleLayout.Controls.Add($actionPanel, 0, 0)

    $tailscaleHelpGroup = New-Group "What these tools do"
    & $makeGroupAutoHeight $tailscaleHelpGroup
    $tailscaleHelp = [Windows.Forms.Label]::new()
    $tailscaleHelp.Dock = "Top"
    $tailscaleHelp.AutoSize = $true
    $tailscaleHelp.Padding = New-ScaledPadding 4 8 4 8
    $tailscaleHelp.ForeColor = $ui.Muted
    $tailscaleHelp.Font = [Drawing.Font]::new("Segoe UI", 9)
    $tailscaleHelp.Text = "Check prints service, network, version, and watchdog health. Repair rebuilds the boot hook/watchdog and reconnects using the Setup details. Remove logs out, deletes Tailscale state, and reboots the JetKVM.`r`nRepair also restarts tailscaled after repeated LocalAPI health timeouts; without an auth key it opens the browser login flow."
    $tailscaleHelpGroup.Controls.Add($tailscaleHelp)
    $tailscaleLayout.Controls.Add($tailscaleHelpGroup, 0, 1)
    $resizeTailscaleHelp = {
        $tailscaleHelp.MaximumSize = [Drawing.Size]::new([Math]::Max((S 360), $tailscalePage.ClientSize.Width - (S 52)), 0)
    }
    $tailscalePage.Add_SizeChanged({ & $resizeTailscaleHelp })
    $tailscalePage.Add_VisibleChanged({ if ($tailscalePage.Visible) { & $resizeTailscaleHelp } })
    & $resizeTailscaleHelp

    $newDiagnosticsButton = {
        param([string]$Text, [string]$Kind = "Secondary", [int]$Width = 142)
        $button = [Windows.Forms.Button]::new()
        $button.Text = $Text
        $button.Size = [Drawing.Size]::new((S $Width), (S 34))
        $button.Margin = New-ScaledPadding 0 2 8 4
        Set-ButtonStyle $button $Kind
        return $button
    }

    $diagnosticsGroup = New-Group "JetKVM health and debug files"
    & $makeGroupAutoHeight $diagnosticsGroup
    $diagnosticsGrid = [Windows.Forms.TableLayoutPanel]::new()
    $diagnosticsGrid.Dock = "Top"
    $diagnosticsGrid.AutoSize = $true
    $diagnosticsGrid.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $diagnosticsGrid.ColumnCount = 1
    $diagnosticsGrid.RowCount = 3
    $diagnosticsGrid.Padding = New-ScaledPadding 8 4 8 2
    $diagnosticsGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    for ($i = 0; $i -lt 3; $i++) {
        $diagnosticsGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    }
    $diagnosticsIntro = New-RowLabel "Read-only SSH checks using the Setup address and key. Quick check covers health; full report adds logs and crash dumps."
    $diagnosticsPrivacy = New-RowLabel "Reports may contain IPs, MAC addresses, identifiers, and application logs. Review before sharing."
    $diagnosticsPrivacy.ForeColor = $ui.Warn
    $diagnosticsActions = [Windows.Forms.FlowLayoutPanel]::new()
    $diagnosticsActions.Dock = "Top"
    $diagnosticsActions.AutoSize = $true
    $diagnosticsActions.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $diagnosticsActions.WrapContents = $true
    $quickDiagnosticsButton = & $newDiagnosticsButton "Quick check" "Primary"
    $saveDiagnosticsButton = & $newDiagnosticsButton "Save full report"
    $viewAppLogButton = & $newDiagnosticsButton "View app log"
    $viewCrashLogsButton = & $newDiagnosticsButton "View crash logs"
    $diagnosticsActions.Controls.AddRange(@($quickDiagnosticsButton, $saveDiagnosticsButton, $viewAppLogButton, $viewCrashLogsButton))
    $diagnosticsGrid.Controls.Add($diagnosticsIntro, 0, 0)
    $diagnosticsGrid.Controls.Add($diagnosticsPrivacy, 0, 1)
    $diagnosticsGrid.Controls.Add($diagnosticsActions, 0, 2)
    $diagnosticsGroup.Controls.Add($diagnosticsGrid)
    $diagnosticsLayout.Controls.Add($diagnosticsGroup, 0, 0)

    $restartGroup = New-Group "Restart and power recovery"
    & $makeGroupAutoHeight $restartGroup
    $restartGrid = [Windows.Forms.TableLayoutPanel]::new()
    $restartGrid.Dock = "Top"
    $restartGrid.AutoSize = $true
    $restartGrid.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $restartGrid.ColumnCount = 1
    $restartGrid.RowCount = 2
    $restartGrid.Padding = New-ScaledPadding 8 4 8 2
    $restartGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    for ($i = 0; $i -lt 2; $i++) {
        $restartGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    }
    $restartIntro = New-RowLabel "Use normal reboot first. Force reboot is a last resort. Electrical power cycling requires an external switched power source."
    $restartActions = [Windows.Forms.FlowLayoutPanel]::new()
    $restartActions.Dock = "Top"
    $restartActions.AutoSize = $true
    $restartActions.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $restartActions.WrapContents = $true
    $rebootJetKvmButton = & $newDiagnosticsButton "Reboot JetKVM" "Secondary"
    $forceRebootJetKvmButton = & $newDiagnosticsButton "Force reboot" "Danger"
    $powerCycleHelpButton = & $newDiagnosticsButton "Power-cycle help" "Secondary"
    $restartActions.Controls.AddRange(@($rebootJetKvmButton, $forceRebootJetKvmButton, $powerCycleHelpButton))
    $restartGrid.Controls.Add($restartIntro, 0, 0)
    $restartGrid.Controls.Add($restartActions, 0, 1)
    $restartGroup.Controls.Add($restartGrid)
    $diagnosticsLayout.Controls.Add($restartGroup, 0, 1)

    $recoveryGroup = New-Group "Updates and DFU recovery"
    & $makeGroupAutoHeight $recoveryGroup
    $recoveryGrid = [Windows.Forms.TableLayoutPanel]::new()
    $recoveryGrid.Dock = "Top"
    $recoveryGrid.AutoSize = $true
    $recoveryGrid.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $recoveryGrid.ColumnCount = 1
    $recoveryGrid.RowCount = 3
    $recoveryGrid.Padding = New-ScaledPadding 8 4 8 2
    $recoveryGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    for ($i = 0; $i -lt 3; $i++) {
        $recoveryGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    }
    $updateIntro = New-RowLabel "Use OTA settings for normal updates. Manual app update is an advanced, checksum-verified app-only fallback."
    $recoveryWarning = New-RowLabel "DFU recovery is destructive and needs physical access. DriverAssistant installs recovery drivers; SocToolKit flashes the official image."
    $recoveryWarning.ForeColor = $ui.Warn
    $recoveryActions = [Windows.Forms.FlowLayoutPanel]::new()
    $recoveryActions.Dock = "Top"
    $recoveryActions.AutoSize = $true
    $recoveryActions.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $recoveryActions.WrapContents = $true
    $openOtaButton = & $newDiagnosticsButton "Open OTA settings"
    $manualAppUpdateButton = & $newDiagnosticsButton "Manual app update" "Danger"
    $driverAssistantButton = & $newDiagnosticsButton "DriverAssistant"
    $socToolkitButton = & $newDiagnosticsButton "SocToolKit"
    $recoveryImageButton = & $newDiagnosticsButton "Recovery image" "Danger"
    $recoveryGuideButton = & $newDiagnosticsButton "Recovery guide"
    $recoveryActions.Controls.AddRange(@($openOtaButton, $manualAppUpdateButton, $driverAssistantButton, $socToolkitButton, $recoveryImageButton, $recoveryGuideButton))
    $recoveryGrid.Controls.Add($updateIntro, 0, 0)
    $recoveryGrid.Controls.Add($recoveryWarning, 0, 1)
    $recoveryGrid.Controls.Add($recoveryActions, 0, 2)
    $recoveryGroup.Controls.Add($recoveryGrid)
    $diagnosticsLayout.Controls.Add($recoveryGroup, 0, 2)

    $diagnosticTextLabels = @($diagnosticsIntro, $diagnosticsPrivacy, $restartIntro, $updateIntro, $recoveryWarning)
    foreach ($diagnosticTextLabel in $diagnosticTextLabels) {
        $diagnosticTextLabel.AutoSize = $true
        $diagnosticTextLabel.Dock = "Top"
        $diagnosticTextLabel.TextAlign = "TopLeft"
        $diagnosticTextLabel.Padding = New-ScaledPadding 0 2 0 3
    }
    $resizeDiagnosticText = {
        $wrapWidth = [Math]::Max((S 360), $diagnosticsPage.ClientSize.Width - (S 52))
        foreach ($diagnosticTextLabel in $diagnosticTextLabels) {
            $diagnosticTextLabel.MaximumSize = [Drawing.Size]::new($wrapWidth, 0)
        }
    }
    $diagnosticsPage.Add_SizeChanged({ & $resizeDiagnosticText })
    $diagnosticsPage.Add_VisibleChanged({ if ($diagnosticsPage.Visible) { & $resizeDiagnosticText } })
    & $resizeDiagnosticText

    $inventoryGroup = New-Group "JetKVM and local PC inventory"
    & $makeGroupAutoHeight $inventoryGroup
    $inventoryGrid = [Windows.Forms.TableLayoutPanel]::new()
    $inventoryGrid.Dock = "Top"
    $inventoryGrid.AutoSize = $true
    $inventoryGrid.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $inventoryGrid.ColumnCount = 2
    $inventoryGrid.RowCount = 21
    $inventoryGrid.Padding = New-ScaledPadding 10 7 10 8
    $inventoryGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 190))) | Out-Null
    $inventoryGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    for ($i = 0; $i -lt 21; $i++) {
        $inventoryGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    }

    $inventoryIntro = New-RowLabel "Collects the JetKVM identity plus this Windows PC's hardware summary and displays both below. Nothing is saved unless you select Save report."
    $inventoryIntro.AutoSize = $true
    $inventoryIntro.Dock = "Top"
    $inventoryIntro.Padding = New-ScaledPadding 0 2 0 5
    $inventoryGrid.Controls.Add($inventoryIntro, 0, 0)
    $inventoryGrid.SetColumnSpan($inventoryIntro, 2)

    $inventoryActions = [Windows.Forms.FlowLayoutPanel]::new()
    $inventoryActions.Dock = "Top"
    $inventoryActions.AutoSize = $true
    $inventoryActions.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $inventoryActions.WrapContents = $true
    $collectInventoryButton = & $newDiagnosticsButton "Collect details" "Primary" 145
    $saveInventoryButton = & $newDiagnosticsButton "Save report" "Secondary" 125
    $copyInventoryButton = & $newDiagnosticsButton "Copy details" "Secondary" 132
    $openInventoryReportButton = & $newDiagnosticsButton "Open saved report" "Secondary" 156
    $saveInventoryButton.Enabled = $false
    $copyInventoryButton.Enabled = $false
    $openInventoryReportButton.Enabled = $false
    $inventoryActions.Controls.AddRange(@($collectInventoryButton, $saveInventoryButton, $copyInventoryButton, $openInventoryReportButton))
    $inventoryGrid.Controls.Add($inventoryActions, 0, 1)
    $inventoryGrid.SetColumnSpan($inventoryActions, 2)

    function New-InventoryValueLabel {
        $label = [Windows.Forms.Label]::new()
        $label.Text = "Not collected"
        $label.Dock = "Fill"
        $label.AutoSize = $false
        $label.Height = S 27
        $label.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
        $label.Padding = New-ScaledPadding 8 0 8 0
        $label.Margin = New-ScaledPadding 0 2 0 2
        $label.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
        $label.BackColor = $ui.Surface2
        $label.ForeColor = $ui.Text
        $label.Font = [Drawing.Font]::new("Segoe UI", 9)
        $label.AutoEllipsis = $true
        return $label
    }

    $inventoryRows = [ordered]@{
        "KVM Make" = New-InventoryValueLabel
        "KVM Model / Version" = New-InventoryValueLabel
        "Serial Number" = New-InventoryValueLabel
        "MAC" = New-InventoryValueLabel
        "Hostname" = New-InventoryValueLabel
        "Tailscale Name" = New-InventoryValueLabel
        "Cloud Configured State" = New-InventoryValueLabel
    }
    $rowIndex = 2
    foreach ($entry in $inventoryRows.GetEnumerator()) {
        $nameLabel = New-RowLabel $entry.Key
        $nameLabel.ForeColor = $ui.Muted
        $inventoryGrid.Controls.Add($nameLabel, 0, $rowIndex)
        $inventoryGrid.Controls.Add($entry.Value, 1, $rowIndex)
        $rowIndex++
    }

    $localInventoryTitle = New-RowLabel "Local Windows PC"
    $localInventoryTitle.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $localInventoryTitle.ForeColor = $ui.Info
    $localInventoryTitle.Padding = New-ScaledPadding 0 9 0 3
    $inventoryGrid.Controls.Add($localInventoryTitle, 0, 9)
    $inventoryGrid.SetColumnSpan($localInventoryTitle, 2)

    $localInventoryRows = [ordered]@{
        "PC Name" = New-InventoryValueLabel
        "PC Make" = New-InventoryValueLabel
        "PC Model" = New-InventoryValueLabel
        "Windows Version" = New-InventoryValueLabel
        "PC Serial Number" = New-InventoryValueLabel
        "PC MAC" = New-InventoryValueLabel
        "CPU" = New-InventoryValueLabel
        "RAM (GB)" = New-InventoryValueLabel
        "External IP" = New-InventoryValueLabel
    }
    $rowIndex = 10
    foreach ($entry in $localInventoryRows.GetEnumerator()) {
        $nameLabel = New-RowLabel $entry.Key
        $nameLabel.ForeColor = $ui.Muted
        $inventoryGrid.Controls.Add($nameLabel, 0, $rowIndex)
        $inventoryGrid.Controls.Add($entry.Value, 1, $rowIndex)
        $rowIndex++
    }

    $inventoryPrivacyLabel = New-RowLabel "Privacy: the saved report includes local and external IP-related identifiers. Review it before sharing. External IP lookup uses api.ipify.org and is skipped gracefully if unavailable."
    $inventoryPrivacyLabel.AutoSize = $true
    $inventoryPrivacyLabel.Dock = "Top"
    $inventoryPrivacyLabel.ForeColor = $ui.Warn
    $inventoryPrivacyLabel.Padding = New-ScaledPadding 0 7 0 1
    $inventoryGrid.Controls.Add($inventoryPrivacyLabel, 0, 19)
    $inventoryGrid.SetColumnSpan($inventoryPrivacyLabel, 2)

    $inventoryPathLabel = New-RowLabel "Not collected. Use Collect details, then choose Save report or Copy details."
    $inventoryPathLabel.AutoSize = $true
    $inventoryPathLabel.Dock = "Top"
    $inventoryPathLabel.ForeColor = $ui.Muted
    $inventoryPathLabel.Padding = New-ScaledPadding 0 6 0 1
    $inventoryGrid.Controls.Add($inventoryPathLabel, 0, 20)
    $inventoryGrid.SetColumnSpan($inventoryPathLabel, 2)
    $inventoryGroup.Controls.Add($inventoryGrid)
    $inventoryPage.Controls.Add($inventoryGroup)

    $inventoryState = [pscustomobject]@{
        Data = $null
        ReportPath = $null
    }
    $resizeInventoryIntro = {
        $inventoryIntro.MaximumSize = [Drawing.Size]::new([Math]::Max((S 360), $inventoryPage.ClientSize.Width - (S 60)), 0)
        $inventoryPrivacyLabel.MaximumSize = [Drawing.Size]::new([Math]::Max((S 360), $inventoryPage.ClientSize.Width - (S 60)), 0)
    }
    $inventoryPage.Add_SizeChanged({ & $resizeInventoryIntro })
    $inventoryPage.Add_VisibleChanged({ if ($inventoryPage.Visible) { & $resizeInventoryIntro } })
    & $resizeInventoryIntro

    $macGroup = New-Group "Network MAC identity"
    & $makeGroupAutoHeight $macGroup
    $macGrid = New-StepGrid 7
    $macGrid.RowStyles.Clear()
    foreach ($height in @(30, 28, 28, 28, 26, 30, 36)) {
        $macGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $macGroup.Controls.Add($macGrid)
    $macIntro = [Windows.Forms.Label]::new()
    $macIntro.Text = "Advanced: generate or set a persistent JetKVM Ethernet MAC override. This does not clone this PC and does not use real third-party vendor OUIs by default."
    $macIntro.Dock = "Fill"
    $macIntro.ForeColor = $ui.Muted
    $macIntro.Font = [Drawing.Font]::new("Segoe UI", 9)
    $macCurrentLabel = New-RowLabel "Current JetKVM MAC: not checked"
    $macOverrideLabel = New-RowLabel "User override: not checked"
    $macProfiles = Get-MacIdentityProfiles
    $macProfileBox = [Windows.Forms.ComboBox]::new()
    $macProfileBox.Dock = "Fill"
    $macProfileBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $macProfileBox.Margin = New-ScaledPadding 0 2 8 2
    $macProfileBox.BackColor = $ui.Input
    $macProfileBox.ForeColor = $ui.InputText
    $macProfileBox.Font = [Drawing.Font]::new("Segoe UI", 9)
    [void]$macProfileBox.Items.AddRange(($macProfiles | ForEach-Object { $_.Name }))
    $macProfileBox.SelectedItem = $macProfiles[0].Name
    $macProfileHelp = New-RowLabel $macProfiles[0].Description
    $macBox = New-Field ""
    $macWarning = [Windows.Forms.Label]::new()
    $macWarning.Text = "Changing MAC may change the JetKVM IP, DHCP reservation, firewall rules, and remote access. Reboot is required before the value is active."
    $macWarning.Dock = "Fill"
    $macWarning.ForeColor = $ui.Warn
    $macWarning.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
    $refreshMacButton = [Windows.Forms.Button]::new()
    $refreshMacButton.Text = "Refresh"
    $refreshMacButton.Dock = "Fill"
    $refreshMacButton.Margin = New-ScaledPadding 8 2 8 2
    Set-ButtonStyle $refreshMacButton "Secondary"
    $generateMacButton = [Windows.Forms.Button]::new()
    $generateMacButton.Text = "Generate"
    $generateMacButton.Dock = "Fill"
    $generateMacButton.Margin = New-ScaledPadding 8 2 8 2
    Set-ButtonStyle $generateMacButton "Secondary"
    $applyMacButton = [Windows.Forms.Button]::new()
    $applyMacButton.Text = "Apply"
    $applyMacButton.Dock = "Fill"
    $applyMacButton.Margin = New-ScaledPadding 8 2 8 2
    Set-ButtonStyle $applyMacButton "Primary"
    $clearMacButton = [Windows.Forms.Button]::new()
    $clearMacButton.Text = "Clear override"
    $clearMacButton.Dock = "Fill"
    $clearMacButton.Margin = New-ScaledPadding 8 2 8 2
    Set-ButtonStyle $clearMacButton "Secondary"
    $macGrid.Controls.Add($macIntro, 0, 0)
    $macGrid.SetColumnSpan($macIntro, 3)
    $macGrid.Controls.Add($macCurrentLabel, 0, 1)
    $macGrid.SetColumnSpan($macCurrentLabel, 2)
    $macGrid.Controls.Add($refreshMacButton, 2, 1)
    $macGrid.Controls.Add($macOverrideLabel, 0, 2)
    $macGrid.SetColumnSpan($macOverrideLabel, 3)
    $macGrid.Controls.Add((New-RowLabel "MAC profile"), 0, 3)
    $macGrid.Controls.Add($macProfileBox, 1, 3)
    $macGrid.Controls.Add($generateMacButton, 2, 3)
    $macGrid.Controls.Add($macProfileHelp, 1, 4)
    $macGrid.SetColumnSpan($macProfileHelp, 2)
    $macGrid.Controls.Add((New-RowLabel "MAC to apply"), 0, 5)
    $macGrid.Controls.Add($macBox, 1, 5)
    $macGrid.Controls.Add($applyMacButton, 2, 5)
    $macGrid.Controls.Add($macWarning, 0, 6)
    $macGrid.SetColumnSpan($macWarning, 2)
    $macGrid.Controls.Add($clearMacButton, 2, 6)
    $identityLayout.Controls.Add($macGroup, 0, 0)

    $identityScanGroup = New-Group "Display and USB identity"
    & $makeGroupAutoHeight $identityScanGroup
    $identityScanGrid = New-StepGrid 9
    $identityScanGrid.ColumnStyles.Clear()
    $identityScanGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 145))) | Out-Null
    $identityScanGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $identityScanGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 150))) | Out-Null
    $identityScanGrid.RowStyles.Clear()
    foreach ($height in @(38, 24, 30, 24, 24, 30, 24, 42, 34)) {
        $identityScanGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $identityScanGroup.Controls.Add($identityScanGrid)
    $identityScanIntro = [Windows.Forms.Label]::new()
    $identityScanIntro.Text = "Scan this Windows PC, choose a display EDID or USB identity, then apply it to the JetKVM using the Setup tab IP and SSH key."
    $identityScanIntro.Dock = "Fill"
    $identityScanIntro.ForeColor = $ui.Muted
    $identityScanIntro.Font = [Drawing.Font]::new("Segoe UI", 9)
    $edidStatusLabel = New-RowLabel "Display EDID: not scanned"
    $usbStatusLabel = New-RowLabel "USB input devices: not scanned"
    $selectedDisplayLabel = New-RowLabel "Selected display: none"
    $selectedUsbLabel = New-RowLabel "Selected USB identity: none"
    $identityNote = New-RowLabel "Apply writes /userdata/kvm_config.json over SSH, creates a timestamped backup, then offers to reboot. EDID uses the same hex content shown as EDID File in the JetKVM UI."
    $displayChoiceBox = [Windows.Forms.ComboBox]::new()
    $displayChoiceBox.Dock = "Fill"
    $displayChoiceBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $displayChoiceBox.Margin = New-ScaledPadding 0 2 8 2
    $displayChoiceBox.BackColor = $ui.Input
    $displayChoiceBox.ForeColor = $ui.InputText
    $displayChoiceBox.Font = [Drawing.Font]::new("Segoe UI", 9)
    $displayChoiceBox.DisplayMember = "DisplayName"
    $displayChoiceBox.Enabled = $false
    $usbChoiceBox = [Windows.Forms.ComboBox]::new()
    $usbChoiceBox.Dock = "Fill"
    $usbChoiceBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $usbChoiceBox.Margin = New-ScaledPadding 0 2 8 2
    $usbChoiceBox.BackColor = $ui.Input
    $usbChoiceBox.ForeColor = $ui.InputText
    $usbChoiceBox.Font = [Drawing.Font]::new("Segoe UI", 9)
    $usbChoiceBox.DisplayMember = "DisplayName"
    $usbChoiceBox.Enabled = $false
    $scanThisPcButton = [Windows.Forms.Button]::new()
    $scanThisPcButton.Text = "Scan PC"
    $scanThisPcButton.Dock = "Fill"
    $scanThisPcButton.Margin = New-ScaledPadding 8 2 8 2
    Set-ButtonStyle $scanThisPcButton "Secondary"
    $applyEdidButton = [Windows.Forms.Button]::new()
    $applyEdidButton.Text = "Apply EDID"
    $applyEdidButton.Dock = "Fill"
    $applyEdidButton.Margin = New-ScaledPadding 8 2 8 2
    $applyEdidButton.Enabled = $false
    Set-ButtonStyle $applyEdidButton "Primary"
    $applyUsbButton = [Windows.Forms.Button]::new()
    $applyUsbButton.Text = "Apply USB"
    $applyUsbButton.Dock = "Fill"
    $applyUsbButton.Margin = New-ScaledPadding 8 2 8 2
    $applyUsbButton.Enabled = $false
    Set-ButtonStyle $applyUsbButton "Primary"
    $identityScanGrid.Controls.Add($identityScanIntro, 0, 0)
    $identityScanGrid.SetColumnSpan($identityScanIntro, 3)
    $identityScanGrid.Controls.Add($edidStatusLabel, 0, 1)
    $identityScanGrid.SetColumnSpan($edidStatusLabel, 3)
    $identityScanGrid.Controls.Add((New-RowLabel "Display EDID to use"), 0, 2)
    $identityScanGrid.Controls.Add($displayChoiceBox, 1, 2)
    $identityScanGrid.Controls.Add($applyEdidButton, 2, 2)
    $identityScanGrid.Controls.Add($selectedDisplayLabel, 1, 3)
    $identityScanGrid.SetColumnSpan($selectedDisplayLabel, 2)
    $identityScanGrid.Controls.Add($usbStatusLabel, 0, 4)
    $identityScanGrid.SetColumnSpan($usbStatusLabel, 3)
    $identityScanGrid.Controls.Add((New-RowLabel "USB identity to use"), 0, 5)
    $identityScanGrid.Controls.Add($usbChoiceBox, 1, 5)
    $identityScanGrid.Controls.Add($applyUsbButton, 2, 5)
    $identityScanGrid.Controls.Add($selectedUsbLabel, 1, 6)
    $identityScanGrid.SetColumnSpan($selectedUsbLabel, 2)
    $identityScanGrid.Controls.Add($identityNote, 0, 7)
    $identityScanGrid.SetColumnSpan($identityNote, 2)
    $identityScanGrid.Controls.Add($scanThisPcButton, 2, 8)
    $identityLayout.Controls.Add($identityScanGroup, 0, 1)

    $wolGroup = New-Group "Wake-on-LAN target"
    & $makeGroupAutoHeight $wolGroup
    $wolGrid = New-StepGrid 8
    $wolGrid.ColumnStyles.Clear()
    $wolGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 145))) | Out-Null
    $wolGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $wolGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 150))) | Out-Null
    $wolGrid.RowStyles.Clear()
    foreach ($height in @(38, 30, 30, 30, 30, 28, 40, 34)) {
        $wolGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $wolGroup.Controls.Add($wolGrid)
    $wolIntro = [Windows.Forms.Label]::new()
    $wolIntro.Text = "Scan this Windows PC for the NIC MAC, optionally enable Windows Wake-on-LAN, then save it as a JetKVM Wake on LAN target."
    $wolIntro.Dock = "Fill"
    $wolIntro.ForeColor = $ui.Muted
    $wolIntro.Font = [Drawing.Font]::new("Segoe UI", 9)
    $wolAdapterBox = [Windows.Forms.ComboBox]::new()
    $wolAdapterBox.Dock = "Fill"
    $wolAdapterBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $wolAdapterBox.Margin = New-ScaledPadding 0 2 8 2
    $wolAdapterBox.BackColor = $ui.Input
    $wolAdapterBox.ForeColor = $ui.InputText
    $wolAdapterBox.Font = [Drawing.Font]::new("Segoe UI", 9)
    $wolAdapterBox.DisplayMember = "DisplayName"
    $wolNameBox = New-Field $env:COMPUTERNAME
    $wolMacBox = New-Field ""
    $wolBroadcastBox = New-Field ""
    $enableLocalWolCheck = [Windows.Forms.CheckBox]::new()
    $enableLocalWolCheck.Text = "Enable Wake-on-LAN on this Windows adapter first (requires Administrator)"
    $enableLocalWolCheck.Checked = $true
    $enableLocalWolCheck.Dock = "Fill"
    Set-CheckStyle $enableLocalWolCheck
    $wolStatusLabel = [Windows.Forms.Label]::new()
    $wolStatusLabel.Text = "Scan adapters to pick the NIC that should wake this PC. Wired Ethernet is usually more reliable than Wi-Fi."
    $wolStatusLabel.Dock = "Fill"
    $wolStatusLabel.ForeColor = $ui.Muted
    $wolStatusLabel.Font = [Drawing.Font]::new("Segoe UI", 9)
    $scanWolAdaptersButton = [Windows.Forms.Button]::new()
    $scanWolAdaptersButton.Text = "Scan NICs"
    $scanWolAdaptersButton.Dock = "Fill"
    $scanWolAdaptersButton.Margin = New-ScaledPadding 8 2 8 2
    Set-ButtonStyle $scanWolAdaptersButton "Secondary"
    $applyWolButton = [Windows.Forms.Button]::new()
    $applyWolButton.Text = "Set up WOL"
    $applyWolButton.Dock = "Fill"
    $applyWolButton.Margin = New-ScaledPadding 8 2 8 2
    Set-ButtonStyle $applyWolButton "Primary"
    $wolGrid.Controls.Add($wolIntro, 0, 0)
    $wolGrid.SetColumnSpan($wolIntro, 3)
    $wolGrid.Controls.Add((New-RowLabel "Windows adapter"), 0, 1)
    $wolGrid.Controls.Add($wolAdapterBox, 1, 1)
    $wolGrid.Controls.Add($scanWolAdaptersButton, 2, 1)
    $wolGrid.Controls.Add((New-RowLabel "Target name"), 0, 2)
    $wolGrid.Controls.Add($wolNameBox, 1, 2)
    $wolGrid.SetColumnSpan($wolNameBox, 2)
    $wolGrid.Controls.Add((New-RowLabel "Target MAC"), 0, 3)
    $wolGrid.Controls.Add($wolMacBox, 1, 3)
    $wolGrid.SetColumnSpan($wolMacBox, 2)
    $wolGrid.Controls.Add((New-RowLabel "Broadcast IP"), 0, 4)
    $wolGrid.Controls.Add($wolBroadcastBox, 1, 4)
    $wolGrid.SetColumnSpan($wolBroadcastBox, 2)
    $wolGrid.Controls.Add($enableLocalWolCheck, 1, 5)
    $wolGrid.SetColumnSpan($enableLocalWolCheck, 2)
    $wolGrid.Controls.Add($wolStatusLabel, 0, 6)
    $wolGrid.SetColumnSpan($wolStatusLabel, 2)
    $wolGrid.Controls.Add($applyWolButton, 2, 6)
    $identityLayout.Controls.Add($wolGroup, 0, 2)

    foreach ($preset in @(Get-JetKvmEdidPresets)) { [void]$displayChoiceBox.Items.Add($preset) }
    $displayChoiceBox.Enabled = ($displayChoiceBox.Items.Count -gt 0)
    $applyEdidButton.Enabled = $displayChoiceBox.Enabled
    if ($displayChoiceBox.Items.Count -gt 0) { $displayChoiceBox.SelectedIndex = 0 }
    if ($displayChoiceBox.SelectedItem) {
        $selectedDisplayLabel.Text = "Selected display: $($displayChoiceBox.SelectedItem.DisplayName)"
        $selectedDisplayLabel.ForeColor = $ui.Good
    }
    $edidStatusLabel.Text = "Display EDID: JetKVM presets loaded; scan PC to add local monitors"
    $edidStatusLabel.ForeColor = $ui.Info

    foreach ($preset in @(Get-JetKvmUsbIdentityPresets)) { [void]$usbChoiceBox.Items.Add($preset) }
    $usbChoiceBox.Enabled = ($usbChoiceBox.Items.Count -gt 0)
    $applyUsbButton.Enabled = $usbChoiceBox.Enabled
    if ($usbChoiceBox.Items.Count -gt 0) { $usbChoiceBox.SelectedIndex = 0 }
    if ($usbChoiceBox.SelectedItem) {
        $selectedUsbLabel.Text = "Selected USB identity: $($usbChoiceBox.SelectedItem.DisplayName)"
        $selectedUsbLabel.ForeColor = $ui.Good
    }
    $usbStatusLabel.Text = "USB identity: JetKVM presets loaded; scan PC to add local USB candidates"
    $usbStatusLabel.ForeColor = $ui.Info

    $biosManifest = Get-ConfigJonBiosManifest
    $biosSourceText = if ($biosManifest) {
        "Bundled ConfigJon Firmware-Management scripts from commit $($biosManifest.upstream_commit). Dell/HP/Lenovo only; PXE boot order is report-only and is not changed."
    } else {
        "Bundled ConfigJon Firmware-Management metadata was not found. Scan/apply will still check for the required vendor script files."
    }

    $biosWarningGroup = New-Group "BIOS prep warning"
    & $makeGroupAutoHeight $biosWarningGroup
    $biosWarningGroup.BackColor = [Drawing.Color]::FromArgb(69, 10, 10)
    $biosWarningGroup.ForeColor = [Drawing.Color]::FromArgb(254, 202, 202)
    $biosWarningGrid = New-StepGrid 3
    $biosWarningGrid.RowStyles.Clear()
    foreach ($height in @(38, 28, 26)) {
        $biosWarningGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $biosWarningGroup.Controls.Add($biosWarningGrid)
    $biosWarningLabel = [Windows.Forms.Label]::new()
    $biosWarningLabel.Text = "This changes BIOS/UEFI settings on the Windows PC running JetFUEL, not on the JetKVM. Scan first, review the report, and only apply on machines you are allowed to manage."
    $biosWarningLabel.Dock = "Fill"
    $biosWarningLabel.ForeColor = [Drawing.Color]::FromArgb(255, 245, 245)
    $biosWarningLabel.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
    $biosWarningLabel.AutoEllipsis = $true
    $biosWarningSource = New-RowLabel $biosSourceText
    $biosWarningSource.ForeColor = [Drawing.Color]::FromArgb(254, 202, 202)
    $biosPasswordNote = New-RowLabel "BIOS passwords are optional, used for this run only, passed through child-process environment variables, redacted from logs, and never saved by JetFUEL."
    $biosPasswordNote.ForeColor = [Drawing.Color]::FromArgb(253, 230, 138)
    $biosWarningGrid.Controls.Add($biosWarningLabel, 0, 0)
    $biosWarningGrid.SetColumnSpan($biosWarningLabel, 3)
    $biosWarningGrid.Controls.Add($biosWarningSource, 0, 1)
    $biosWarningGrid.SetColumnSpan($biosWarningSource, 3)
    $biosWarningGrid.Controls.Add($biosPasswordNote, 0, 2)
    $biosWarningGrid.SetColumnSpan($biosPasswordNote, 3)
    $biosLayout.Controls.Add($biosWarningGroup, 0, 0)

    $biosDetectGroup = New-Group "Detected local PC BIOS"
    & $makeGroupAutoHeight $biosDetectGroup
    $biosDetectGrid = New-StepGrid 7
    $biosDetectGrid.RowStyles.Clear()
    foreach ($height in @(28, 28, 28, 28, 28, 28, 30)) {
        $biosDetectGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $biosDetectGroup.Controls.Add($biosDetectGrid)
    $biosVendorValue = New-RowLabel "Not scanned"
    $biosModelValue = New-RowLabel "Not scanned"
    $biosVersionValue = New-RowLabel "Not scanned"
    $biosSupportValue = New-RowLabel "Not scanned"
    $biosPasswordBox = New-Field ""
    $biosPasswordBox.UseSystemPasswordChar = $true
    $biosSmPasswordBox = New-Field ""
    $biosSmPasswordBox.UseSystemPasswordChar = $true
    $scanBiosButton = [Windows.Forms.Button]::new()
    $scanBiosButton.Text = "Scan BIOS"
    $scanBiosButton.Dock = "Fill"
    $scanBiosButton.Margin = New-ScaledPadding 8 2 8 2
    Set-ButtonStyle $scanBiosButton "Secondary"
    $applyBiosButton = [Windows.Forms.Button]::new()
    $applyBiosButton.Text = "Apply BIOS prep"
    $applyBiosButton.Dock = "Fill"
    $applyBiosButton.Margin = New-ScaledPadding 8 2 8 2
    $applyBiosButton.Enabled = $false
    Set-ButtonStyle $applyBiosButton "Danger"
    $biosDetectGrid.Controls.Add((New-RowLabel "Manufacturer"), 0, 0)
    $biosDetectGrid.Controls.Add($biosVendorValue, 1, 0)
    $biosDetectGrid.Controls.Add($scanBiosButton, 2, 0)
    $biosDetectGrid.SetRowSpan($scanBiosButton, 2)
    $biosDetectGrid.Controls.Add((New-RowLabel "Model"), 0, 1)
    $biosDetectGrid.Controls.Add($biosModelValue, 1, 1)
    $biosDetectGrid.Controls.Add((New-RowLabel "BIOS version"), 0, 2)
    $biosDetectGrid.Controls.Add($biosVersionValue, 1, 2)
    $biosDetectGrid.Controls.Add($applyBiosButton, 2, 2)
    $biosDetectGrid.SetRowSpan($applyBiosButton, 2)
    $biosDetectGrid.Controls.Add((New-RowLabel "Support"), 0, 3)
    $biosDetectGrid.Controls.Add($biosSupportValue, 1, 3)
    $biosDetectGrid.Controls.Add((New-RowLabel "BIOS password"), 0, 4)
    $biosDetectGrid.Controls.Add($biosPasswordBox, 1, 4)
    $biosDetectGrid.SetColumnSpan($biosPasswordBox, 2)
    $biosDetectGrid.Controls.Add((New-RowLabel "Lenovo SM password"), 0, 5)
    $biosDetectGrid.Controls.Add($biosSmPasswordBox, 1, 5)
    $biosDetectGrid.SetColumnSpan($biosSmPasswordBox, 2)
    $biosDetectGrid.Controls.Add((New-RowLabel "Password note"), 0, 6)
    $biosLenovoNote = New-RowLabel "Leave passwords blank unless the local PC firmware already has one set. Lenovo system-management password is optional and Lenovo-only."
    $biosLenovoNote.ForeColor = $ui.Muted
    $biosDetectGrid.Controls.Add($biosLenovoNote, 1, 6)
    $biosDetectGrid.SetColumnSpan($biosLenovoNote, 2)
    $biosLayout.Controls.Add($biosDetectGroup, 0, 1)

    $biosOptionsGroup = New-Group "Recommended BIOS prep"
    & $makeGroupAutoHeight $biosOptionsGroup
    $biosOptionsGrid = New-StepGrid 5
    $biosOptionsGrid.RowStyles.Clear()
    foreach ($height in @(30, 30, 30, 30, 30)) {
        $biosOptionsGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $biosOptionsGroup.Controls.Add($biosOptionsGrid)
    $biosWolCheck = [Windows.Forms.CheckBox]::new()
    $biosWolCheck.Text = "Enable BIOS Wake-on-LAN support"
    $biosWolCheck.Checked = $true
    $biosWolCheck.Dock = "Fill"
    Set-CheckStyle $biosWolCheck
    $biosAcPowerCheck = [Windows.Forms.CheckBox]::new()
    $biosAcPowerCheck.Text = "Power on after AC power is restored"
    $biosAcPowerCheck.Checked = $true
    $biosAcPowerCheck.Dock = "Fill"
    Set-CheckStyle $biosAcPowerCheck
    $biosPowerBlockersCheck = [Windows.Forms.CheckBox]::new()
    $biosPowerBlockersCheck.Text = "Disable known deep sleep / power-saving settings that can block WOL"
    $biosPowerBlockersCheck.Checked = $true
    $biosPowerBlockersCheck.Dock = "Fill"
    Set-CheckStyle $biosPowerBlockersCheck
    $biosPxeNote = New-RowLabel "PXE/network boot settings are not changed by JetFUEL. Firmware setting names vary by model; missing settings are skipped and shown in the report."
    $biosPxeNote.ForeColor = $ui.Warn
    $biosOptionsGrid.Controls.Add($biosWolCheck, 1, 0)
    $biosOptionsGrid.SetColumnSpan($biosWolCheck, 2)
    $biosOptionsGrid.Controls.Add($biosAcPowerCheck, 1, 1)
    $biosOptionsGrid.SetColumnSpan($biosAcPowerCheck, 2)
    $biosOptionsGrid.Controls.Add($biosPowerBlockersCheck, 1, 2)
    $biosOptionsGrid.SetColumnSpan($biosPowerBlockersCheck, 2)
    $biosOptionsGrid.Controls.Add($biosPxeNote, 0, 3)
    $biosOptionsGrid.SetColumnSpan($biosPxeNote, 3)
    $biosLayout.Controls.Add($biosOptionsGroup, 0, 2)

    $biosReportGroup = New-Group "BIOS scan report"
    $biosReportGroup.Dock = "Top"
    $biosReportGroup.Height = S 220
    $biosReportBox = [Windows.Forms.RichTextBox]::new()
    $biosReportBox.Dock = "Fill"
    $biosReportBox.ReadOnly = $true
    $biosReportBox.WordWrap = $false
    $biosReportBox.ScrollBars = "Both"
    $biosReportBox.BorderStyle = "FixedSingle"
    $biosReportBox.BackColor = $ui.Log
    $biosReportBox.ForeColor = $ui.Text
    $biosReportBox.Font = [Drawing.Font]::new("Consolas", 9)
    $biosReportBox.Text = "Click Scan BIOS to detect Dell/HP/Lenovo firmware support and preview the settings JetFUEL can change."
    $biosReportGroup.Controls.Add($biosReportBox)
    $biosLayout.Controls.Add($biosReportGroup, 0, 3)

    $settingsGroup = New-Group "Installer sources"
    & $makeGroupAutoHeight $settingsGroup
    $settingsGrid = New-StepGrid 5
    $settingsGrid.RowStyles.Clear()
    foreach ($height in @(32, 28, 30, 30, 38)) {
        $settingsGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $settingsGroup.Controls.Add($settingsGrid)
    $settingsIntro = [Windows.Forms.Label]::new()
    $settingsIntro.Text = "Advanced installer sources. The default is JetKVM's current installer. The JetFUEL repo script is a copied reference/fallback in case JetKVM changes their hosted script."
    $settingsIntro.Dock = "Fill"
    $settingsIntro.ForeColor = $ui.Muted
    $settingsIntro.Font = [Drawing.Font]::new("Segoe UI", 9)
    $customInstallerUrlBox = New-Field ""
    $localInstallerPathBox = New-Field ""
    $browseInstallerButton = [Windows.Forms.Button]::new()
    $browseInstallerButton.Text = "Browse"
    $browseInstallerButton.Dock = "Fill"
    Set-ButtonStyle $browseInstallerButton "Secondary"
    $metadataPath = Join-Path (Get-JetFuelScriptRoot) "install-tailscale.metadata.json"
    $metadataText = "JetFUEL repo reference copy metadata not found."
    if (Test-Path -LiteralPath $metadataPath) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            $metadataText = "JetFUEL repo reference copy of JetKVM script: fetched $($metadata.fetched_utc), SHA256 $($metadata.sha256)"
        } catch {}
    }
    $metadataLabel = New-RowLabel $metadataText
    $metadataLabel.AutoEllipsis = $true
    $requirementsLabel = [Windows.Forms.Label]::new()
    $requirementsLabel.Dock = "Fill"
    $requirementsLabel.ForeColor = $ui.Muted
    $requirementsLabel.Font = [Drawing.Font]::new("Segoe UI", 9)
    $requirementsLabel.Text = "Custom scripts must follow JetFUEL's installer contract. See Help > Settings for arguments, SSH, reboot, and login URL requirements."
    $requirementsLabel.TextAlign = "MiddleLeft"
    $setupTips.SetToolTip($metadataLabel, $metadataText)
    $setupTips.SetToolTip($requirementsLabel, "POSIX shell; accepts version/yes/clean/IP/tailscale-up arguments; handles install, reboot, login URL, and JETFUEL_SSH_OPTS.")
    $settingsGrid.Controls.Add($settingsIntro, 0, 0)
    $settingsGrid.SetColumnSpan($settingsIntro, 3)
    $settingsGrid.Controls.Add($metadataLabel, 0, 1)
    $settingsGrid.SetColumnSpan($metadataLabel, 3)
    $settingsGrid.Controls.Add((New-RowLabel "Custom script URL"), 0, 2)
    $settingsGrid.Controls.Add($customInstallerUrlBox, 1, 2)
    $settingsGrid.SetColumnSpan($customInstallerUrlBox, 2)
    $settingsGrid.Controls.Add((New-RowLabel "Local script file"), 0, 3)
    $settingsGrid.Controls.Add($localInstallerPathBox, 1, 3)
    $settingsGrid.Controls.Add($browseInstallerButton, 2, 3)
    $settingsGrid.Controls.Add($requirementsLabel, 0, 4)
    $settingsGrid.SetColumnSpan($requirementsLabel, 3)
    $settingsLayout.Controls.Add($settingsGroup, 0, 0)

    $deviceSettingsGroup = New-Group "JetKVM device settings"
    & $makeGroupAutoHeight $deviceSettingsGroup
    $deviceSettingsGrid = New-StepGrid 17
    $deviceSettingsGrid.RowStyles.Clear()
    foreach ($height in @(38, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 50, 34, 38)) {
        $deviceSettingsGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $deviceSettingsGroup.Controls.Add($deviceSettingsGrid)

    $deviceSettingsIntro = [Windows.Forms.Label]::new()
    $deviceSettingsIntro.Text = "Optional device defaults written to /userdata/kvm_config.json over SSH. These are config-backed JetKVM settings and normally need a reboot to take effect."
    $deviceSettingsIntro.Dock = "Fill"
    $deviceSettingsIntro.ForeColor = $ui.Muted
    $deviceSettingsIntro.Font = [Drawing.Font]::new("Segoe UI", 9)

    $disableAutoUpdateCheck = [Windows.Forms.CheckBox]::new()
    $disableAutoUpdateCheck.Text = "Disable JetKVM auto update"
    $disableAutoUpdateCheck.Checked = $true
    $disableAutoUpdateCheck.Dock = "Fill"
    Set-CheckStyle $disableAutoUpdateCheck

    $keyboardLayoutBox = New-OptionBox @(
        (New-Option "English (UK) - JetKVM en-UK" "en-UK"),
        (New-Option "English (US) - JetKVM default" "en-US")
    ) "en-UK"

    $displayBrightnessBox = New-OptionBox @(
        (New-Option "Off (0)" 0),
        (New-Option "Low (10)" 10),
        (New-Option "Medium (35)" 35),
        (New-Option "High (64) - JetKVM default" 64)
    ) 10

    $dimDisplayBox = New-OptionBox @(
        (New-Option "Never" 0),
        (New-Option "1 minute" 60),
        (New-Option "5 minutes" 300),
        (New-Option "10 minutes" 600),
        (New-Option "30 minutes - JetKVM default" 1800),
        (New-Option "1 hour" 3600)
    ) 60

    $offDisplayBox = New-OptionBox @(
        (New-Option "Never" 0),
        (New-Option "5 minutes" 300),
        (New-Option "10 minutes" 600),
        (New-Option "30 minutes - JetKVM default" 1800),
        (New-Option "1 hour" 3600)
    ) 300

    $hdmiSleepBox = New-OptionBox @(
        (New-Option "Disabled" -1),
        (New-Option "Enabled after 90 seconds" 90),
        (New-Option "JetKVM default (1 minute)" 0)
    ) -1

    $setNetworkHostnameCheck = [Windows.Forms.CheckBox]::new()
    $setNetworkHostnameCheck.Text = "Set network hostname"
    $setNetworkHostnameCheck.Checked = $false
    $setNetworkHostnameCheck.Dock = "Fill"
    Set-CheckStyle $setNetworkHostnameCheck
    $networkHostnameBox = New-Field ""
    $networkHostnameBox.Enabled = $false

    $domainBox = New-OptionBox @(
        (New-Option "DHCP provided" "dhcp"),
        (New-Option ".local" "local"),
        (New-Option "Custom domain" "custom")
    ) "dhcp"
    $customDomainBox = New-Field ""
    $customDomainBox.Enabled = $false

    $mdnsBox = New-OptionBox @(
        (New-Option "Disabled" "disabled"),
        (New-Option "Auto - JetKVM default" "auto"),
        (New-Option "IPv4 only" "ipv4_only"),
        (New-Option "IPv6 only" "ipv6_only")
    ) "disabled"

    $ipv6Box = New-OptionBox @(
        (New-Option "Disabled" "disabled"),
        (New-Option "SLAAC - JetKVM default" "slaac"),
        (New-Option "Link-local only" "link_local")
    ) "disabled"

    $deviceSettingsNote = [Windows.Forms.Label]::new()
    $deviceSettingsNote.Text = "Notes: hostname also updates /etc/hostname immediately, but reboot is still recommended before checking DHCP lease names. Local password should still be set in JetKVM Access UI. Hide Header/Status Bar are browser UI preferences, not device config."
    $deviceSettingsNote.Dock = "Fill"
    $deviceSettingsNote.ForeColor = $ui.Warn
    $deviceSettingsNote.Font = [Drawing.Font]::new("Segoe UI", 9)

    $applyDeviceSettingsButton = [Windows.Forms.Button]::new()
    $applyDeviceSettingsButton.Text = "Apply settings"
    $applyDeviceSettingsButton.Dock = "Fill"
    $applyDeviceSettingsButton.Margin = New-ScaledPadding 8 2 8 2
    Set-ButtonStyle $applyDeviceSettingsButton "Primary"

    $deviceSettingsGrid.Controls.Add($deviceSettingsIntro, 0, 0)
    $deviceSettingsGrid.SetColumnSpan($deviceSettingsIntro, 3)
    $deviceSettingsGrid.Controls.Add($disableAutoUpdateCheck, 1, 1)
    $deviceSettingsGrid.SetColumnSpan($disableAutoUpdateCheck, 2)
    $deviceSettingsGrid.Controls.Add((New-RowLabel "Keyboard layout"), 0, 2)
    $deviceSettingsGrid.Controls.Add($keyboardLayoutBox, 1, 2)
    $deviceSettingsGrid.SetColumnSpan($keyboardLayoutBox, 2)
    $deviceSettingsGrid.Controls.Add((New-RowLabel "Display brightness"), 0, 3)
    $deviceSettingsGrid.Controls.Add($displayBrightnessBox, 1, 3)
    $deviceSettingsGrid.SetColumnSpan($displayBrightnessBox, 2)
    $deviceSettingsGrid.Controls.Add((New-RowLabel "Dim display after"), 0, 4)
    $deviceSettingsGrid.Controls.Add($dimDisplayBox, 1, 4)
    $deviceSettingsGrid.SetColumnSpan($dimDisplayBox, 2)
    $deviceSettingsGrid.Controls.Add((New-RowLabel "Turn off display after"), 0, 5)
    $deviceSettingsGrid.Controls.Add($offDisplayBox, 1, 5)
    $deviceSettingsGrid.SetColumnSpan($offDisplayBox, 2)
    $deviceSettingsGrid.Controls.Add((New-RowLabel "HDMI sleep mode"), 0, 6)
    $deviceSettingsGrid.Controls.Add($hdmiSleepBox, 1, 6)
    $deviceSettingsGrid.SetColumnSpan($hdmiSleepBox, 2)
    $deviceSettingsGrid.Controls.Add($setNetworkHostnameCheck, 1, 7)
    $deviceSettingsGrid.SetColumnSpan($setNetworkHostnameCheck, 2)
    $deviceSettingsGrid.Controls.Add((New-RowLabel "Network hostname"), 0, 8)
    $deviceSettingsGrid.Controls.Add($networkHostnameBox, 1, 8)
    $deviceSettingsGrid.SetColumnSpan($networkHostnameBox, 2)
    $deviceSettingsGrid.Controls.Add((New-RowLabel "Domain"), 0, 9)
    $deviceSettingsGrid.Controls.Add($domainBox, 1, 9)
    $deviceSettingsGrid.SetColumnSpan($domainBox, 2)
    $deviceSettingsGrid.Controls.Add((New-RowLabel "Custom domain"), 0, 10)
    $deviceSettingsGrid.Controls.Add($customDomainBox, 1, 10)
    $deviceSettingsGrid.SetColumnSpan($customDomainBox, 2)
    $deviceSettingsGrid.Controls.Add((New-RowLabel "mDNS"), 0, 11)
    $deviceSettingsGrid.Controls.Add($mdnsBox, 1, 11)
    $deviceSettingsGrid.SetColumnSpan($mdnsBox, 2)
    $deviceSettingsGrid.Controls.Add((New-RowLabel "IPv6 mode"), 0, 12)
    $deviceSettingsGrid.Controls.Add($ipv6Box, 1, 12)
    $deviceSettingsGrid.SetColumnSpan($ipv6Box, 2)
    $deviceSettingsGrid.Controls.Add($deviceSettingsNote, 0, 14)
    $deviceSettingsGrid.SetColumnSpan($deviceSettingsNote, 2)
    $deviceSettingsGrid.Controls.Add($applyDeviceSettingsButton, 2, 15)
    $settingsLayout.Controls.Add($deviceSettingsGroup, 0, 1)

    $logPanel = [Windows.Forms.TableLayoutPanel]::new()
    $logPanel.Dock = "Fill"
    $logPanel.BackColor = $ui.Window
    $logPanel.RowCount = 2
    $logPanel.ColumnCount = 2
    $logPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $logPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 130))) | Out-Null
    $logPanel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S 26))) | Out-Null
    $logPanel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $logTitle = [Windows.Forms.Label]::new()
    $logTitle.Text = "Status log"
    $logTitle.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $logTitle.Dock = "Fill"
    $logTitle.ForeColor = $ui.Text
    $copyLogsButton = [Windows.Forms.Button]::new()
    $copyLogsButton.Text = "Copy logs"
    $copyLogsButton.Dock = "Fill"
    $copyLogsButton.Margin = New-ScaledPadding 8 0 0 2
    Set-ButtonStyle $copyLogsButton "Secondary"
    $logBox = [Windows.Forms.RichTextBox]::new()
    $logBox.Dock = "Fill"
    $logBox.ScrollBars = "Vertical"
    $logBox.WordWrap = $false
    $logBox.ReadOnly = $true
    $logBox.BorderStyle = "FixedSingle"
    $logBox.BackColor = $ui.Log
    $logBox.ForeColor = $ui.Text
    $logBox.Font = [Drawing.Font]::new("Consolas", 9)
    $logPanel.Controls.Add($logTitle, 0, 0)
    $logPanel.Controls.Add($copyLogsButton, 1, 0)
    $logPanel.Controls.Add($logBox, 0, 1)
    $logPanel.SetColumnSpan($logBox, 2)
    $split.Panel2.Controls.Add($logPanel)

    $log = {
        param([string]$Message)
        $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
        $colour = $ui.Text
        if ($Message -match '^(ERROR|FAIL)|\bfailed\b|not found|not reachable|cancelled|invalid|authentication failed|permission denied|timed out|Timeout|rejected') {
            $colour = $ui.Bad
        } elseif ($Message -match '^(Warning|WARN)|NeedsLogin|Logged out|no current Tailscale IPs|not confirmed|did not receive|Continuing may still work|manual login|repair') {
            $colour = $ui.Warn
        } elseif ($Message -match 'https?://|login\.tailscale\.com') {
            $colour = $ui.Info
        } elseif ($Message -match '^---|\[[0-9]+/[0-9]+\]|Checking|Using|Downloading|Installing|Configuring|Starting') {
            $colour = $ui.Purple
        } elseif ($Message -match 'OK|confirmed|reachable|complete|found|available|copied|responded|SUCCESS|online|100\.[0-9]+\.[0-9]+\.[0-9]+') {
            $colour = $ui.Good
        }
        $logBox.SelectionStart = $logBox.TextLength
        $logBox.SelectionLength = 0
        $logBox.SelectionColor = $colour
        $logBox.AppendText($line + [Environment]::NewLine)
        $logBox.SelectionColor = $logBox.ForeColor
        $logBox.ScrollToCaret()
        [Windows.Forms.Application]::DoEvents()
    }

    $biosState = [pscustomobject]@{
        Scan = $null
    }

    $showDesktopPlaceholder = {
        param([string]$Text)
        if ($webUiState.Control) {
            try { $webUiState.Control.Dispose() } catch {}
            $webUiState.Control = $null
            $webUiState.Ready = $false
        }
        $desktopPlaceholder.Text = $Text
        $desktopBrowserHost.Controls.Clear()
        $desktopBrowserHost.Controls.Add($desktopPlaceholder)
    }

    $initialiseEmbeddedWebUi = {
        if ($webUiState.RemovalPending) {
            throw "Embedded Web UI removal is scheduled. Close and reopen JetFUEL before installing or opening it again."
        }
        if ($webUiState.Control -and $webUiState.Ready) { return $webUiState.Control }

        $support = Import-JetFuelWebView2Support
        $runtimeVersion = Get-JetFuelWebView2RuntimeVersion
        if ([string]::IsNullOrWhiteSpace($runtimeVersion)) {
            throw "Microsoft Edge WebView2 Runtime is not available. Use Install Web UI to install or repair it."
        }

        $browser = [Microsoft.Web.WebView2.WinForms.WebView2]::new()
        $browser.Dock = "Fill"
        $browser.BackColor = $ui.Log
        $creation = [Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties]::new()
        $creation.UserDataFolder = Join-Path $env:LOCALAPPDATA "JetFUEL\webview2-user-data"
        $browser.CreationProperties = $creation
        $desktopBrowserHost.Controls.Clear()
        $desktopBrowserHost.Controls.Add($browser)

        $task = $browser.EnsureCoreWebView2Async($null)
        $deadline = (Get-Date).AddSeconds(30)
        while (-not $task.IsCompleted -and (Get-Date) -lt $deadline) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 40
        }
        if (-not $task.IsCompleted) {
            $browser.Dispose()
            throw "The embedded browser did not initialise within 30 seconds."
        }
        if ($task.IsFaulted) {
            $message = $task.Exception.GetBaseException().Message
            $browser.Dispose()
            throw "The embedded browser failed to initialise: $message"
        }

        $browser.CoreWebView2.Settings.IsStatusBarEnabled = $false
        $browser.CoreWebView2.Settings.IsZoomControlEnabled = $true
        $browser.CoreWebView2.Settings.AreDefaultContextMenusEnabled = $true
        $browser.Add_NavigationStarting({
            param($sender, $eventArgs)
            $desktopStatusLabel.Text = "Loading $($eventArgs.Uri)..."
            $desktopStatusLabel.ForeColor = $ui.Info
        })
        $browser.Add_NavigationCompleted({
            param($sender, $eventArgs)
            if ($eventArgs.IsSuccess) {
                $desktopStatusLabel.Text = "Connected inside JetFUEL: $($sender.Source.Host)"
                $desktopStatusLabel.ForeColor = $ui.Good
            } else {
                $desktopStatusLabel.Text = "Web UI navigation failed: $($eventArgs.WebErrorStatus)"
                $desktopStatusLabel.ForeColor = $ui.Bad
            }
            $webBackButton.Enabled = $sender.CanGoBack
            $webForwardButton.Enabled = $sender.CanGoForward
        })
        $webUiState.Control = $browser
        $webUiState.Ready = $true
        $desktopStatusLabel.Text = "Embedded browser ready: SDK $($support.Version), runtime $runtimeVersion"
        $desktopStatusLabel.ForeColor = $ui.Good
        return $browser
    }

    $openEmbeddedWebUi = {
        param([string]$Address)
        $uri = Get-JetKvmWebUri -Address $Address
        $browser = & $initialiseEmbeddedWebUi
        $desktopWebAddressBox.Text = $uri.GetLeftPart([UriPartial]::Authority)
        $browser.Source = $uri
        & $log "Opened the JetKVM Web UI inside JetFUEL for $($uri.Host)."
    }

    $refreshDesktopStatus = {
        try {
            if ($webUiState.RemovalPending) {
                $desktopStatusLabel.Text = "Embedded Web UI removal is scheduled for exit"
                $desktopStatusLabel.ForeColor = $ui.Warn
                $installDesktopButton.Text = "Restart required"
                $installDesktopButton.Enabled = $false
                $removeDesktopButton.Enabled = $false
                $openEmbeddedWebButton.Enabled = $false
                return
            }
            $desktopState = Get-JetFuelWebView2State
            if ($desktopState.Installed) {
                $runtimeVersion = Get-JetFuelWebView2RuntimeVersion
                if ([string]::IsNullOrWhiteSpace($runtimeVersion)) {
                    $desktopStatusLabel.Text = "Support installed; Microsoft WebView2 Runtime needs installation or repair"
                    $desktopStatusLabel.ForeColor = $ui.Warn
                    $installDesktopButton.Text = "Install runtime"
                    $installDesktopButton.Enabled = $true
                    $openEmbeddedWebButton.Enabled = $false
                } else {
                    $desktopStatusLabel.Text = "Ready inside JetFUEL: SDK $($desktopState.Version), runtime $runtimeVersion"
                    $desktopStatusLabel.ForeColor = $ui.Good
                    $installDesktopButton.Text = "Support installed"
                    $installDesktopButton.Enabled = $false
                    $openEmbeddedWebButton.Enabled = $true
                }
                $removeDesktopButton.Enabled = $true
            } else {
                $missingText = if ($desktopState.Missing.Count -gt 0) { " ($($desktopState.Missing -join ', ') missing)" } else { "" }
                $desktopStatusLabel.Text = "Embedded Web UI support is not installed$missingText"
                $desktopStatusLabel.ForeColor = $ui.Warn
                $installDesktopButton.Text = "Install Web UI"
                $installDesktopButton.Enabled = $true
                $openEmbeddedWebButton.Enabled = $false
                $removeDesktopButton.Enabled = Test-Path -LiteralPath $desktopState.Root
            }
        } catch {
            $desktopStatusLabel.Text = "Web UI status unavailable: $($_.Exception.Message)"
            $desktopStatusLabel.ForeColor = $ui.Bad
            $installDesktopButton.Enabled = $true
            $openEmbeddedWebButton.Enabled = $false
            $removeDesktopButton.Enabled = $false
        }
        $webBackButton.Enabled = $false
        $webForwardButton.Enabled = $false
        if ($webUiState.Ready -and $null -ne $webUiState.Control) {
            $webBackButton.Enabled = $webUiState.Control.CanGoBack
            $webForwardButton.Enabled = $webUiState.Control.CanGoForward
        }
        $webRefreshButton.Enabled = $webUiState.Ready
    }
    & $refreshDesktopStatus

    $setBusy = {
        param([bool]$Busy, [string]$Status)
        $runButton.Enabled = -not $Busy
        $preflightButton.Enabled = -not $Busy
        $checkTailscaleButton.Enabled = -not $Busy
        $repairTailscaleButton.Enabled = -not $Busy
        $removeTailscaleButton.Enabled = -not $Busy
        if ($Busy) {
            $installDesktopButton.Enabled = $false
            $openEmbeddedWebButton.Enabled = $false
            $webBackButton.Enabled = $false
            $webForwardButton.Enabled = $false
            $webRefreshButton.Enabled = $false
            $webExternalButton.Enabled = $false
            $removeDesktopButton.Enabled = $false
        } else {
            & $refreshDesktopStatus
            $webExternalButton.Enabled = $true
        }
        $refreshMacButton.Enabled = -not $Busy
        $generateMacButton.Enabled = -not $Busy
        $applyMacButton.Enabled = -not $Busy
        $clearMacButton.Enabled = -not $Busy
        $scanThisPcButton.Enabled = -not $Busy
        $scanWolAdaptersButton.Enabled = -not $Busy
        $applyWolButton.Enabled = -not $Busy
        $applyEdidButton.Enabled = (-not $Busy) -and $displayChoiceBox.Enabled -and ($null -ne $displayChoiceBox.SelectedItem)
        $applyUsbButton.Enabled = (-not $Busy) -and $usbChoiceBox.Enabled -and ($null -ne $usbChoiceBox.SelectedItem)
        $applyDeviceSettingsButton.Enabled = -not $Busy
        $scanBiosButton.Enabled = -not $Busy
        $applyBiosButton.Enabled = (-not $Busy) -and $biosState.Scan -and $biosState.Scan.VendorInfo.Supported -and $biosState.Scan.Targets -and ($biosState.Scan.Targets.ApplyRows.Count -gt 0)
        foreach ($diagnosticButton in @(
            $quickDiagnosticsButton, $saveDiagnosticsButton, $viewAppLogButton, $viewCrashLogsButton,
            $rebootJetKvmButton, $forceRebootJetKvmButton, $powerCycleHelpButton,
            $openOtaButton, $manualAppUpdateButton, $driverAssistantButton, $socToolkitButton,
            $recoveryImageButton, $recoveryGuideButton
        )) {
            $diagnosticButton.Enabled = -not $Busy
        }
        $collectInventoryButton.Enabled = -not $Busy
        $saveInventoryButton.Enabled = (-not $Busy) -and ($null -ne $inventoryState.Data)
        $copyInventoryButton.Enabled = (-not $Busy) -and ($null -ne $inventoryState.Data)
        $openInventoryReportButton.Enabled = (-not $Busy) -and -not [string]::IsNullOrWhiteSpace([string]$inventoryState.ReportPath)
        $exitButton.Enabled = -not $Busy
        $statusLabel.Text = $Status
        [Windows.Forms.Application]::DoEvents()
    }

    $installDesktopButton.Add_Click({
        try {
            & $setBusy $true "Installing Web UI..."
            $installedState = Install-JetFuelWebView2Support -Log $log
            [void](& $initialiseEmbeddedWebUi)
            & $setBusy $false "Embedded Web UI ready"
            if (-not [string]::IsNullOrWhiteSpace($ipBox.Text)) {
                $desktopWebAddressBox.Text = $ipBox.Text.Trim()
            }
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Web UI install failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL Web UI", "OK", "Error") | Out-Null
        }
    })
    $openEmbeddedWebButton.Add_Click({
        try {
            $address = $desktopWebAddressBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($address)) { $address = $ipBox.Text.Trim() }
            if ([string]::IsNullOrWhiteSpace($address)) {
                throw "Enter a JetKVM address here or on the Setup tab first."
            }
            & $openEmbeddedWebUi $address
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL Web UI", "OK", "Error") | Out-Null
        }
    })
    $webBackButton.Add_Click({ if ($webUiState.Ready -and $webUiState.Control.CanGoBack) { $webUiState.Control.GoBack() } })
    $webForwardButton.Add_Click({ if ($webUiState.Ready -and $webUiState.Control.CanGoForward) { $webUiState.Control.GoForward() } })
    $webRefreshButton.Add_Click({ if ($webUiState.Ready) { $webUiState.Control.Reload() } })
    $webExternalButton.Add_Click({
        try {
            $address = $desktopWebAddressBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($address)) { $address = $ipBox.Text.Trim() }
            $uri = Get-JetKvmWebUri -Address $address
            Start-Process $uri.AbsoluteUri
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL Web UI", "OK", "Error") | Out-Null
        }
    })
    $removeDesktopButton.Add_Click({
        try {
            $answer = [Windows.Forms.MessageBox]::Show(
                "Remove JetFUEL's private embedded Web UI support and browser cache?`r`n`r`nThe shared Microsoft Edge WebView2 Runtime, JetKVM devices, and SSH keys are not removed. Loaded files may finish deleting after JetFUEL exits.",
                "Remove Web UI support",
                "YesNo",
                "Warning"
            )
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
            & $setBusy $true "Uninstalling Web UI..."
            & $showDesktopPlaceholder "Embedded Web UI support has been removed or scheduled for removal. Close JetFUEL to finish cleanup."
            Remove-JetFuelWebView2Support -Log $log
            Remove-JetKvmDesktopClient -Log $log -StopRunning
            $webUiState.RemovalPending = $true
            & $setBusy $false "Web UI removal scheduled"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Web UI uninstall failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL Web UI", "OK", "Error") | Out-Null
        }
    })

    $setIndicator = {
        param(
            [Windows.Forms.Label]$Label,
            [ValidateSet("Pending", "OK", "Warn", "Fail")][string]$State,
            [string]$Text
        )
        switch ($State) {
            "OK" { $Label.Text = "[OK] $Text"; $Label.ForeColor = $ui.Good }
            "Warn" { $Label.Text = "[WARN] $Text"; $Label.ForeColor = $ui.Warn }
            "Fail" { $Label.Text = "[FAIL] $Text"; $Label.ForeColor = $ui.Bad }
            default { $Label.Text = "[ ] $Text"; $Label.ForeColor = $ui.Text }
        }
        [Windows.Forms.Application]::DoEvents()
    }

    $refreshBiosReport = {
        param($Scan)
        if (-not $Scan) {
            $biosVendorValue.Text = "Not scanned"
            $biosModelValue.Text = "Not scanned"
            $biosVersionValue.Text = "Not scanned"
            $biosSupportValue.Text = "Not scanned"
            $biosSupportValue.ForeColor = $ui.Muted
            $biosReportBox.Text = "Click Scan BIOS to detect Dell/HP/Lenovo firmware support and preview the settings JetFUEL can change."
            $applyBiosButton.Enabled = $false
            return
        }

        $vendor = $Scan.VendorInfo
        $biosVendorValue.Text = if ($vendor.Manufacturer) { $vendor.Manufacturer } else { "Unknown" }
        $biosModelValue.Text = if ($vendor.Model) { $vendor.Model } else { "Unknown" }
        $biosVersionValue.Text = if ($vendor.BiosVersion) { $vendor.BiosVersion } else { "Unknown" }
        if ($vendor.Supported) {
            $biosSupportValue.Text = "$($vendor.DisplayVendor) supported"
            $biosSupportValue.ForeColor = $ui.Good
            $Scan.Targets = Resolve-BiosTargetSettings -VendorKey $vendor.VendorKey -Settings $Scan.Settings -EnableWakeOnLan $biosWolCheck.Checked -PowerOnAfterAc $biosAcPowerCheck.Checked -DisablePowerBlockers $biosPowerBlockersCheck.Checked
            $biosReportBox.Text = Format-BiosTargetReport -VendorInfo $vendor -Targets $Scan.Targets
            $applyBiosButton.Enabled = ($Scan.Targets.ApplyRows.Count -gt 0)
        } else {
            $biosSupportValue.Text = "Unsupported manufacturer"
            $biosSupportValue.ForeColor = $ui.Warn
            $biosReportBox.Text = "This BIOS manufacturer is not supported by the bundled ConfigJon scripts.`r`n`r`nDetected: $($vendor.Manufacturer) $($vendor.Model)`r`n`r`nSupported vendors: Dell, HP, Lenovo."
            $applyBiosButton.Enabled = $false
        }
    }

    $biosOptionChanged = {
        if ($biosState.Scan) {
            & $refreshBiosReport $biosState.Scan
        }
    }
    $biosWolCheck.Add_CheckedChanged($biosOptionChanged)
    $biosAcPowerCheck.Add_CheckedChanged($biosOptionChanged)
    $biosPowerBlockersCheck.Add_CheckedChanged($biosOptionChanged)

    $scanBiosButton.Add_Click({
        try {
            & $setBusy $true "Scanning BIOS..."
            & $log "--- BIOS prep scan ---"
            $scan = Invoke-BiosSettingsScan -EnableWakeOnLan $biosWolCheck.Checked -PowerOnAfterAc $biosAcPowerCheck.Checked -DisablePowerBlockers $biosPowerBlockersCheck.Checked -Log $log
            $biosState.Scan = $scan
            & $refreshBiosReport $scan
            if ($scan.VendorInfo.Supported) {
                & $setBusy $false "BIOS scan complete"
            } else {
                & $setBusy $false "BIOS unsupported"
                [Windows.Forms.MessageBox]::Show(
                    "This local PC manufacturer is not currently supported for BIOS prep.`r`n`r`nDetected: $($scan.VendorInfo.Manufacturer) $($scan.VendorInfo.Model)`r`n`r`nSupported vendors: Dell, HP, Lenovo.",
                    "BIOS unsupported",
                    "OK",
                    "Warning"
                ) | Out-Null
            }
        } catch {
            $biosState.Scan = $null
            & $refreshBiosReport $null
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $applyBiosButton.Add_Click({
        try {
            if (-not $biosState.Scan) { throw "Run Scan BIOS before applying BIOS prep." }
            if (-not $biosState.Scan.VendorInfo.Supported) { throw "This PC vendor is not supported for BIOS prep." }
            & $refreshBiosReport $biosState.Scan
            $targets = $biosState.Scan.Targets
            if (-not $targets -or $targets.ApplyRows.Count -eq 0) {
                [Windows.Forms.MessageBox]::Show("No BIOS changes are needed or available for the selected options.", "BIOS prep", "OK", "Information") | Out-Null
                return
            }

            $summary = @(
                "Vendor: $($biosState.Scan.VendorInfo.DisplayVendor)",
                "Model: $($biosState.Scan.VendorInfo.Model)",
                "",
                "Settings to write:"
            )
            foreach ($row in $targets.ApplyRows) {
                $summary += " - $($row.Name) = $($row.Value) ($($row.Reason))"
            }
            $summary += ""
            $summary += "PXE/network boot order will not be changed."
            $summary += "BIOS passwords are used only for this run and are not saved."

            $answer = [Windows.Forms.MessageBox]::Show(
                "Apply BIOS prep to this local Windows PC?`r`n`r`n$($summary -join "`r`n")`r`n`r`nThis writes firmware settings. Continue only if you are allowed to manage this machine.",
                "Apply BIOS prep",
                "YesNo",
                "Warning"
            )
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                & $log "BIOS prep cancelled."
                return
            }

            & $setBusy $true "Applying BIOS prep..."
            & $log "--- BIOS prep apply ---"
            $result = Invoke-BiosSettingsApply -Scan $biosState.Scan -EnableWakeOnLan $biosWolCheck.Checked -PowerOnAfterAc $biosAcPowerCheck.Checked -DisablePowerBlockers $biosPowerBlockersCheck.Checked -BiosPassword $biosPasswordBox.Text -SystemManagementPassword $biosSmPasswordBox.Text -Log $log
            $biosPasswordBox.Text = ""
            $biosSmPasswordBox.Text = ""
            if ($result.Changed) {
                & $log $result.Message
                [Windows.Forms.MessageBox]::Show($result.Message, "BIOS prep complete", "OK", "Information") | Out-Null
            } else {
                & $log $result.Message
                [Windows.Forms.MessageBox]::Show($result.Message, "BIOS prep", "OK", "Information") | Out-Null
            }

            $biosState.Scan = Invoke-BiosSettingsScan -EnableWakeOnLan $biosWolCheck.Checked -PowerOnAfterAc $biosAcPowerCheck.Checked -DisablePowerBlockers $biosPowerBlockersCheck.Checked -Log $log
            & $refreshBiosReport $biosState.Scan
            & $setBusy $false "BIOS prep complete"
        } catch {
            $biosPasswordBox.Text = ""
            $biosSmPasswordBox.Text = ""
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $noPassCheck.Add_CheckedChanged({
        $passBox.Enabled = -not $noPassCheck.Checked
        if ($noPassCheck.Checked) { $passBox.Text = "" }
    })
    $useAuthKeyCheck.Add_CheckedChanged({
        $authBox.Enabled = $useAuthKeyCheck.Checked
        if (-not $useAuthKeyCheck.Checked) { $authBox.Text = "" }
    })
    $copyLogsButton.Add_Click({
        try {
            [Windows.Forms.Clipboard]::SetText($logBox.Text)
            & $log "Logs copied to clipboard."
        } catch {
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })
    $exitButton.Add_Click({
        $choice = [Windows.Forms.MessageBox]::Show(
            "Exit JetFUEL?`r`n`r`nYes = remove JetFUEL's private embedded Web UI support and browser cache, clean up JetFUEL temp/downloaded files, optionally uninstall Git Bash, then exit.`r`nNo = exit only and leave installed tools in place.`r`nCancel = stay here.`r`n`r`nThe shared Microsoft Edge WebView2 Runtime and SSH key files are always left in place.",
            "Exit JetFUEL",
            "YesNoCancel",
            "Warning"
        )
        if ($choice -eq [Windows.Forms.DialogResult]::Cancel) { return }

        if ($choice -eq [Windows.Forms.DialogResult]::Yes) {
            try {
                & $setBusy $true "Cleaning up..."
                & $showDesktopPlaceholder "JetFUEL is cleaning up embedded Web UI files..."
                Invoke-JetFuelCleanup -Log $log
                & $setBusy $false "Cleanup complete"
            } catch {
                $message = Get-CleanExceptionMessage -ErrorRecord $_
                & $log "ERROR: Cleanup failed: $message"
                & $setBusy $false "Cleanup failed"
                $exitAnyway = [Windows.Forms.MessageBox]::Show(
                    "Cleanup hit a problem:`r`n`r`n$message`r`n`r`nExit JetFUEL anyway?",
                    "Cleanup failed",
                    "YesNo",
                    "Warning"
                )
                if ($exitAnyway -ne [Windows.Forms.DialogResult]::Yes) { return }
            }
        }

        $form.Close()
    })
    $form.Add_FormClosing({
        if ($webUiState.Control) {
            try { $webUiState.Control.Dispose() } catch {}
            $webUiState.Control = $null
            $webUiState.Ready = $false
        }
    })
    $normalisingHostV2 = $false
    $hostBox.Add_TextChanged({
        if ($normalisingHostV2) { return }
        $current = $hostBox.Text
        $clean = ConvertTo-TailscaleHostname -Value $current
        if ($current -cne $clean) {
            $normalisingHostV2 = $true
            $cursor = [Math]::Min($hostBox.SelectionStart, $clean.Length)
            $hostBox.Text = $clean
            $hostBox.SelectionStart = $cursor
            $normalisingHostV2 = $false
        }
    })
    $browseButton.Add_Click({
        $dialog = [Windows.Forms.SaveFileDialog]::new()
        $dialog.Title = "Choose SSH private key path"
        $dialog.FileName = [IO.Path]::GetFileName($keyBox.Text)
        $dialog.InitialDirectory = Split-Path -Parent $keyBox.Text
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $keyBox.Text = $dialog.FileName }
    })
    $browseInstallerButton.Add_Click({
        $dialog = [Windows.Forms.OpenFileDialog]::new()
        $dialog.Title = "Choose local Tailscale installer script"
        $dialog.Filter = "Shell scripts (*.sh)|*.sh|All files (*.*)|*.*"
        if (-not [string]::IsNullOrWhiteSpace($localInstallerPathBox.Text)) {
            $parent = Split-Path -Parent $localInstallerPathBox.Text
            if (Test-Path -LiteralPath $parent) { $dialog.InitialDirectory = $parent }
        }
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            $localInstallerPathBox.Text = $dialog.FileName
            $installerSourceBox.SelectedItem = "Local file"
        }
    })
    $setNetworkHostnameCheck.Add_CheckedChanged({
        $networkHostnameBox.Enabled = $setNetworkHostnameCheck.Checked
    })
    $domainBox.Add_SelectedIndexChanged({
        $customDomainBox.Enabled = ((Get-SelectedOptionValue $domainBox) -eq "custom")
    })
    $normalisingNetworkHostname = $false
    $networkHostnameBox.Add_TextChanged({
        if ($normalisingNetworkHostname) { return }
        $current = $networkHostnameBox.Text
        $clean = ConvertTo-TailscaleHostname -Value $current
        if ($current -cne $clean) {
            $normalisingNetworkHostname = $true
            $cursor = [Math]::Min($networkHostnameBox.SelectionStart, $clean.Length)
            $networkHostnameBox.Text = $clean
            $networkHostnameBox.SelectionStart = $cursor
            $normalisingNetworkHostname = $false
        }
    })
    $customDomainBox.Add_TextChanged({
        $current = $customDomainBox.Text
        $clean = $current.Trim().ToLowerInvariant()
        $clean = [regex]::Replace($clean, '[^a-z0-9.-]+', '-')
        $clean = [regex]::Replace($clean, '-{2,}', '-')
        if ($current -cne $clean) {
            $cursor = [Math]::Min($customDomainBox.SelectionStart, $clean.Length)
            $customDomainBox.Text = $clean
            $customDomainBox.SelectionStart = $cursor
        }
    })
    $applyDeviceSettingsButton.Add_Click({
        try {
            $ip = $ipBox.Text.Trim()
            $keyPath = $keyBox.Text.Trim()
            Assert-ValidIpOrHost -Value $ip
            if ([string]::IsNullOrWhiteSpace($keyPath)) { throw "Choose the SSH private key path before applying JetKVM settings." }

            $networkHostname = ""
            if ($setNetworkHostnameCheck.Checked) {
                $networkHostname = ConvertTo-TailscaleHostname -Value $networkHostnameBox.Text
                Assert-TailscaleHostname -Value $networkHostname
                if ([string]::IsNullOrWhiteSpace($networkHostname)) { throw "Network hostname is enabled but empty." }
                if ($networkHostnameBox.Text -cne $networkHostname) { $networkHostnameBox.Text = $networkHostname }
            }

            $domain = [string](Get-SelectedOptionValue $domainBox)
            if ($domain -eq "custom") {
                $domain = $customDomainBox.Text.Trim().ToLowerInvariant()
                Assert-JetKvmDomain -Value $domain
                $customDomainBox.Text = $domain
            }

            $summary = @(
                "Auto update: " + $(if ($disableAutoUpdateCheck.Checked) { "disabled" } else { "enabled" }),
                "Keyboard layout: $(Get-SelectedOptionValue $keyboardLayoutBox)",
                "Display brightness: $(Get-SelectedOptionValue $displayBrightnessBox)",
                "Dim display after: $(Get-SelectedOptionValue $dimDisplayBox)s",
                "Turn off display after: $(Get-SelectedOptionValue $offDisplayBox)s",
                "HDMI sleep mode: $(Get-SelectedOptionValue $hdmiSleepBox)",
                "Domain: $domain",
                "mDNS: $(Get-SelectedOptionValue $mdnsBox)",
                "IPv6 mode: $(Get-SelectedOptionValue $ipv6Box)"
            )
            if ($setNetworkHostnameCheck.Checked) { $summary += "Network hostname: $networkHostname" }

            $answer = [Windows.Forms.MessageBox]::Show(
                "Apply these JetKVM device settings?`r`n`r`n$($summary -join "`r`n")`r`n`r`nJetFUEL will back up /userdata/kvm_config.json, write the settings, then offer to reboot.",
                "Apply JetKVM settings",
                "YesNo",
                "Warning"
            )
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                & $log "JetKVM settings apply cancelled."
                return
            }

            & $setBusy $true "Applying JetKVM settings..."
            Update-JetKvmDeviceSettings `
                -JetKvmAddress $ip `
                -KeyPath $keyPath `
                -AutoUpdateEnabled (-not $disableAutoUpdateCheck.Checked) `
                -KeyboardLayout ([string](Get-SelectedOptionValue $keyboardLayoutBox)) `
                -DisplayMaxBrightness ([int](Get-SelectedOptionValue $displayBrightnessBox)) `
                -DisplayDimAfterSec ([int](Get-SelectedOptionValue $dimDisplayBox)) `
                -DisplayOffAfterSec ([int](Get-SelectedOptionValue $offDisplayBox)) `
                -VideoSleepAfterSec ([int](Get-SelectedOptionValue $hdmiSleepBox)) `
                -SetNetworkHostname $setNetworkHostnameCheck.Checked `
                -NetworkHostname $networkHostname `
                -Domain $domain `
                -MDNSMode ([string](Get-SelectedOptionValue $mdnsBox)) `
                -IPv6Mode ([string](Get-SelectedOptionValue $ipv6Box)) `
                -Log $log

            & $log "JetKVM device settings saved."
            & $rebootJetKvmAfterIdentity $ip $keyPath "JetKVM settings"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })
    $openAction = {
        try { Open-JetKvmUi -JetKvmAddress $ipBox.Text.Trim() }
        catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null }
    }
    $openUiButton.Add_Click($openAction)
    $openUiButton2.Add_Click($openAction)

    $getJetKvmSshTarget = {
        $ip = $ipBox.Text.Trim()
        $keyPath = $keyBox.Text.Trim()
        Assert-ValidIpOrHost -Value $ip
        if ([string]::IsNullOrWhiteSpace($keyPath)) {
            throw "Choose the SSH private key path on the Setup tab first."
        }
        if (-not (Test-Path -LiteralPath $keyPath)) {
            throw "SSH private key not found: $keyPath"
        }
        return [pscustomobject]@{ Ip = $ip; KeyPath = $keyPath }
    }

    $writeSshOutput = {
        param($Result)
        if ($Result.Output) {
            (Remove-AnsiEscapeSequences -Text $Result.Output) -split "`n" | ForEach-Object { & $log $_ }
        }
    }

    $collectInventoryButton.Add_Click({
        try {
            $target = & $getJetKvmSshTarget
            & $setBusy $true "Collecting inventory..."
            & $log "--- Collecting JetKVM device inventory ---"

            $inventory = Get-JetKvmInventory -JetKvmAddress $target.Ip -KeyPath $target.KeyPath
            & $log "--- Collecting local Windows PC inventory ---"
            $localInventory = Get-LocalWindowsInventory
            $inventory | Add-Member -MemberType NoteProperty -Name LocalComputer -Value $localInventory
            $inventoryState.Data = $inventory
            $inventoryState.ReportPath = $null

            $inventoryRows["KVM Make"].Text = $inventory.KvmMake
            $inventoryRows["KVM Model / Version"].Text = $inventory.KvmModelVersion
            $inventoryRows["Serial Number"].Text = $inventory.SerialNumber
            $inventoryRows["MAC"].Text = $inventory.MacAddress
            $inventoryRows["Hostname"].Text = $inventory.Hostname
            $inventoryRows["Tailscale Name"].Text = $inventory.TailscaleName
            $inventoryRows["Cloud Configured State"].Text = $inventory.CloudConfiguredState
            $inventoryRows["Cloud Configured State"].ForeColor = if ($inventory.CloudConfiguredState -eq "Configured") { $ui.Good } else { $ui.Warn }
            $localInventoryRows["PC Name"].Text = $localInventory.PcName
            $localInventoryRows["PC Make"].Text = $localInventory.PcMake
            $localInventoryRows["PC Model"].Text = $localInventory.PcModel
            $localInventoryRows["Windows Version"].Text = $localInventory.WindowsVersion
            $localInventoryRows["PC Serial Number"].Text = $localInventory.SerialNumber
            $localInventoryRows["PC MAC"].Text = $localInventory.MacAddress
            $localInventoryRows["CPU"].Text = $localInventory.Cpu
            $localInventoryRows["RAM (GB)"].Text = [string]$localInventory.RamGb
            $localInventoryRows["External IP"].Text = $localInventory.ExternalIp
            $inventoryPathLabel.Text = "Collected. Use Save report or Copy details; no file has been written."
            $inventoryPathLabel.ForeColor = $ui.Info

            & $log "[OK] KVM Make: $($inventory.KvmMake)"
            & $log "[OK] KVM Model/Version: $($inventory.KvmModelVersion)"
            & $log "[OK] Serial Number: $($inventory.SerialNumber)"
            & $log "[OK] MAC: $($inventory.MacAddress)"
            & $log "[OK] Hostname: $($inventory.Hostname)"
            & $log "[OK] Tailscale Name: $($inventory.TailscaleName)"
            & $log "[OK] Cloud Configured State: $($inventory.CloudConfiguredState)"
            & $log "[OK] Local Windows PC inventory included."
            if ($localInventory.ExternalIp -eq "Unavailable") {
                & $log "[WARN] External IP lookup was unavailable; the rest of the inventory was collected."
            }
            & $log "[OK] Inventory collected. No file was saved automatically."
            & $setBusy $false "Inventory collected"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Inventory failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetKVM inventory", "OK", "Error") | Out-Null
        }
    })

    $saveInventoryButton.Add_Click({
        try {
            if ($null -eq $inventoryState.Data) {
                throw "Collect the inventory first."
            }

            $identity = [string]$inventoryState.Data.Hostname
            if ([string]::IsNullOrWhiteSpace($identity) -or $identity -eq "Not available") {
                $identity = [string]$inventoryState.Data.SerialNumber
            }
            if ([string]::IsNullOrWhiteSpace($identity) -or $identity -eq "Not available") {
                $identity = [string]$inventoryState.Data.JetKvmAddress
            }
            $safeIdentity = ($identity -replace '[^A-Za-z0-9._-]', '_').Trim('_')
            if ([string]::IsNullOrWhiteSpace($safeIdentity)) { $safeIdentity = "JetKVM" }

            $saveDialog = [Windows.Forms.SaveFileDialog]::new()
            $saveDialog.Title = "Save deployment inventory"
            $saveDialog.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
            $saveDialog.DefaultExt = "txt"
            $saveDialog.AddExtension = $true
            $saveDialog.FileName = "JetFUEL-JetKVM-{0}-{1}.txt" -f $safeIdentity, (Get-Date -Format "yyyyMMdd-HHmmss")
            $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
            if (-not [string]::IsNullOrWhiteSpace($desktop) -and (Test-Path -LiteralPath $desktop)) {
                $saveDialog.InitialDirectory = $desktop
            }
            if ($saveDialog.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK) {
                return
            }

            $reportPath = Save-JetKvmInventoryReport -Inventory $inventoryState.Data -Path $saveDialog.FileName
            $inventoryState.ReportPath = $reportPath
            $inventoryPathLabel.Text = "Saved to: $reportPath"
            $inventoryPathLabel.ForeColor = $ui.Good
            $openInventoryReportButton.Enabled = $true
            & $log "[OK] Inventory report saved: $reportPath"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Deployment inventory", "OK", "Error") | Out-Null
        }
    })

    $copyInventoryButton.Add_Click({
        try {
            if ($null -eq $inventoryState.Data) {
                throw "Collect the JetKVM inventory first."
            }
            [Windows.Forms.Clipboard]::SetText((Format-JetKvmInventoryReport -Inventory $inventoryState.Data))
            & $log "[OK] JetKVM inventory details copied to the clipboard."
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetKVM inventory", "OK", "Error") | Out-Null
        }
    })

    $openInventoryReportButton.Add_Click({
        try {
            $reportPath = [string]$inventoryState.ReportPath
            if ([string]::IsNullOrWhiteSpace($reportPath) -or -not (Test-Path -LiteralPath $reportPath)) {
                throw "Save the inventory report first, or save it again if the previous report was moved."
            }
            Start-Process -FilePath $reportPath
            & $log "Opened inventory report: $reportPath"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetKVM inventory", "OK", "Error") | Out-Null
        }
    })

    $openDiagnosticUrl = {
        param([string]$Url, [string]$Description)
        try {
            Start-Process $Url
            & $log $Description
        } catch {
            & $log ("ERROR: Could not open $Url - " + $_.Exception.Message)
            [Windows.Forms.MessageBox]::Show("Could not open:`r`n$Url`r`n`r`n$($_.Exception.Message)", "JetFUEL diagnostics", "OK", "Error") | Out-Null
        }
    }

    $quickDiagnosticsButton.Add_Click({
        try {
            $target = & $getJetKvmSshTarget
            & $setBusy $true "Running diagnostics..."
            & $log "--- JetKVM quick diagnostics ---"
            $command = ConvertTo-JetKvmEncodedShellCommand -Script (Get-JetKvmQuickDiagnosticsCommand)
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $target.Ip -KeyPath $target.KeyPath -Command $command -TimeoutSeconds 75
            & $writeSshOutput $result
            if ($result.TimedOut) { throw "JetKVM quick diagnostics timed out after 75 seconds." }
            if ($result.ExitCode -ne 0) { throw "JetKVM quick diagnostics failed with exit code $($result.ExitCode)." }
            & $setBusy $false "Diagnostics complete"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL diagnostics", "OK", "Error") | Out-Null
        }
    })

    $saveDiagnosticsButton.Add_Click({
        $dialog = $null
        try {
            $target = & $getJetKvmSshTarget
            $safeTarget = $target.Ip -replace '[^A-Za-z0-9.-]', '_'
            $dialog = [Windows.Forms.SaveFileDialog]::new()
            $dialog.Title = "Save JetKVM diagnostic report"
            $dialog.Filter = "Text report (*.txt)|*.txt|All files (*.*)|*.*"
            $dialog.FileName = "JetKVM-diagnostics-$safeTarget-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
            if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
                & $log "Diagnostic report cancelled."
                return
            }
            $reportPath = $dialog.FileName

            & $setBusy $true "Collecting full report..."
            & $log "--- Collecting full JetKVM diagnostic report ---"
            $command = ConvertTo-JetKvmEncodedShellCommand -Script (Get-JetKvmFullDiagnosticsCommand)
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $target.Ip -KeyPath $target.KeyPath -Command $command -TimeoutSeconds 150
            & $writeSshOutput $result

            $header = @(
                "JetFUEL JetKVM diagnostic report",
                "Collected: $((Get-Date).ToString('o'))",
                "JetKVM target: $($target.Ip)",
                "Privacy notice: this report may contain IP/MAC addresses, device identifiers, and application log content.",
                ""
            ) -join [Environment]::NewLine
            $cleanReport = Remove-AnsiEscapeSequences -Text $result.Output
            [IO.File]::WriteAllText($reportPath, ($header + $cleanReport + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            & $log "Diagnostic report saved: $reportPath"

            if ($result.TimedOut) { throw "The full report timed out after 150 seconds. Partial output was saved to $reportPath" }
            if ($result.ExitCode -ne 0) { throw "The full report command exited with code $($result.ExitCode). Partial output was saved to $reportPath" }
            & $setBusy $false "Report saved"
            [Windows.Forms.MessageBox]::Show("Diagnostic report saved to:`r`n`r`n$reportPath`r`n`r`nReview it for identifying information before sharing.", "JetFUEL diagnostics", "OK", "Information") | Out-Null
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL diagnostics", "OK", "Error") | Out-Null
        } finally {
            if ($dialog) { $dialog.Dispose() }
        }
    })

    $viewAppLogButton.Add_Click({
        try {
            $target = & $getJetKvmSshTarget
            & $setBusy $true "Reading app log..."
            $command = ConvertTo-JetKvmEncodedShellCommand -Script "echo '--- /userdata/jetkvm/last.log (last 500 lines) ---'; if [ -f /userdata/jetkvm/last.log ]; then tail -n 500 /userdata/jetkvm/last.log 2>&1; else echo '[WARN] JetKVM app log was not found'; fi"
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $target.Ip -KeyPath $target.KeyPath -Command $command -TimeoutSeconds 60
            & $writeSshOutput $result
            if ($result.TimedOut) { throw "Reading the JetKVM app log timed out." }
            if ($result.ExitCode -ne 0) { throw "Reading the JetKVM app log failed with exit code $($result.ExitCode)." }
            & $setBusy $false "App log loaded"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL diagnostics", "OK", "Error") | Out-Null
        }
    })

    $viewCrashLogsButton.Add_Click({
        try {
            $target = & $getJetKvmSshTarget
            & $setBusy $true "Reading crash logs..."
            $command = ConvertTo-JetKvmEncodedShellCommand -Script (Get-JetKvmCrashLogsCommand)
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $target.Ip -KeyPath $target.KeyPath -Command $command -TimeoutSeconds 75
            & $writeSshOutput $result
            if ($result.TimedOut) { throw "Reading the JetKVM crash logs timed out." }
            if ($result.ExitCode -ne 0) { throw "Reading the JetKVM crash logs failed with exit code $($result.ExitCode)." }
            & $setBusy $false "Crash logs loaded"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL diagnostics", "OK", "Error") | Out-Null
        }
    })

    $rebootJetKvmButton.Add_Click({
        try {
            $target = & $getJetKvmSshTarget
            $answer = [Windows.Forms.MessageBox]::Show("Request a normal JetKVM reboot now?", "Reboot JetKVM", "YesNo", "Question")
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
            & $setBusy $true "Requesting reboot..."
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $target.Ip -KeyPath $target.KeyPath -Command "sync; echo '[OK] normal reboot requested'; ( sleep 1; reboot ) >/dev/null 2>&1 &" -TimeoutSeconds 8
            & $writeSshOutput $result
            if ($result.Output -notmatch '\[OK\] normal reboot requested') {
                throw "JetKVM did not acknowledge the reboot request. Check SSH access and the diagnostic log."
            }
            & $log "Reboot command sent. SSH and the web UI will be unavailable while JetKVM restarts."
            & $setBusy $false "JetKVM rebooting"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL diagnostics", "OK", "Error") | Out-Null
        }
    })

    $forceRebootJetKvmButton.Add_Click({
        try {
            $target = & $getJetKvmSshTarget
            $answer = [Windows.Forms.MessageBox]::Show("Force reboot skips the normal orderly shutdown path and can risk filesystem damage.`r`n`r`nUse it only when a normal reboot does not work. It is NOT an electrical power cycle.`r`n`r`nContinue?", "Force reboot JetKVM", "YesNo", "Warning")
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
            & $setBusy $true "Requesting force reboot..."
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $target.Ip -KeyPath $target.KeyPath -Command "sync; echo '[WARN] force reboot requested'; ( sleep 1; reboot -f ) >/dev/null 2>&1 &" -TimeoutSeconds 8
            & $writeSshOutput $result
            if ($result.Output -notmatch '\[WARN\] force reboot requested') {
                throw "JetKVM did not acknowledge the force-reboot request. Check SSH access and the diagnostic log."
            }
            & $log "Force reboot command sent. SSH and the web UI will be unavailable while JetKVM restarts."
            & $setBusy $false "JetKVM force rebooting"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL diagnostics", "OK", "Error") | Out-Null
        }
    })

    $powerCycleHelpButton.Add_Click({
        [Windows.Forms.MessageBox]::Show(
            "JetKVM cannot electrically power-cycle itself: after its input power is removed, its software cannot turn that power back on.`r`n`r`nFor a full power cycle, remove and restore USB power physically or use an independently controlled USB/PoE switch or smart plug.`r`n`r`nReboot and Force reboot only restart Linux; they do not remove electrical power.",
            "Full JetKVM power cycle",
            "OK",
            "Information"
        ) | Out-Null
    })

    $openOtaButton.Add_Click({
        try {
            Open-JetKvmUi -JetKvmAddress $ipBox.Text.Trim()
            & $log "Opened JetKVM UI. Use Settings > General > Check for Updates for the normal OTA update path."
            [Windows.Forms.MessageBox]::Show("In the JetKVM UI, open Settings > General and choose Check for Updates. This is the recommended way to update both supported components through the normal rollout.", "JetKVM OTA update", "OK", "Information") | Out-Null
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL diagnostics", "OK", "Error") | Out-Null
        }
    })

    $manualAppUpdateButton.Add_Click({
        try {
            $target = & $getJetKvmSshTarget
            $answer = [Windows.Forms.MessageBox]::Show(
                "Use JetKVM's official OTA UI whenever possible.`r`n`r`nThis advanced fallback queries JetKVM's official release API for this hardware SKU, verifies the app SHA-256, stages only the app component, and reboots. It bypasses staged rollout and does not update the system image.`r`n`r`nContinue?",
                "Manual JetKVM app update",
                "YesNo",
                "Warning"
            )
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
            & $setBusy $true "Updating JetKVM app..."
            & $log "--- Manual JetKVM app update ---"
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $target.Ip -KeyPath $target.KeyPath -Command (Get-JetKvmManualAppUpdateCommand) -TimeoutSeconds 180
            & $writeSshOutput $result
            $staged = $result.Output -match '\[OK\] verified app update staged'
            if (-not $staged) {
                if ($result.TimedOut) { throw "Manual app update timed out before JetFUEL saw the verified staging confirmation." }
                throw "Manual app update failed with exit code $($result.ExitCode). Check the diagnostic log before retrying."
            }
            & $log "Verified app update was staged. JetKVM is rebooting."
            & $setBusy $false "JetKVM updating"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL diagnostics", "OK", "Error") | Out-Null
        }
    })

    $driverAssistantButton.Add_Click({
        & $openDiagnosticUrl "https://github.com/jetkvm/rv1106-system/releases/download/v0.2.5/DriverAssitant_v5.14.zip" "Opened official JetKVM/Rockchip DriverAssistant v5.14 download. This is a DFU recovery USB driver, not a routine Windows driver update."
    })
    $socToolkitButton.Add_Click({
        & $openDiagnosticUrl "https://github.com/jetkvm/rv1106-system/releases/download/v0.2.5/SocToolKit_v2.5_20250701_01_win.zip" "Opened official JetKVM/Rockchip SocToolKit v2.5 download for manual DFU recovery."
    })
    $recoveryImageButton.Add_Click({
        $answer = [Windows.Forms.MessageBox]::Show("Open the latest official jetkvm-v2 system recovery image?`r`n`r`nDFU flashing can erase/reset the JetKVM. Confirm the hardware SKU and follow the official recovery guide before using this image.", "JetKVM recovery image", "YesNo", "Warning")
        if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
            & $openDiagnosticUrl "https://api.jetkvm.com/releases/system_recovery/latest?sku=jetkvm-v2" "Opened official latest jetkvm-v2 recovery image endpoint."
        }
    })
    $recoveryGuideButton.Add_Click({
        & $openDiagnosticUrl "https://jetkvm.com/docs/advanced-usage/factory-reset-dfu" "Opened the official JetKVM factory reset / DFU recovery guide."
    })

    $copyKeyButton.Add_Click({
        try {
            $keyPath = $keyBox.Text.Trim()
            if ($createKeyCheck.Checked -and -not (Test-Path -LiteralPath "$keyPath.pub")) {
                $passphrase = if ($noPassCheck.Checked) { "" } else { $passBox.Text }
                New-SshKeyPair -KeyPath $keyPath -Passphrase $passphrase -Log $log
            }
            [Windows.Forms.Clipboard]::SetText((Get-PublicKeyText -KeyPath $keyPath))
            & $log "Public key copied to clipboard. Paste it into JetKVM Settings > Advanced > Developer Mode."
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $getSelectedMacProfile = {
        $selectedName = [string]$macProfileBox.SelectedItem
        foreach ($profile in $macProfiles) {
            if ($profile.Name -eq $selectedName) { return $profile }
        }
        return $macProfiles[0]
    }

    $macProfileBox.Add_SelectedIndexChanged({
        $profile = & $getSelectedMacProfile
        $macProfileHelp.Text = $profile.Description
    })

    $refreshMacStatus = {
        $ip = $ipBox.Text.Trim()
        $keyPath = $keyBox.Text.Trim()
        Assert-ValidIpOrHost -Value $ip
        $cmd = @"
echo '--- mac identity ---'
active=`$(cat /sys/class/net/eth0/address 2>/dev/null || ifconfig eth0 2>/dev/null | awk '/HWaddr|ether/{print `$5; exit}')
echo "active=`$active"
if [ -f /userdata/jetkvm/mac_address ]; then echo "user_override=`$(cat /userdata/jetkvm/mac_address)"; else echo "user_override=<none>"; fi
if [ -f /userdata/.mac_address ]; then echo "system_mac=`$(cat /userdata/.mac_address)"; else echo "system_mac=<none>"; fi
if [ -f /data/ethaddr.txt ]; then echo "legacy_override=`$(cat /data/ethaddr.txt)"; else echo "legacy_override=<none>"; fi
echo '--- mac identity complete ---'
"@
        $result = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command $cmd -TimeoutSeconds 25
        if ($result.Output) { $result.Output -split "`n" | ForEach-Object { & $log $_ } }
        if ($result.ExitCode -ne 0) { throw "MAC status check failed with exit code $($result.ExitCode)." }

        $activeMatch = [regex]::Match($result.Output, '(?im)^active=([0-9A-Fa-f:]{17})')
        $overrideMatch = [regex]::Match($result.Output, '(?im)^user_override=(.+)$')
        $systemMatch = [regex]::Match($result.Output, '(?im)^system_mac=(.+)$')
        if ($activeMatch.Success) {
            $macCurrentLabel.Text = "Current JetKVM MAC: " + $activeMatch.Groups[1].Value.ToUpperInvariant()
            $macCurrentLabel.ForeColor = $ui.Good
        } else {
            $macCurrentLabel.Text = "Current JetKVM MAC: not detected"
            $macCurrentLabel.ForeColor = $ui.Warn
        }
        $overrideText = if ($overrideMatch.Success) { $overrideMatch.Groups[1].Value.Trim() } else { "<unknown>" }
        $systemText = if ($systemMatch.Success) { $systemMatch.Groups[1].Value.Trim() } else { "<unknown>" }
        $macOverrideLabel.Text = "User override: $overrideText    System MAC file: $systemText"
        $macOverrideLabel.ForeColor = if ($overrideText -eq "<none>") { $ui.Muted } else { $ui.Warn }
    }

    $generateMacButton.Add_Click({
        try {
            $profile = & $getSelectedMacProfile
            $macBox.Text = New-MacAddressFromProfile -Profile $profile
            & $log "Generated $($profile.Name) MAC: $($macBox.Text)"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $macBox.Add_Leave({
        $macBox.Text = Format-MacAddress -Value $macBox.Text
    })

    $refreshMacButton.Add_Click({
        try {
            & $setBusy $true "Checking MAC identity..."
            & $refreshMacStatus
            & $setBusy $false "MAC check complete"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $applyMacButton.Add_Click({
        try {
            $mac = Format-MacAddress -Value $macBox.Text
            $macBox.Text = $mac
            Assert-MacAddress -MacAddress $mac
            if (-not (Test-MacAddressIsLocalAdministered -MacAddress $mac)) {
                $answerGlobal = [Windows.Forms.MessageBox]::Show(
                    "This MAC is not locally administered. That means it may belong to a real vendor range.`r`n`r`nUse a generated local-administered MAC unless you have a specific reason to override it.`r`n`r`nContinue anyway?",
                    "Global MAC warning",
                    "YesNo",
                    "Warning"
                )
                if ($answerGlobal -ne [Windows.Forms.DialogResult]::Yes) { return }
            }
            $answer = [Windows.Forms.MessageBox]::Show(
                "Write this MAC override to the JetKVM?`r`n`r`n$mac`r`n`r`nThe JetKVM will need to reboot before Ethernet uses it. Its IP address may change after reboot.",
                "Apply JetKVM MAC override",
                "YesNo",
                "Warning"
            )
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                & $log "MAC override cancelled."
                return
            }

            & $setBusy $true "Applying MAC override..."
            $ip = $ipBox.Text.Trim()
            $keyPath = $keyBox.Text.Trim()
            Assert-ValidIpOrHost -Value $ip
            $quotedMac = ConvertTo-ShellSingleQuoted $mac
            $cmd = "mkdir -p /userdata/jetkvm && printf '%s\n' $quotedMac > /userdata/jetkvm/mac_address && sync && echo 'MAC override written to /userdata/jetkvm/mac_address' && cat /userdata/jetkvm/mac_address"
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command $cmd -TimeoutSeconds 25
            if ($result.Output) { $result.Output -split "`n" | ForEach-Object { & $log $_ } }
            if ($result.ExitCode -ne 0) { throw "MAC override failed with exit code $($result.ExitCode)." }
            & $log "MAC override saved. Reboot JetKVM for it to become active."

            $reboot = [Windows.Forms.MessageBox]::Show(
                "MAC override saved. Reboot the JetKVM now?`r`n`r`nAfter reboot, the JetKVM may receive a different LAN IP address.",
                "Reboot JetKVM",
                "YesNo",
                "Question"
            )
            if ($reboot -eq [Windows.Forms.DialogResult]::Yes) {
                try {
                    $null = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command "( sleep 1; reboot ) >/dev/null 2>&1 &" -TimeoutSeconds 5
                } catch {
                    & $log "Reboot command sent; SSH may disconnect while JetKVM restarts."
                }
                & $setBusy $false "JetKVM rebooting"
            } else {
                & $setBusy $false "MAC override saved"
            }
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $clearMacButton.Add_Click({
        try {
            $answer = [Windows.Forms.MessageBox]::Show(
                "Clear the JetKVM user MAC override?`r`n`r`nThis removes /userdata/jetkvm/mac_address and the legacy /data/ethaddr.txt override if present. It does not remove JetKVM's system-generated stable MAC file.",
                "Clear JetKVM MAC override",
                "YesNo",
                "Warning"
            )
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                & $log "Clear MAC override cancelled."
                return
            }
            & $setBusy $true "Clearing MAC override..."
            $ip = $ipBox.Text.Trim()
            $keyPath = $keyBox.Text.Trim()
            Assert-ValidIpOrHost -Value $ip
            $cmd = "rm -f /userdata/jetkvm/mac_address /data/ethaddr.txt && sync && echo 'User MAC override cleared. Reboot JetKVM for the active MAC to refresh.'"
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command $cmd -TimeoutSeconds 25
            if ($result.Output) { $result.Output -split "`n" | ForEach-Object { & $log $_ } }
            if ($result.ExitCode -ne 0) { throw "Clearing MAC override failed with exit code $($result.ExitCode)." }
            $macOverrideLabel.Text = "User override: cleared; reboot required"
            $macOverrideLabel.ForeColor = $ui.Warn
            $reboot = [Windows.Forms.MessageBox]::Show(
                "MAC override cleared. Reboot the JetKVM now?",
                "Reboot JetKVM",
                "YesNo",
                "Question"
            )
            if ($reboot -eq [Windows.Forms.DialogResult]::Yes) {
                try {
                    $null = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command "( sleep 1; reboot ) >/dev/null 2>&1 &" -TimeoutSeconds 5
                } catch {
                    & $log "Reboot command sent; SSH may disconnect while JetKVM restarts."
                }
                & $setBusy $false "JetKVM rebooting"
            } else {
                & $setBusy $false "MAC override cleared"
            }
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $displayChoiceBox.Add_SelectedIndexChanged({
        if ($displayChoiceBox.SelectedItem) {
            $item = $displayChoiceBox.SelectedItem
            $selectedDisplayLabel.Text = "Selected display: $($item.DisplayName)"
            $selectedDisplayLabel.ForeColor = $ui.Good
            $applyEdidButton.Enabled = $true
        } else {
            $applyEdidButton.Enabled = $false
        }
    })

    $usbChoiceBox.Add_SelectedIndexChanged({
        if ($usbChoiceBox.SelectedItem) {
            $item = $usbChoiceBox.SelectedItem
            $selectedUsbLabel.Text = "Selected USB identity: $($item.DisplayName)"
            $selectedUsbLabel.ForeColor = $ui.Good
            $applyUsbButton.Enabled = $true
        } else {
            $applyUsbButton.Enabled = $false
        }
    })

    $refreshWolAdapters = {
        $wolAdapterBox.Items.Clear()
        $wolMacBox.Text = ""
        $wolBroadcastBox.Text = ""
        $wolStatusLabel.Text = "Scanning this Windows PC for physical network adapters..."
        $wolStatusLabel.ForeColor = $ui.Info

        $adapters = @(Get-LocalWakeOnLanAdapters)
        foreach ($adapter in $adapters) {
            [void]$wolAdapterBox.Items.Add($adapter)
            $kind = if ($adapter.IsWireless) { "wireless" } else { "wired/unknown" }
            & $log ("WOL adapter option: {0}; MAC {1}; IP {2}; broadcast {3}; {4}" -f $adapter.Name, $adapter.MacAddress, $(if ($adapter.IPAddress) { $adapter.IPAddress } else { "none" }), $(if ($adapter.BroadcastIP) { $adapter.BroadcastIP } else { "blank" }), $kind)
        }

        if ($wolAdapterBox.Items.Count -gt 0) {
            $wolAdapterBox.DropDownWidth = [Math]::Max($wolAdapterBox.Width, (S 900))
            $wolAdapterBox.SelectedIndex = 0
            $wolStatusLabel.Text = "Choose the NIC that should wake this PC. Wired Ethernet is usually more reliable than Wi-Fi."
            $wolStatusLabel.ForeColor = $ui.Good
        } else {
            $wolStatusLabel.Text = "No physical network adapters were found. You can still type a target MAC manually."
            $wolStatusLabel.ForeColor = $ui.Warn
        }
    }

    $wolAdapterBox.Add_SelectedIndexChanged({
        if ($wolAdapterBox.SelectedItem) {
            $adapter = $wolAdapterBox.SelectedItem
            $wolMacBox.Text = [string]$adapter.MacAddress
            $wolBroadcastBox.Text = [string]$adapter.BroadcastIP
            if ([string]::IsNullOrWhiteSpace($wolNameBox.Text)) { $wolNameBox.Text = ConvertTo-WakeOnLanDeviceName -Value $env:COMPUTERNAME }
            if ($adapter.IsWireless) {
                $wolStatusLabel.Text = "Selected adapter looks wireless. Wake-on-LAN over Wi-Fi is often unsupported; wired Ethernet is safer."
                $wolStatusLabel.ForeColor = $ui.Warn
            } else {
                $wolStatusLabel.Text = "Selected adapter MAC and broadcast IP are ready to save to JetKVM."
                $wolStatusLabel.ForeColor = $ui.Good
            }
        }
    })

    $wolMacBox.Add_Leave({
        $wolMacBox.Text = Format-MacAddress -Value $wolMacBox.Text
    })

    $scanWolAdaptersButton.Add_Click({
        try {
            & $setBusy $true "Scanning WOL adapters..."
            & $log "--- Wake-on-LAN adapter scan ---"
            & $refreshWolAdapters
            & $setBusy $false "WOL scan complete"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $scanThisPcButton.Add_Click({
        try {
            & $setBusy $true "Scanning this PC identity..."
            $displayChoiceBox.Items.Clear()
            $displayChoiceBox.Enabled = $false
            $applyEdidButton.Enabled = $false
            $selectedDisplayLabel.Text = "Selected display: none"
            $selectedDisplayLabel.ForeColor = $ui.Muted
            $usbChoiceBox.Items.Clear()
            $usbChoiceBox.Enabled = $false
            $applyUsbButton.Enabled = $false
            $selectedUsbLabel.Text = "Selected USB identity: none"
            $selectedUsbLabel.ForeColor = $ui.Muted

            & $log "--- this PC display EDID ---"
            $edidPresets = @(Get-JetKvmEdidPresets)
            foreach ($preset in $edidPresets) {
                [void]$displayChoiceBox.Items.Add($preset)
                & $log ("Display preset: {0}" -f $preset.DisplayName)
            }
            $edids = @(Get-LocalDisplayEdidRecords)
            if ($edids.Count -eq 0) {
                & $log "Warning: no local monitor EDID records were found."
                $edidStatusLabel.Text = "Display EDID: JetKVM presets loaded; no local monitor EDID found"
                $edidStatusLabel.ForeColor = $ui.Warn
            } else {
                $edidStatusLabel.Text = "Display EDID: $($edidPresets.Count) JetKVM preset(s) plus $($edids.Count) local record(s)"
                $edidStatusLabel.ForeColor = $ui.Good
                foreach ($edid in $edids) {
                    [void]$displayChoiceBox.Items.Add($edid)
                    $previewLength = [Math]::Min(96, $edid.Hex.Length)
                    & $log ("Display option: {0}; EDID {1} bytes: {2}..." -f $edid.DisplayName, $edid.Bytes, $edid.Hex.Substring(0, $previewLength))
                }
            }
            $displayChoiceBox.Enabled = ($displayChoiceBox.Items.Count -gt 0)
            $displayChoiceBox.DropDownWidth = [Math]::Max($displayChoiceBox.Width, (S 900))
            if ($displayChoiceBox.Items.Count -gt 0) { $displayChoiceBox.SelectedIndex = 0 }

            & $log "--- this PC USB input candidates ---"
            $usbPresets = @(Get-JetKvmUsbIdentityPresets)
            foreach ($preset in $usbPresets) {
                [void]$usbChoiceBox.Items.Add($preset)
                & $log ("USB preset: {0}" -f $preset.DisplayName)
            }
            $usbDevices = @(Get-LocalUsbInputDevices)
            if ($usbDevices.Count -eq 0) {
                & $log "Warning: no local USB keyboard/mouse/HID VID/PID candidates were found."
                $usbStatusLabel.Text = "USB identity: JetKVM presets loaded; no local USB input candidates found"
                $usbStatusLabel.ForeColor = $ui.Warn
            } else {
                $usbStatusLabel.Text = "USB identity: $($usbPresets.Count) JetKVM preset(s) plus $($usbDevices.Count) local candidate(s)"
                $usbStatusLabel.ForeColor = $ui.Good
                foreach ($device in $usbDevices) {
                    [void]$usbChoiceBox.Items.Add($device)
                    & $log ("USB option: {0}" -f $device.DisplayName)
                }
            }
            $usbChoiceBox.Enabled = ($usbChoiceBox.Items.Count -gt 0)
            $usbChoiceBox.DropDownWidth = [Math]::Max($usbChoiceBox.Width, (S 900))
            if ($usbChoiceBox.Items.Count -gt 0) { $usbChoiceBox.SelectedIndex = 0 }
            & $log "Identity scan complete. Choose an item from each dropdown, then use Apply EDID or Apply USB when ready."
            & $setBusy $false "Identity scan complete"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $rebootJetKvmAfterIdentity = {
        param([string]$Ip, [string]$KeyPath, [string]$Reason)

        $reboot = [Windows.Forms.MessageBox]::Show(
            "$Reason saved to the JetKVM config.`r`n`r`nReboot the JetKVM now so the KVM service reloads it? If you choose No, reboot later from the JetKVM UI.",
            "Reboot JetKVM",
            "YesNo",
            "Question"
        )
        if ($reboot -eq [Windows.Forms.DialogResult]::Yes) {
            try {
                $null = Invoke-JetKvmSshCommand -JetKvmAddress $Ip -KeyPath $KeyPath -Command "( sleep 1; reboot ) >/dev/null 2>&1 &" -TimeoutSeconds 5
            } catch {
                & $log "Reboot command sent; SSH may disconnect while JetKVM restarts."
            }
            & $setBusy $false "JetKVM rebooting"
        } else {
            & $setBusy $false "$Reason saved"
        }
    }

    $applyWolButton.Add_Click({
        try {
            $ip = $ipBox.Text.Trim()
            $keyPath = $keyBox.Text.Trim()
            Assert-ValidIpOrHost -Value $ip
            if ([string]::IsNullOrWhiteSpace($keyPath)) { throw "Choose the SSH private key path before setting up Wake-on-LAN." }

            $selectedAdapter = $wolAdapterBox.SelectedItem
            $deviceName = ConvertTo-WakeOnLanDeviceName -Value $wolNameBox.Text
            $wolNameBox.Text = $deviceName
            $mac = Format-MacAddress -Value $wolMacBox.Text
            $wolMacBox.Text = $mac
            Assert-MacAddress -MacAddress $mac
            $broadcast = $wolBroadcastBox.Text.Trim()
            if (-not [string]::IsNullOrWhiteSpace($broadcast) -and -not (Test-IPv4Address -Value $broadcast)) {
                throw "Broadcast IP must be a valid IPv4 address, or left blank."
            }

            if ($enableLocalWolCheck.Checked -and -not $selectedAdapter) {
                throw "Scan and select a Windows adapter before enabling local Wake-on-LAN, or untick the local adapter option."
            }

            if ($selectedAdapter -and $selectedAdapter.IsWireless) {
                $wifiAnswer = [Windows.Forms.MessageBox]::Show(
                    "The selected adapter looks like Wi-Fi. Wake-on-LAN over Wi-Fi is often unsupported or unreliable.`r`n`r`nContinue anyway?",
                    "Wireless Wake-on-LAN warning",
                    "YesNo",
                    "Warning"
                )
                if ($wifiAnswer -ne [Windows.Forms.DialogResult]::Yes) { return }
            }

            $localAction = if ($enableLocalWolCheck.Checked) { "JetFUEL will also try to enable Wake-on-LAN on the selected Windows adapter. This requires Administrator PowerShell and adapter driver support." } else { "JetFUEL will not change this Windows adapter. Make sure Wake-on-LAN is already enabled in Windows and BIOS/UEFI." }
            $answer = [Windows.Forms.MessageBox]::Show(
                "Set up this Wake-on-LAN target?`r`n`r`nName: $deviceName`r`nMAC: $mac`r`nBroadcast IP: $(if ($broadcast) { $broadcast } else { "(blank/default)" })`r`n`r`n$localAction`r`n`r`nJetFUEL will back up /userdata/kvm_config.json and save the target into JetKVM's Wake on LAN device list.",
                "Set up Wake-on-LAN",
                "YesNo",
                "Warning"
            )
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                & $log "Wake-on-LAN setup cancelled."
                return
            }

            & $setBusy $true "Setting up WOL..."
            if ($enableLocalWolCheck.Checked) {
                try {
                    Enable-LocalAdapterWakeOnLan -AdapterName $selectedAdapter.Name -AdapterDescription $selectedAdapter.InterfaceDescription -Log $log
                } catch {
                    $localMessage = Get-CleanExceptionMessage -ErrorRecord $_
                    & $log "Warning: Local Wake-on-LAN enable failed: $localMessage"
                    $continue = [Windows.Forms.MessageBox]::Show(
                        "JetFUEL could not enable Wake-on-LAN on this Windows adapter:`r`n`r`n$localMessage`r`n`r`nSave the JetKVM Wake-on-LAN target anyway? You may need to enable WOL manually in Windows, adapter driver settings, and BIOS/UEFI.",
                        "Local WOL setup failed",
                        "YesNo",
                        "Warning"
                    )
                    if ($continue -ne [Windows.Forms.DialogResult]::Yes) {
                        & $setBusy $false "WOL cancelled"
                        return
                    }
                }
            }

            Update-JetKvmWakeOnLanDevice -JetKvmAddress $ip -KeyPath $keyPath -DeviceName $deviceName -MacAddress $mac -BroadcastIP $broadcast -Log $log
            & $log "Wake-on-LAN target saved to JetKVM: $deviceName ($mac)"
            if ($broadcast) { & $log "Wake-on-LAN broadcast IP saved: $broadcast" }
            & $rebootJetKvmAfterIdentity $ip $keyPath "Wake-on-LAN target"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $applyEdidButton.Add_Click({
        try {
            if (-not $displayChoiceBox.SelectedItem) { throw "Select a display EDID first." }
            $item = $displayChoiceBox.SelectedItem
            $edid = Assert-EdidHex -Hex $item.Hex
            $answer = [Windows.Forms.MessageBox]::Show(
                "Apply this display EDID to the JetKVM?`r`n`r`n$($item.DisplayName)`r`n`r`nJetFUEL will back up /userdata/kvm_config.json, write the EDID hex/file content to hdmi_edid_string, then offer to reboot.",
                "Apply JetKVM EDID",
                "YesNo",
                "Warning"
            )
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                & $log "EDID apply cancelled."
                return
            }

            & $setBusy $true "Applying EDID..."
            $ip = $ipBox.Text.Trim()
            $keyPath = $keyBox.Text.Trim()
            Assert-ValidIpOrHost -Value $ip
            Update-JetKvmConfigProperty -JetKvmAddress $ip -KeyPath $keyPath -Name "hdmi_edid_string" -Value $edid -Log $log
            & $log "EDID saved to JetKVM config: $($item.DisplayName)"
            & $rebootJetKvmAfterIdentity $ip $keyPath "EDID"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $applyUsbButton.Add_Click({
        try {
            if (-not $usbChoiceBox.SelectedItem) { throw "Select a USB identity first." }
            $item = $usbChoiceBox.SelectedItem
            $usbConfig = ConvertTo-JetKvmUsbConfig -Device $item
            $answer = [Windows.Forms.MessageBox]::Show(
                "Apply this USB identity to the JetKVM?`r`n`r`n$($item.DisplayName)`r`n`r`nThis changes the JetKVM composite USB vendor/product identity only. It does not clone every descriptor from a physical keyboard or mouse.",
                "Apply JetKVM USB identity",
                "YesNo",
                "Warning"
            )
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                & $log "USB identity apply cancelled."
                return
            }

            & $setBusy $true "Applying USB identity..."
            $ip = $ipBox.Text.Trim()
            $keyPath = $keyBox.Text.Trim()
            Assert-ValidIpOrHost -Value $ip
            Update-JetKvmConfigProperty -JetKvmAddress $ip -KeyPath $keyPath -Name "usb_config" -Value $usbConfig -Log $log
            & $log ("USB identity saved to JetKVM config: {0}:{1} {2} - {3}; serial: {4}" -f $usbConfig.vendor_id, $usbConfig.product_id, $usbConfig.manufacturer, $usbConfig.product, $(if ([string]::IsNullOrWhiteSpace($usbConfig.serial_number)) { "(blank)" } else { $usbConfig.serial_number }))
            & $rebootJetKvmAfterIdentity $ip $keyPath "USB identity"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })

    $doPreflight = {
        param([bool]$Install)
        try {
            & $setBusy $true "Working..."
            $ip = $ipBox.Text.Trim()
            Assert-ValidIpOrHost -Value $ip

            & $log "Checking Windows prerequisites..."
            $wingetState = Test-WingetAvailable
            if ($wingetState.Ok) {
                & $log $wingetState.Message
                & $setIndicator $wingetStatus "OK" "winget available"
            } else {
                & $log ("Warning: " + $wingetState.Message)
                & $setIndicator $wingetStatus "Warn" "winget missing/broken"
            }

            $bashInfo = Select-BashForInstall -Log $log
            $bash = $bashInfo.Path
            $bashKind = $bashInfo.Kind
            & $log "Using $bashKind bash: $bash"
            & $setIndicator $bashStatus "OK" "$bashKind bash selected"

            $ssh = Get-CommandPath -Name "ssh.exe"
            if (-not $ssh) { $ssh = Get-CommandPath -Name "ssh" }
            if (-not $ssh) { throw "OpenSSH client was not found. Enable Windows OpenSSH Client and try again." }
            & $log "Using ssh: $ssh"
            & $setIndicator $sshStatus "OK" "SSH tools found"

            $keyPath = $keyBox.Text.Trim()
            if ($createKeyCheck.Checked -and -not (Test-Path -LiteralPath "$keyPath.pub")) {
                $passphrase = if ($noPassCheck.Checked) { "" } else { $passBox.Text }
                New-SshKeyPair -KeyPath $keyPath -Passphrase $passphrase -Log $log
            }
            $null = Get-PublicKeyText -KeyPath $keyPath
            & $log "SSH public key is available: $keyPath.pub"

            if (-not (Test-Connection -ComputerName $ip -Count 1 -Quiet)) {
                & $log "Warning: Windows ping did not receive a reply from $ip. Continuing may still work if ICMP is blocked."
                & $setIndicator $kvmStatus "Warn" "Ping did not reply"
            } else {
                & $log "JetKVM responded to ping."
                & $setIndicator $kvmStatus "OK" "JetKVM answered ping"
            }

            if (Test-JetKvmWebUi -JetKvmAddress $ip) {
                & $log "JetKVM web UI port is reachable."
                & $setIndicator $httpStatus "OK" "Web UI reachable"
            } else {
                & $log "Warning: JetKVM web UI port 80 was not reachable from this PC."
                & $setIndicator $httpStatus "Warn" "Web UI not reachable"
            }

            $sshLogin = Test-JetKvmSshLogin -JetKvmAddress $ip -KeyPath $keyPath
            if ($sshLogin.Ok) {
                & $log "JetKVM SSH login confirmed with the selected key."
                & $setIndicator $sshLoginStatus "OK" "JetKVM SSH login confirmed"
            } else {
                & $log ("JetKVM SSH login not confirmed: " + $sshLogin.Message)
                & $setIndicator $sshLoginStatus "Warn" "SSH login not confirmed"
            }

            if (-not $Install) {
                & $log "Preflight complete. Finish the JetKVM UI steps, then run setup."
                & $setBusy $false "Preflight complete"
                return
            }

            $authKey = if ($useAuthKeyCheck.Checked) { $authBox.Text.Trim() } else { "" }
            if ($useAuthKeyCheck.Checked -and [string]::IsNullOrWhiteSpace($authKey)) {
                throw "Tailscale auth key is enabled but empty. Paste a key that usually starts with tskey-auth-, or untick the auth key box."
            }
            if ($useAuthKeyCheck.Checked) {
                Assert-TailscaleAuthKeyLooksUsable -AuthKey $authKey
            }
            if ($useAuthKeyCheck.Checked -and $authKey -notmatch '^tskey-auth-') {
                $answer = [Windows.Forms.MessageBox]::Show(
                    "This does not look like a Tailscale pre-authentication key. It should usually start with tskey-auth-. Continue anyway?",
                    "JetFUEL",
                    "YesNo",
                    "Warning"
                )
                if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                    throw "Install cancelled so the Tailscale auth key can be checked."
                }
            }
            $tailHostname = ConvertTo-TailscaleHostname -Value $hostBox.Text
            Assert-TailscaleHostname -Value $tailHostname
            if ($hostBox.Text -cne $tailHostname) {
                $hostBox.Text = $tailHostname
                & $log "Tailscale hostname was normalised to: $tailHostname"
            }
            $installerSourceKind = [string]$installerSourceBox.SelectedItem
            if ([string]::IsNullOrWhiteSpace($installerSourceKind)) { $installerSourceKind = "Official JetKVM" }
            $installerSourcePath = switch ($installerSourceKind) {
                "Custom URL" { $customInstallerUrlBox.Text.Trim() }
                "Local file" { $localInstallerPathBox.Text.Trim() }
                default { "" }
            }

            Invoke-JetKvmTailscaleInstall `
                -BashPath $bash `
                -BashKind $bashKind `
                -JetKvmAddress $ip `
                -KeyPath $keyPath `
                -TailscaleVersion $versionBox.Text.Trim() `
                -AuthKey $authKey `
                -Hostname $tailHostname `
                -CleanInstall:($cleanCheck.Checked) `
                -InstallerSourceKind $installerSourceKind `
                -InstallerSourcePath $installerSourcePath `
                -Log $log `
                -LoginUrlHandler {
                    param($url)
                    & $log "Opening Tailscale login URL: $url"
                    Start-Process $url
                    & $setBusy $true "Waiting for browser login..."
                    if (Wait-JetKvmTailscaleOnline -JetKvmAddress $ip -KeyPath $keyPath -Log $log -TimeoutSeconds 180) {
                        & $setBusy $false "Tailscale online"
                    } else {
                        & $setBusy $false "Login wait timed out"
                        throw "Timed out waiting for Tailscale login to complete. Complete the browser login, then click Check Tailscale."
                    }
                }

            & $log "Setup complete. Confirm the new device in the Tailscale admin console."
            & $setBusy $false "Complete"
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            if ($_.Exception.Message -match "winget|App Installer") { & $setIndicator $wingetStatus "Fail" "winget problem" }
            if ($_.Exception.Message -match "bash|Git") { & $setIndicator $bashStatus "Fail" "Git Bash problem" }
            if ($_.Exception.Message -match "SSH|ssh") { & $setIndicator $sshStatus "Fail" "SSH problem" }
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    }

    $preflightButton.Add_Click({ & $doPreflight $false })
    $runButton.Add_Click({ & $doPreflight $true })
    $checkTailscaleButton.Add_Click({
        try {
            & $setBusy $true "Checking Tailscale..."
            $ip = $ipBox.Text.Trim()
            $keyPath = $keyBox.Text.Trim()
            Assert-ValidIpOrHost -Value $ip
            $cmd = @'
echo '--- date ---'
date 2>&1 || true
echo '--- network ---'
ip route 2>&1 || true
cat /etc/resolv.conf 2>&1 || true
echo '--- tailscale persistence/autostart ---'
if [ -x /userdata/tailscale/tailscale ]; then echo '[OK] /userdata/tailscale/tailscale exists'; else echo '[FAIL] /userdata/tailscale/tailscale missing or not executable'; fi
if [ -x /userdata/tailscale/tailscaled ]; then echo '[OK] /userdata/tailscale/tailscaled exists'; else echo '[FAIL] /userdata/tailscale/tailscaled missing or not executable'; fi
if [ -f /userdata/init.d/S22tailscale ]; then
  echo '[OK] /userdata/init.d/S22tailscale exists'
  grep -n 'watchdog\|tailscaled\|/dev/net/tun\|killall tailscaled' /userdata/init.d/S22tailscale 2>&1 || true
else
  echo '[FAIL] /userdata/init.d/S22tailscale missing - Tailscale may not start after reboot'
fi
if [ -f /userdata/init.d/S22tailscale ] && ( grep -q 'JetFUEL robust Tailscale startup' /userdata/init.d/S22tailscale || grep -q '/userdata/tailscale/tailscaled' /userdata/init.d/S22tailscale ); then echo '[OK] boot hook starts tailscaled'; else echo '[FAIL] boot hook does not start tailscaled'; fi
if [ -f /userdata/init.d/S22tailscale ] && grep -q 'watchdog' /userdata/init.d/S22tailscale; then echo '[OK] watchdog configured in boot hook'; else echo '[WARN] watchdog not configured in boot hook'; fi
if [ -f /var/run/tailscale/jetfuel-watchdog.pid ]; then
  pid="$(cat /var/run/tailscale/jetfuel-watchdog.pid 2>/dev/null || true)"
  if [ -n "$pid" ] && ps | grep -q "^[[:space:]]*$pid[[:space:]]"; then echo '[OK] watchdog process running'; else echo '[WARN] watchdog pid file exists but process not found'; fi
else
  echo '[WARN] watchdog pid file missing'
fi
echo '--- tailscale status ---'
tailscale status 2>&1 || true
echo '--- tailscale ip ---'
tailscale ip -4 2>&1 || true
echo '--- tailscale version ---'
tailscale version 2>&1 || true
echo '--- processes ---'
ps | grep tailscale | grep -v grep 2>&1 || echo '[WARN] no tailscale processes found'
echo '--- check complete ---'
'@
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command $cmd -TimeoutSeconds 45
            if ($result.Output) { $result.Output -split "`n" | ForEach-Object { & $log $_ } }
            if ($result.ExitCode -eq 0) { & $setBusy $false "Tailscale check complete" }
            else { & $setBusy $false "Tailscale check completed with warnings" }
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })
    $repairTailscaleButton.Add_Click({
        try {
            & $setBusy $true "Repairing Tailscale..."
            $ip = $ipBox.Text.Trim()
            $keyPath = $keyBox.Text.Trim()
            $hostname = ConvertTo-TailscaleHostname -Value $hostBox.Text
            Assert-TailscaleHostname -Value $hostname
            if ($hostBox.Text -cne $hostname) {
                $hostBox.Text = $hostname
                & $log "Tailscale hostname was normalised to: $hostname"
            }
            $authKey = $authBox.Text.Trim()
            Assert-ValidIpOrHost -Value $ip

            $configureCmd = "echo '--- configure tailscale persistence/autostart ---'; if [ -x /userdata/tailscale/tailscale ]; then /userdata/tailscale/tailscale configure jetkvm 2>&1 || true; else echo 'WARN: /userdata/tailscale/tailscale is missing'; exit 1; fi"
            $configureResult = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command $configureCmd -TimeoutSeconds 35
            if ($configureResult.Output) { $configureResult.Output -split "`n" | ForEach-Object { & $log $_ } }
            if ($configureResult.ExitCode -ne 0) {
                throw "Cannot repair Tailscale because /userdata/tailscale/tailscale is missing. Run Step 5 install first."
            }

            Set-JetKvmTailscaleInitHook -JetKvmAddress $ip -KeyPath $keyPath -Log $log
            $startResult = Invoke-JetKvmTailscaleStartGuard -JetKvmAddress $ip -KeyPath $keyPath -Log $log -TimeoutSeconds 60
            if ($startResult.ExitCode -ne 0) {
                throw "tailscaled did not start. Check the status log and /tmp/tailscale-init.log on the JetKVM for details."
            }

            $preStatus = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command "tailscale status 2>&1" -TimeoutSeconds 30
            if ($preStatus.Output) { $preStatus.Output -split "`n" | ForEach-Object { & $log $_ } }
            $needsLogin = ($preStatus.Output -match 'NeedsLogin|Logged out|no current Tailscale IPs')
            if ($needsLogin -and [string]::IsNullOrWhiteSpace($authKey)) {
                & $log "Tailscale is in NeedsLogin and no auth key is supplied. Repair will request a browser login URL."
                $statusLoginUrl = Get-TailscaleLoginUrlFromText -Text $preStatus.Output
                if ($statusLoginUrl) {
                    & $log "Opening Tailscale login URL: $statusLoginUrl"
                    Start-Process $statusLoginUrl
                    & $setBusy $true "Waiting for browser login..."
                    if (Wait-JetKvmTailscaleOnline -JetKvmAddress $ip -KeyPath $keyPath -Log $log -TimeoutSeconds 180) {
                        & $setBusy $false "Tailscale online"
                    } else {
                        & $setBusy $false "Login wait timed out"
                        throw "Timed out waiting for Tailscale login to complete. Complete the browser login, then click Check Tailscale."
                    }
                    return
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($authKey)) {
                Assert-TailscaleAuthKeyLooksUsable -AuthKey $authKey
            }

            $upArgs = New-Object System.Collections.Generic.List[string]
            if (-not [string]::IsNullOrWhiteSpace($authKey)) { $upArgs.Add("--authkey=$(ConvertTo-ShellSingleQuoted $authKey)") }
            if (-not [string]::IsNullOrWhiteSpace($hostname)) { $upArgs.Add("--hostname=$(ConvertTo-ShellSingleQuoted $hostname)") }
            $upArgs.Add("--reset")
            if ([string]::IsNullOrWhiteSpace($authKey)) {
                & $log "Warning: Repair is running without an auth key. If the device is in NeedsLogin, Tailscale may require manual login."
            } else {
                & $log "Repair will use the pasted Tailscale auth key."
            }
            $upArgText = ($upArgs -join " ")
            if ([string]::IsNullOrWhiteSpace($authKey)) {
                $loginCmd = "tailscale up $upArgText 2>&1 | sed -n '1,20p'"
                $loginResult = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command $loginCmd -TimeoutSeconds 12
                if ($loginResult.Output) { $loginResult.Output -split "`n" | ForEach-Object { & $log $_ } }
                $loginUrl = Get-TailscaleLoginUrlFromText -Text $loginResult.Output
                if ($loginUrl) {
                    & $log "Opening Tailscale login URL: $loginUrl"
                    Start-Process $loginUrl
                    & $setBusy $true "Waiting for browser login..."
                    if (Wait-JetKvmTailscaleOnline -JetKvmAddress $ip -KeyPath $keyPath -Log $log -TimeoutSeconds 180) {
                        & $setBusy $false "Tailscale online"
                    } else {
                        & $setBusy $false "Login wait timed out"
                        throw "Timed out waiting for Tailscale login to complete. Complete the browser login, then click Check Tailscale."
                    }
                    return
                }
                throw "Tailscale needs login, but no login URL was detected. Paste an auth key or run tailscale up manually over SSH."
            }
            $cmd = "echo '--- status before repair ---'; tailscale status 2>&1 || true; echo '--- logout/reset local login state ---'; tailscale logout 2>&1 || true; echo '--- running tailscale up repair ---'; tailscale up $upArgText 2>&1; echo '--- status after repair ---'; tailscale status 2>&1; echo '--- ip after repair ---'; tailscale ip -4 2>&1; echo '--- persistence after repair ---'; if [ -f /userdata/init.d/S22tailscale ] && grep -q 'JetFUEL robust Tailscale startup' /userdata/init.d/S22tailscale; then echo '[OK] robust boot hook exists'; else echo '[FAIL] robust boot hook missing or incomplete'; fi"
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command $cmd -TimeoutSeconds 90
            $safeOutput = $result.Output
            if (-not [string]::IsNullOrWhiteSpace($authKey)) {
                $safeOutput = $safeOutput.Replace($authKey, "<redacted-auth-key>")
            }
            if ($safeOutput) { $safeOutput -split "`n" | ForEach-Object { & $log $_ } }
            $loginUrlFound = Open-TailscaleLoginUrlFromText -Text $safeOutput -Log $log
            if ($result.TimedOut -and $loginUrlFound) {
                throw "Tailscale is waiting for browser login. Complete the login page, then click Check Tailscale."
            }
            if ($loginUrlFound -and $result.ExitCode -ne 0) {
                throw "Tailscale needs browser login. Complete the login page, then click Check Tailscale."
            }
            if ($result.TimedOut) {
                throw "Tailscale repair timed out after 90 seconds. If no auth key was supplied, run Repair again and use the login URL if one appears in the log."
            }
            if ($result.ExitCode -eq 0) { & $setBusy $false "Repair complete" }
            else {
                if ($result.Output -match 'invalid key|unable to validate API key|API key .*not valid|API key does not exist') {
                    throw "Tailscale rejected the pasted auth key during repair even after local logout/reset. This usually means the JetKVM cannot validate that key against the Tailscale control server, or the key text being received by tailscale differs from the saved key. Run Check Tailscale and verify the JetKVM date/network/DNS, or untick auth key and run Repair to use the manual login URL."
                }
                throw "Tailscale repair failed with exit code $($result.ExitCode)."
            }
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })
    $removeTailscaleButton.Add_Click({
        try {
            $answer = [Windows.Forms.MessageBox]::Show(
                "This will stop Tailscale on the JetKVM, log it out where possible, remove /userdata/tailscale, and reboot the JetKVM. Continue?",
                "Remove Tailscale from JetKVM",
                "YesNo",
                "Warning"
            )
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                & $log "Tailscale removal cancelled."
                return
            }

            & $setBusy $true "Removing Tailscale..."
            $ip = $ipBox.Text.Trim()
            $keyPath = $keyBox.Text.Trim()
            Assert-ValidIpOrHost -Value $ip

            $cmd = @"
echo '--- tailscale before removal ---'
tailscale status 2>&1 || true
echo '--- logging out and stopping tailscale ---'
tailscale down 2>&1 || true
tailscale logout 2>&1 || true
killall tailscaled 2>&1 || true
killall tailscale 2>&1 || true
echo '--- removing /userdata/tailscale ---'
rm -rf /userdata/tailscale /userdata/tailscale.tgz /userdata/tailscale_*_arm
sync
echo '--- rebooting JetKVM ---'
( sleep 1; reboot ) >/dev/null 2>&1 &
"@
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command $cmd -TimeoutSeconds 35
            if ($result.Output) { $result.Output -split "`n" | ForEach-Object { & $log $_ } }
            if ($result.ExitCode -eq 0 -or $result.TimedOut) {
                & $log "Tailscale removal command sent. The JetKVM should reboot now."
                & $setBusy $false "Removal sent"
            } else {
                throw "Tailscale removal failed with exit code $($result.ExitCode)."
            }
        } catch {
            & $log ("ERROR: " + $_.Exception.Message)
            & $setBusy $false "Failed"
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "JetFUEL", "OK", "Error") | Out-Null
        }
    })
    # Double-buffer the whole control tree so resizing and moving the window
    # repaints smoothly instead of flickering.
    $enableDoubleBuffering = {
        param([Windows.Forms.Control]$Control)
        try {
            $doubleBufferedProperty = [Windows.Forms.Control].GetProperty("DoubleBuffered", ([Reflection.BindingFlags]"Instance, NonPublic"))
            $doubleBufferedProperty.SetValue($Control, $true, $null)
        } catch {}
        foreach ($child in $Control.Controls) { & $enableDoubleBuffering $child }
    }
    & $enableDoubleBuffering $form

    & $log "Use Copy public key, enable Developer Mode in JetKVM, then run setup."
    [void]$form.ShowDialog()
}

if ($NoGui) {
    throw "NoGui mode is not implemented yet. Run JetFuel.ps1 without -NoGui for the wizard."
}

Start-JetFuelGuiV2
