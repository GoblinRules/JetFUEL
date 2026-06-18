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

    if (Test-PathInsideDirectory -Path $PSScriptRoot -Root $localRoot) {
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
            $repoScript = Join-Path $PSScriptRoot "install-tailscale.sh"
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
    $sshOpts = "-i $keyBashPath -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
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
    & $BashPath -lc $bashCommand 2>&1 | ForEach-Object {
        $line = [string]$_
        $installerOutput.Add($line)
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
    if ($LASTEXITCODE -ne 0) {
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
        throw "JetKVM Tailscale installer failed with exit code $LASTEXITCODE."
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
        $output = & $ssh -i $KeyPath -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@$JetKvmAddress "echo SSH_OK" 2>&1
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
        "root@$JetKvmAddress",
        $Command
    )

    $job = Start-Job -ScriptBlock {
        param($SshPath, $ArgsForSsh)
        & $SshPath @ArgsForSsh 2>&1 | ForEach-Object { [string]$_ }
        "__JETFUEL_EXIT_CODE:$LASTEXITCODE"
    } -ArgumentList $ssh, $sshArgs

    if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
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
    $iconPath = Join-Path $PSScriptRoot "assets\icon.ico"
    $logoPath = Join-Path $PSScriptRoot "assets\icon.png"
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
    $subtitle.Text = "Follow the steps from top to bottom. Run preflight first to confirm this PC can see the JetKVM."
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
    $navPanel.ColumnCount = 6
    $navPanel.RowCount = 1
    foreach ($width in @(122, 122, 122, 122, 122)) {
        $navPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S $width))) | Out-Null
    }
    $navPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null

    $setupTabButton = [Windows.Forms.Button]::new()
    $setupTabButton.Text = "Setup"
    $setupTabButton.Dock = "Fill"
    $setupTabButton.Margin = New-ScaledPadding 0 0 4 0
    $tailscaleTabButton = [Windows.Forms.Button]::new()
    $tailscaleTabButton.Text = "Tailscale"
    $tailscaleTabButton.Dock = "Fill"
    $tailscaleTabButton.Margin = New-ScaledPadding 0 0 4 0
    $identityTabButton = [Windows.Forms.Button]::new()
    $identityTabButton.Text = "Identity"
    $identityTabButton.Dock = "Fill"
    $identityTabButton.Margin = New-ScaledPadding 0 0 4 0
    $settingsTabButton = [Windows.Forms.Button]::new()
    $settingsTabButton.Text = "Settings"
    $settingsTabButton.Dock = "Fill"
    $settingsTabButton.Margin = New-ScaledPadding 0 0 4 0
    $helpTabButton = [Windows.Forms.Button]::new()
    $helpTabButton.Text = "Help"
    $helpTabButton.Dock = "Fill"
    $helpTabButton.Margin = New-ScaledPadding 0 0 4 0
    Set-ButtonStyle $setupTabButton "Primary"
    Set-ButtonStyle $tailscaleTabButton "Secondary"
    Set-ButtonStyle $identityTabButton "Secondary"
    Set-ButtonStyle $settingsTabButton "Secondary"
    Set-ButtonStyle $helpTabButton "Secondary"
    $navPanel.Controls.Add($setupTabButton, 0, 0)
    $navPanel.Controls.Add($tailscaleTabButton, 1, 0)
    $navPanel.Controls.Add($identityTabButton, 2, 0)
    $navPanel.Controls.Add($settingsTabButton, 3, 0)
    $navPanel.Controls.Add($helpTabButton, 4, 0)

    $pageHost = [Windows.Forms.Panel]::new()
    $pageHost.Dock = "Fill"
    $pageHost.BackColor = $ui.Window

    $setupPage = [Windows.Forms.Panel]::new()
    $setupPage.Dock = "Fill"
    $setupPage.BackColor = $ui.Window
    $setupPage.AutoScroll = $true
    $tailscalePage = [Windows.Forms.Panel]::new()
    $tailscalePage.Dock = "Fill"
    $tailscalePage.BackColor = $ui.Window
    $identityPage = [Windows.Forms.Panel]::new()
    $identityPage.Dock = "Fill"
    $identityPage.BackColor = $ui.Window
    $identityPage.AutoScroll = $true
    $settingsPage = [Windows.Forms.Panel]::new()
    $settingsPage.Dock = "Fill"
    $settingsPage.BackColor = $ui.Window
    $settingsPage.AutoScroll = $true
    $helpPage = [Windows.Forms.Panel]::new()
    $helpPage.Dock = "Fill"
    $helpPage.BackColor = $ui.Window

    $setupLayout = [Windows.Forms.TableLayoutPanel]::new()
    $setupLayout.Dock = "Top"
    $setupLayout.AutoSize = $true
    $setupLayout.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $setupLayout.AutoScroll = $false
    $setupLayout.BackColor = $ui.Window
    $setupLayout.ColumnCount = 1
    $setupLayout.RowCount = 5
    $setupLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    # The step groups size themselves to their content; only the action row is fixed.
    for ($i = 0; $i -lt 4; $i++) {
        $setupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    }
    $setupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S 46))) | Out-Null
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
    $tailscaleLayout.Dock = "Fill"
    $tailscaleLayout.BackColor = $ui.Window
    $tailscaleLayout.ColumnCount = 1
    $tailscaleLayout.RowCount = 2
    $tailscaleLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $tailscaleLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S 76))) | Out-Null
    $tailscaleLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $tailscalePage.Controls.Add($tailscaleLayout)

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
    $identityLayout.RowCount = 2
    $identityLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $identityLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    $identityLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) | Out-Null
    $identityPage.Controls.Add($identityLayout)

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
- Complete Step 1 through Step 4 first, then run Step 5.

Step 1 - Prechecks
- Run preflight checks that this Windows PC has bash and SSH tools available.
- Checks whether the JetKVM responds on the network and whether the web UI is reachable.
- Checks SSH login after you enable Developer Mode and add the public SSH key.

Step 2 - JetKVM and SSH
- Enter the JetKVM IP address or hostname.
- Choose the SSH private key path used by the wizard.
- If the key does not exist, the wizard can create it.
- Choose whether the SSH key has no passphrase or a passphrase.
- Open UI opens the JetKVM web interface.

Step 3 - Tailscale options
- Install script selects which installer Step 5 uses:
  - Official JetKVM: downloads JetKVM's current hosted installer script.
  - JetFUEL repo: uses the local copied reference/fallback script stored with this wizard.
  - Custom URL: downloads a custom compatible installer URL from Settings.
  - Local file: uses a custom compatible installer file path from Settings.
- Use a Tailscale auth key if you want the JetKVM to join your tailnet automatically.
- Auth keys should usually start with tskey-auth-. The key ID shown in the admin table is not enough.
- Tailscale hostname is optional, but if used it must be lowercase letters, numbers, and hyphens only.
- Clean Tailscale install removes the old Tailscale identity on the JetKVM and creates a new machine identity.

Step 4 - Required JetKVM UI steps
- Developer Mode SSH must be enabled before the install can run.
- Copy public key copies the SSH public key to your clipboard.
- Paste that key into JetKVM Settings > Advanced > Developer Mode, then save the JetKVM settings.
- After Tailscale is online, you can remove the SSH public key or disable Developer Mode again if you do not need SSH access.

Step 5 - Run install
- Runs preflight checks, downloads or loads the selected installer script, patches SSH handling for the chosen key, and starts the install.
- The JetKVM will reboot during installation.
- If no auth key is supplied, the wizard will look for a Tailscale browser login URL and wait for login to complete.

Exit / cleanup
- The red EXIT button asks whether to exit only, clean up and exit, or cancel.
- Cleanup removes JetFUEL temp folders and the downloaded %LOCALAPPDATA%\JetFUEL bootstrap copy when present.
- SSH keys are left in place.
- Git for Windows / Git Bash is only uninstalled after a second confirmation because other tools may use it.

Tailscale tab
- Check Tailscale prints status, Tailscale IP, version, routes, DNS, and running Tailscale processes.
- Check Tailscale also verifies the JetKVM boot hook at /userdata/init.d/S22tailscale so you can see whether Tailscale should survive reboot.
- Repair Tailscale recreates the JetKVM Tailscale boot hook, starts tailscaled if needed, then reruns tailscale up with the current auth key/hostname settings or opens the manual login URL when no auth key is used.
- Remove Tailscale logs out where possible, stops Tailscale, removes /userdata/tailscale, and reboots the JetKVM.

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
- If the JetKVM stays in NeedsLogin, use Check Tailscale and look for a login URL in the log.
- Tailscale auth keys should be full pre-authentication secrets beginning with tskey-auth-. The key ID ending CNTRL is not enough.
- Tailscale installation may fail if the JetKVM itself is set up/authenticated using Google auth. Use local JetKVM authentication for this SSH/Developer Mode flow.
- If SSH login fails, confirm Developer Mode is enabled, the public key was saved in JetKVM Settings > Advanced, and the selected private key matches the public key.

Status log
- Shows the detailed output from preflight, install, repair, remove, and checks.
- Use Copy logs when reporting an issue or saving the output.
- Drag the splitter above the log to make it larger or smaller.
"@
    $helpPage.Controls.Add($helpBox)

    $pageHost.Controls.AddRange(@($helpPage, $settingsPage, $identityPage, $tailscalePage, $setupPage))
    $showPage = {
        param([string]$Name)
        $setupPage.Visible = ($Name -eq "Setup")
        $tailscalePage.Visible = ($Name -eq "Tailscale")
        $identityPage.Visible = ($Name -eq "Identity")
        $settingsPage.Visible = ($Name -eq "Settings")
        $helpPage.Visible = ($Name -eq "Help")
        Set-ButtonStyle $setupTabButton $(if ($Name -eq "Setup") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $tailscaleTabButton $(if ($Name -eq "Tailscale") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $identityTabButton $(if ($Name -eq "Identity") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $settingsTabButton $(if ($Name -eq "Settings") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $helpTabButton $(if ($Name -eq "Help") { "Primary" } else { "Secondary" })
    }
    $setupTabButton.Add_Click({ & $showPage "Setup" })
    $tailscaleTabButton.Add_Click({ & $showPage "Tailscale" })
    $identityTabButton.Add_Click({ & $showPage "Identity" })
    $settingsTabButton.Add_Click({ & $showPage "Settings" })
    $helpTabButton.Add_Click({ & $showPage "Help" })

    $pageShell.Controls.Add($navPanel, 0, 0)
    $pageShell.Controls.Add($pageHost, 0, 1)
    $main.Controls.Add($pageShell, 0, 1)
    & $showPage "Setup"

    $precheckGroup = New-Group "Step 1 - Prechecks"
    & $makeGroupAutoHeight $precheckGroup
    $preGrid = New-StepGrid 3
    $preGrid.RowStyles.Clear()
    foreach ($height in @(25, 25, 25)) {
        $preGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $precheckGroup.Controls.Add($preGrid)
    $bashStatus = New-RowLabel "[ ] Git Bash: not checked"
    $sshStatus = New-RowLabel "[ ] SSH tools: not checked"
    $wingetStatus = New-RowLabel "[ ] winget: not checked"
    $sshLoginStatus = New-RowLabel "[ ] JetKVM SSH login: enable Developer Mode first"
    $kvmStatus = New-RowLabel "[ ] JetKVM network: enter IP, then preflight"
    $httpStatus = New-RowLabel "[ ] JetKVM web UI: not checked"
    $preflightButton = [Windows.Forms.Button]::new()
    $preflightButton.Text = "Run preflight"
    $preflightButton.Dock = "Fill"
    $preflightButton.Margin = New-ScaledPadding 8 3 8 3
    Set-ButtonStyle $preflightButton "Secondary"
    $preGrid.Controls.Add($bashStatus, 0, 0)
    $preGrid.Controls.Add($kvmStatus, 1, 0)
    $preGrid.Controls.Add($sshStatus, 0, 1)
    $preGrid.Controls.Add($httpStatus, 1, 1)
    $preGrid.Controls.Add($wingetStatus, 0, 2)
    $preGrid.Controls.Add($sshLoginStatus, 1, 2)
    $preGrid.Controls.Add($preflightButton, 2, 0)
    $preGrid.SetRowSpan($preflightButton, 2)
    $setupLayout.Controls.Add($precheckGroup, 0, 0)

    $step2Group = New-Group "Step 2 - JetKVM and SSH"
    & $makeGroupAutoHeight $step2Group
    $step2Grid = New-StepGrid 4
    $step2Grid.RowStyles.Clear()
    foreach ($height in @(30, 30, 28, 30)) {
        $step2Grid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $step2Group.Controls.Add($step2Grid)
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
    $createKeyCheck.Text = "Create this SSH key if it does not exist"
    $createKeyCheck.Checked = $true
    $createKeyCheck.Dock = "Fill"
    Set-CheckStyle $createKeyCheck
    $noPassCheck = [Windows.Forms.CheckBox]::new()
    $noPassCheck.Text = "No passphrase"
    $noPassCheck.Checked = $true
    $noPassCheck.Dock = "Fill"
    Set-CheckStyle $noPassCheck
    $step2Grid.Controls.Add((New-RowLabel "JetKVM IP or hostname"), 0, 0)
    $step2Grid.Controls.Add($ipBox, 1, 0)
    $step2Grid.Controls.Add($openUiButton, 2, 0)
    $step2Grid.Controls.Add((New-RowLabel "SSH private key path"), 0, 1)
    $step2Grid.Controls.Add($keyBox, 1, 1)
    $step2Grid.Controls.Add($browseButton, 2, 1)
    $step2Grid.Controls.Add($createKeyCheck, 1, 2)
    $step2Grid.Controls.Add((New-RowLabel "SSH key passphrase"), 0, 3)
    $step2Grid.Controls.Add($passBox, 1, 3)
    $step2Grid.Controls.Add($noPassCheck, 2, 3)
    $setupLayout.Controls.Add($step2Group, 0, 1)

    $step3Group = New-Group "Step 3 - Tailscale options"
    & $makeGroupAutoHeight $step3Group
    $step3Grid = New-StepGrid 10
    $step3Grid.ColumnStyles.Clear()
    $step3Grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 145))) | Out-Null
    $step3Grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $step3Grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, (S 4))) | Out-Null
    $step3Grid.RowStyles.Clear()
    foreach ($height in @(30, 24, 26, 26, 30, 30, 30, 24, 30, 26)) {
        $step3Grid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $step3Group.Controls.Add($step3Grid)
    $installerSourceBox = [Windows.Forms.ComboBox]::new()
    $installerSourceBox.Dock = "Fill"
    $installerSourceBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $installerSourceBox.Margin = New-ScaledPadding 0 2 8 2
    $installerSourceBox.BackColor = $ui.Input
    $installerSourceBox.ForeColor = $ui.InputText
    $installerSourceBox.Font = [Drawing.Font]::new("Segoe UI", 9)
    [void]$installerSourceBox.Items.AddRange(@("Official JetKVM", "JetFUEL repo", "Custom URL", "Local file"))
    $installerSourceBox.SelectedItem = "Official JetKVM"
    $installerSourceHelp = New-RowLabel "Default uses JetKVM's current script. See Settings for the local reference copy and custom source requirements."
    $cleanCheck = [Windows.Forms.CheckBox]::new()
    $cleanCheck.Text = "Clean Tailscale install on JetKVM (creates a new Tailscale machine identity)"
    $cleanCheck.Dock = "Fill"
    Set-CheckStyle $cleanCheck
    $useAuthKeyCheck = [Windows.Forms.CheckBox]::new()
    $useAuthKeyCheck.Text = "Use a Tailscale auth key to connect automatically"
    $useAuthKeyCheck.Dock = "Fill"
    Set-CheckStyle $useAuthKeyCheck
    $authBox = New-Field ""
    $authBox.UseSystemPasswordChar = $true
    $authBox.Enabled = $false
    $authHelp = New-RowLabel "Paste the full tskey-auth-... secret shown when creating the key. The key ID ending CNTRL in the admin table is not enough."
    $hostBox = New-Field ""
    $hostHelp = New-RowLabel "Lowercase letters, numbers, and hyphens only. Cannot start or end with a hyphen."
    $versionBox = New-Field "1.96.4"
    $versionNote = New-RowLabel "Default is pinned for JetKVM compatibility. Change only if you know the version works on your device."
    $step3Grid.Controls.Add((New-RowLabel "Install script"), 0, 0)
    $step3Grid.Controls.Add($installerSourceBox, 1, 0)
    $step3Grid.SetColumnSpan($installerSourceBox, 2)
    $step3Grid.Controls.Add($installerSourceHelp, 1, 1)
    $step3Grid.SetColumnSpan($installerSourceHelp, 2)
    $step3Grid.Controls.Add($cleanCheck, 1, 2)
    $step3Grid.SetColumnSpan($cleanCheck, 2)
    $step3Grid.Controls.Add($useAuthKeyCheck, 1, 3)
    $step3Grid.SetColumnSpan($useAuthKeyCheck, 2)
    $step3Grid.Controls.Add((New-RowLabel "Tailscale auth key"), 0, 4)
    $step3Grid.Controls.Add($authBox, 1, 4)
    $step3Grid.SetColumnSpan($authBox, 2)
    $step3Grid.Controls.Add($authHelp, 1, 5)
    $step3Grid.SetColumnSpan($authHelp, 2)
    $step3Grid.Controls.Add((New-RowLabel "Tailscale hostname"), 0, 6)
    $step3Grid.Controls.Add($hostBox, 1, 6)
    $step3Grid.SetColumnSpan($hostBox, 2)
    $step3Grid.Controls.Add($hostHelp, 1, 7)
    $step3Grid.SetColumnSpan($hostHelp, 2)
    $step3Grid.Controls.Add((New-RowLabel "Tailscale version"), 0, 8)
    $step3Grid.Controls.Add($versionBox, 1, 8)
    $step3Grid.SetColumnSpan($versionBox, 2)
    $step3Grid.Controls.Add($versionNote, 1, 9)
    $step3Grid.SetColumnSpan($versionNote, 2)
    $setupLayout.Controls.Add($step3Group, 0, 2)

    $manualSteps = New-Group "Step 4 - Required JetKVM UI steps"
    & $makeGroupAutoHeight $manualSteps
    $manualSteps.BackColor = [Drawing.Color]::FromArgb(69, 46, 16)
    $manualSteps.ForeColor = [Drawing.Color]::FromArgb(253, 230, 138)
    $manualGrid = New-StepGrid 3
    $manualGrid.RowStyles.Clear()
    foreach ($height in @(40, 28, 24)) {
        $manualGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, (S $height))) | Out-Null
    }
    $manualSteps.Controls.Add($manualGrid)
    $stepsText = [Windows.Forms.Label]::new()
    $stepsText.Text = "Important: Step 5 needs Developer Mode SSH enabled on the JetKVM.`r`n1. Open the JetKVM UI and install any system updates.  2. Settings > Advanced: enable Developer Mode, paste the public SSH key, then save."
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
    $manualGrid.SetRowSpan($stepsText, 2)
    $manualGrid.Controls.Add($securityText, 0, 2)
    $manualGrid.SetColumnSpan($securityText, 2)
    $manualGrid.Controls.Add($copyKeyButton, 2, 0)
    $manualGrid.Controls.Add($openUiButton2, 2, 1)
    $setupLayout.Controls.Add($manualSteps, 0, 3)

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
    $runButton.Text = "Step 5 - Run install"
    $runButton.Dock = "Fill"
    $runButton.Margin = New-ScaledPadding 8 4 0 4
    Set-ButtonStyle $runButton "Primary"
    $setupActionPanel.Controls.Add($statusLabel, 0, 0)
    $setupActionPanel.Controls.Add($runButton, 1, 0)
    $setupLayout.Controls.Add($setupActionPanel, 0, 4)

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
    $tailscaleHelp = [Windows.Forms.Label]::new()
    $tailscaleHelp.Dock = "Fill"
    $tailscaleHelp.ForeColor = $ui.Muted
    $tailscaleHelp.Font = [Drawing.Font]::new("Segoe UI", 9)
    $tailscaleHelp.Text = "Check Tailscale prints status, routes, DNS, version, and running processes from the JetKVM.`r`nRepair Tailscale recreates the boot hook if needed, may reboot JetKVM when the hook has just been repaired, then runs tailscale up using the current auth-key/hostname fields or opens a browser login URL when no auth key is used.`r`nRemove Tailscale logs out where possible, stops Tailscale, removes /userdata/tailscale, and reboots the JetKVM."
    $tailscaleHelpGroup.Controls.Add($tailscaleHelp)
    $tailscaleLayout.Controls.Add($tailscaleHelpGroup, 0, 1)

    $macGroup = New-Group "Network MAC identity"
    & $makeGroupAutoHeight $macGroup
    $macGrid = New-StepGrid 7
    $macGrid.RowStyles.Clear()
    foreach ($height in @(34, 30, 30, 30, 30, 34, 42)) {
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

    $settingsGroup = New-Group "Installer sources"
    & $makeGroupAutoHeight $settingsGroup
    $settingsGrid = New-StepGrid 8
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
    $metadataPath = Join-Path $PSScriptRoot "install-tailscale.metadata.json"
    $metadataText = "JetFUEL repo reference copy metadata not found."
    if (Test-Path -LiteralPath $metadataPath) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            $metadataText = "JetFUEL repo reference copy of JetKVM script: fetched $($metadata.fetched_utc), SHA256 $($metadata.sha256)"
        } catch {}
    }
    $metadataLabel = New-RowLabel $metadataText
    $requirementsLabel = [Windows.Forms.Label]::new()
    $requirementsLabel.Dock = "Fill"
    $requirementsLabel.ForeColor = $ui.Muted
    $requirementsLabel.Font = [Drawing.Font]::new("Segoe UI", 9)
    $requirementsLabel.Text = "Custom script requirements:`r`n- POSIX shell script runnable by Git Bash or WSL bash.`r`n- Accepts: [-v|--version <tailscale-version>] [-y|--yes] [-c|--clean] <JetKVM-IP> [-- <tailscale up args...>].`r`n- Must install/configure Tailscale on JetKVM, handle reboot/return, and print any Tailscale login URL.`r`n- SSH calls should use standard ssh root@<ip> patterns or respect JETFUEL_SSH_OPTS so the wizard can patch/use the selected key."
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
    $settingsGrid.SetRowSpan($requirementsLabel, 4)
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

    $setBusy = {
        param([bool]$Busy, [string]$Status)
        $runButton.Enabled = -not $Busy
        $preflightButton.Enabled = -not $Busy
        $checkTailscaleButton.Enabled = -not $Busy
        $repairTailscaleButton.Enabled = -not $Busy
        $removeTailscaleButton.Enabled = -not $Busy
        $refreshMacButton.Enabled = -not $Busy
        $generateMacButton.Enabled = -not $Busy
        $applyMacButton.Enabled = -not $Busy
        $clearMacButton.Enabled = -not $Busy
        $scanThisPcButton.Enabled = -not $Busy
        $applyEdidButton.Enabled = (-not $Busy) -and $displayChoiceBox.Enabled -and ($null -ne $displayChoiceBox.SelectedItem)
        $applyUsbButton.Enabled = (-not $Busy) -and $usbChoiceBox.Enabled -and ($null -ne $usbChoiceBox.SelectedItem)
        $applyDeviceSettingsButton.Enabled = -not $Busy
        $exitButton.Enabled = -not $Busy
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
            "OK" { $Label.Text = "[OK] $Text"; $Label.ForeColor = $ui.Good }
            "Warn" { $Label.Text = "[WARN] $Text"; $Label.ForeColor = $ui.Warn }
            "Fail" { $Label.Text = "[FAIL] $Text"; $Label.ForeColor = $ui.Bad }
            default { $Label.Text = "[ ] $Text"; $Label.ForeColor = $ui.Text }
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
            "Exit JetFUEL?`r`n`r`nYes = clean up JetFUEL temp/downloaded files, optionally uninstall Git Bash, then exit.`r`nNo = exit only.`r`nCancel = stay here.`r`n`r`nSSH key files are left in place.",
            "Exit JetFUEL",
            "YesNoCancel",
            "Warning"
        )
        if ($choice -eq [Windows.Forms.DialogResult]::Cancel) { return }

        if ($choice -eq [Windows.Forms.DialogResult]::Yes) {
            try {
                & $setBusy $true "Cleaning up..."
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
            $cmd = "echo '--- date ---'; date 2>&1 || true; echo '--- network ---'; ip route 2>&1 || true; cat /etc/resolv.conf 2>&1 || true; echo '--- tailscale persistence/autostart ---'; if [ -x /userdata/tailscale/tailscale ]; then echo '[OK] /userdata/tailscale/tailscale exists'; else echo '[FAIL] /userdata/tailscale/tailscale missing or not executable'; fi; if [ -x /userdata/tailscale/tailscaled ]; then echo '[OK] /userdata/tailscale/tailscaled exists'; else echo '[FAIL] /userdata/tailscale/tailscaled missing or not executable'; fi; if [ -f /userdata/init.d/S22tailscale ]; then echo '[OK] /userdata/init.d/S22tailscale exists'; grep -n 'tailscaled\|/dev/net/tun\|killall tailscaled' /userdata/init.d/S22tailscale 2>&1 || true; else echo '[FAIL] /userdata/init.d/S22tailscale missing - Tailscale may not start after reboot'; fi; if [ -f /userdata/init.d/S22tailscale ] && grep -q '/userdata/tailscale/tailscaled' /userdata/init.d/S22tailscale; then echo '[OK] boot hook starts tailscaled'; else echo '[FAIL] boot hook does not start /userdata/tailscale/tailscaled'; fi; echo '--- tailscale status ---'; tailscale status 2>&1 || true; echo '--- tailscale ip ---'; tailscale ip -4 2>&1 || true; echo '--- tailscale version ---'; tailscale version 2>&1 || true; echo '--- processes ---'; ps | grep tailscale | grep -v grep 2>&1 || echo '[WARN] no tailscale processes found'; echo '--- check complete ---'"
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

            $ensurePersistentCmd = "echo '--- ensure tailscale persistence/autostart ---'; if [ -x /userdata/tailscale/tailscale ]; then /userdata/tailscale/tailscale configure jetkvm 2>&1 || true; else echo 'WARN: /userdata/tailscale/tailscale is missing'; fi; if [ -f /userdata/init.d/S22tailscale ]; then chmod +x /userdata/init.d/S22tailscale 2>&1 || true; fi; if ! ps | grep '[t]ailscaled' >/dev/null 2>&1; then echo 'tailscaled is not running; starting it'; if [ -x /userdata/init.d/S22tailscale ]; then /userdata/init.d/S22tailscale start 2>&1 || true; elif [ -x /userdata/tailscale/tailscaled ]; then /userdata/tailscale/tailscaled >/dev/null 2>&1 & else echo 'WARN: cannot start tailscaled because binary is missing'; fi; sleep 2; fi; echo '--- persistence check ---'; if [ -f /userdata/init.d/S22tailscale ] && grep -q '/userdata/tailscale/tailscaled' /userdata/init.d/S22tailscale; then echo '[OK] boot hook exists'; else echo '[FAIL] boot hook missing or incomplete'; fi; ps | grep tailscale | grep -v grep 2>&1 || true"
            $persistentResult = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command $ensurePersistentCmd -TimeoutSeconds 45
            if ($persistentResult.Output) { $persistentResult.Output -split "`n" | ForEach-Object { & $log $_ } }
            if ($persistentResult.Output -match 'Now restart your JetKVM|restart your JetKVM') {
                $answer = [Windows.Forms.MessageBox]::Show(
                    "The JetKVM Tailscale boot hook was repaired, but JetKVM says it must reboot before tailscaled will start.`r`n`r`nReboot the JetKVM now? After it comes back online, click Check Tailscale. If it still shows NeedsLogin, click Repair Tailscale again.",
                    "JetKVM reboot required",
                    "YesNo",
                    "Warning"
                )
                if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
                    & $log "Rebooting JetKVM so the Tailscale boot hook can start tailscaled..."
                    try {
                        $null = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command "( sleep 1; reboot ) >/dev/null 2>&1 &" -TimeoutSeconds 5
                    } catch {
                        & $log "Reboot command sent; SSH may disconnect while JetKVM restarts."
                    }
                    & $setBusy $false "JetKVM rebooting"
                } else {
                    & $log "Repair paused. Reboot the JetKVM, then click Check Tailscale."
                    & $setBusy $false "Reboot required"
                }
                return
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
            $cmd = "echo '--- status before repair ---'; tailscale status 2>&1; echo '--- ensure tailscale persistence/autostart ---'; if [ -x /userdata/tailscale/tailscale ]; then /userdata/tailscale/tailscale configure jetkvm 2>&1 || true; fi; if [ -f /userdata/init.d/S22tailscale ]; then chmod +x /userdata/init.d/S22tailscale 2>&1 || true; fi; if ! ps | grep '[t]ailscaled' >/dev/null 2>&1; then if [ -x /userdata/init.d/S22tailscale ]; then /userdata/init.d/S22tailscale start 2>&1 || true; elif [ -x /userdata/tailscale/tailscaled ]; then /userdata/tailscale/tailscaled >/dev/null 2>&1 & fi; sleep 2; fi; echo '--- logout/reset local login state ---'; tailscale logout 2>&1 || true; echo '--- running tailscale up repair ---'; tailscale up $upArgText 2>&1; echo '--- status after repair ---'; tailscale status 2>&1; echo '--- ip after repair ---'; tailscale ip -4 2>&1; echo '--- persistence after repair ---'; if [ -f /userdata/init.d/S22tailscale ] && grep -q '/userdata/tailscale/tailscaled' /userdata/init.d/S22tailscale; then echo '[OK] boot hook exists'; else echo '[FAIL] boot hook missing or incomplete'; fi"
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
