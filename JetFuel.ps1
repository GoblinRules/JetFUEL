#Requires -Version 5.1
param(
    [switch]$NoGui
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
    $winget = Get-CommandPath -Name "winget.exe"
    if (-not $winget) {
        throw "winget is not available. Install Git for Windows from https://git-scm.com/download/win, then run this wizard again."
    }

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
    $form.Size = [Drawing.Size]::new(1120, 900)
    $form.MinimumSize = [Drawing.Size]::new(920, 760)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $form.BackColor = $ui.Window

    $split = [Windows.Forms.SplitContainer]::new()
    $split.Dock = "Fill"
    $split.Orientation = [Windows.Forms.Orientation]::Horizontal
    $split.SplitterWidth = 7
    $split.Panel1MinSize = 640
    $split.Panel2MinSize = 120
    $split.BackColor = $ui.Border
    $form.Controls.Add($split)
    $form.Add_Shown({
        try {
            $split.SplitterDistance = [Math]::Max(
                $split.Panel1MinSize,
                $split.Height - 180
            )
        } catch {}
    })

    $main = [Windows.Forms.TableLayoutPanel]::new()
    $main.Dock = "Fill"
    $main.Padding = [Windows.Forms.Padding]::new(20)
    $main.ColumnCount = 1
    $main.RowCount = 2
    $main.AutoScroll = $false
    $main.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $main.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 76)) | Out-Null
    $main.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $split.Panel1.Controls.Add($main)

    $header = [Windows.Forms.Panel]::new()
    $header.Dock = "Fill"
    $header.BackColor = $ui.Surface2
    $header.Padding = [Windows.Forms.Padding]::new(18, 12, 18, 10)
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
            $logo.Size = [Drawing.Size]::new(42, 42)
            $logo.Location = [Drawing.Point]::new(18, 16)
            $logo.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
            $logo.Image = [Drawing.Image]::FromFile($logoPath)
            $header.Controls.Add($logo)
        } catch {}
    }
    $title = [Windows.Forms.Label]::new()
    $title.Text = "JetKVM Tailscale setup"
    $title.Font = [Drawing.Font]::new("Segoe UI", 16, [Drawing.FontStyle]::Bold)
    $title.ForeColor = $ui.Text
    $title.AutoSize = $true
    $title.Location = [Drawing.Point]::new(72, 10)
    $subtitle = [Windows.Forms.Label]::new()
    $subtitle.Text = "Follow the steps from top to bottom. Run preflight first to confirm this PC can see the JetKVM."
    $subtitle.AutoSize = $true
    $subtitle.ForeColor = $ui.Muted
    $subtitle.Location = [Drawing.Point]::new(74, 43)
    $header.Controls.AddRange(@($title, $subtitle))
    $main.Controls.Add($header, 0, 0)

    function New-Group([string]$Text) {
        $group = [Windows.Forms.GroupBox]::new()
        $group.Text = $Text
        $group.Dock = "Fill"
        $group.BackColor = $ui.Surface
        $group.ForeColor = $ui.Text
        $group.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
        $group.Padding = [Windows.Forms.Padding]::new(12, 10, 12, 12)
        $group.Margin = [Windows.Forms.Padding]::new(0, 8, 0, 0)
        return $group
    }

    function New-StepGrid([int]$Rows) {
        $grid = [Windows.Forms.TableLayoutPanel]::new()
        $grid.Dock = "Fill"
        $grid.ColumnCount = 3
        $grid.RowCount = $Rows
        $grid.Padding = [Windows.Forms.Padding]::new(4, 12, 4, 4)
        $grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 175)) | Out-Null
        $grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
        $grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 140)) | Out-Null
        for ($i = 0; $i -lt $Rows; $i++) {
            $grid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 40)) | Out-Null
        }
        return $grid
    }

    function New-Field([string]$Text) {
        $box = [Windows.Forms.TextBox]::new()
        $box.Text = $Text
        $box.Dock = "Fill"
        $box.Margin = [Windows.Forms.Padding]::new(0, 5, 10, 5)
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
        $label.Margin = [Windows.Forms.Padding]::new(0, 0, 10, 0)
        $label.ForeColor = $ui.Text
        $label.Font = [Drawing.Font]::new("Segoe UI", 9)
        return $label
    }

    function Set-ButtonStyle([Windows.Forms.Button]$Button, [string]$Kind = "Secondary") {
        $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
        $Button.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
        $Button.Cursor = [Windows.Forms.Cursors]::Hand
        $Button.UseVisualStyleBackColor = $false
        $Button.FlatAppearance.BorderSize = 1
        if ($Kind -eq "Primary") {
            $Button.BackColor = $ui.Accent
            $Button.ForeColor = [Drawing.Color]::White
            $Button.FlatAppearance.BorderColor = $ui.AccentHover
        } else {
            $Button.BackColor = $ui.Surface2
            $Button.ForeColor = $ui.Text
            $Button.FlatAppearance.BorderColor = $ui.Border
        }
    }

    function Set-CheckStyle([Windows.Forms.CheckBox]$CheckBox) {
        $CheckBox.ForeColor = $ui.Text
        $CheckBox.Font = [Drawing.Font]::new("Segoe UI", 9)
        $CheckBox.BackColor = $ui.Surface
        $CheckBox.Margin = [Windows.Forms.Padding]::new(0, 5, 10, 5)
    }

    $pageShell = [Windows.Forms.TableLayoutPanel]::new()
    $pageShell.Dock = "Fill"
    $pageShell.BackColor = $ui.Window
    $pageShell.Margin = [Windows.Forms.Padding]::new(0, 10, 0, 10)
    $pageShell.ColumnCount = 1
    $pageShell.RowCount = 2
    $pageShell.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $pageShell.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 38)) | Out-Null
    $pageShell.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null

    $navPanel = [Windows.Forms.TableLayoutPanel]::new()
    $navPanel.Dock = "Fill"
    $navPanel.BackColor = $ui.Window
    $navPanel.ColumnCount = 5
    $navPanel.RowCount = 1
    foreach ($width in @(132, 132, 132, 132)) {
        $navPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, $width)) | Out-Null
    }
    $navPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null

    $setupTabButton = [Windows.Forms.Button]::new()
    $setupTabButton.Text = "Setup"
    $setupTabButton.Dock = "Fill"
    $setupTabButton.Margin = [Windows.Forms.Padding]::new(0, 0, 4, 0)
    $tailscaleTabButton = [Windows.Forms.Button]::new()
    $tailscaleTabButton.Text = "Tailscale"
    $tailscaleTabButton.Dock = "Fill"
    $tailscaleTabButton.Margin = [Windows.Forms.Padding]::new(0, 0, 4, 0)
    $settingsTabButton = [Windows.Forms.Button]::new()
    $settingsTabButton.Text = "Settings"
    $settingsTabButton.Dock = "Fill"
    $settingsTabButton.Margin = [Windows.Forms.Padding]::new(0, 0, 4, 0)
    $helpTabButton = [Windows.Forms.Button]::new()
    $helpTabButton.Text = "Help"
    $helpTabButton.Dock = "Fill"
    $helpTabButton.Margin = [Windows.Forms.Padding]::new(0, 0, 4, 0)
    Set-ButtonStyle $setupTabButton "Primary"
    Set-ButtonStyle $tailscaleTabButton "Secondary"
    Set-ButtonStyle $settingsTabButton "Secondary"
    Set-ButtonStyle $helpTabButton "Secondary"
    $navPanel.Controls.Add($setupTabButton, 0, 0)
    $navPanel.Controls.Add($tailscaleTabButton, 1, 0)
    $navPanel.Controls.Add($settingsTabButton, 2, 0)
    $navPanel.Controls.Add($helpTabButton, 3, 0)

    $pageHost = [Windows.Forms.Panel]::new()
    $pageHost.Dock = "Fill"
    $pageHost.BackColor = $ui.Window

    $setupPage = [Windows.Forms.Panel]::new()
    $setupPage.Dock = "Fill"
    $setupPage.BackColor = $ui.Window
    $tailscalePage = [Windows.Forms.Panel]::new()
    $tailscalePage.Dock = "Fill"
    $tailscalePage.BackColor = $ui.Window
    $settingsPage = [Windows.Forms.Panel]::new()
    $settingsPage.Dock = "Fill"
    $settingsPage.BackColor = $ui.Window
    $helpPage = [Windows.Forms.Panel]::new()
    $helpPage.Dock = "Fill"
    $helpPage.BackColor = $ui.Window

    $setupLayout = [Windows.Forms.TableLayoutPanel]::new()
    $setupLayout.Dock = "Fill"
    $setupLayout.AutoScroll = $false
    $setupLayout.BackColor = $ui.Window
    $setupLayout.ColumnCount = 2
    $setupLayout.RowCount = 4
    $setupLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 56)) | Out-Null
    $setupLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 44)) | Out-Null
    $setupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 150)) | Out-Null
    $setupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 260)) | Out-Null
    $setupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $setupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 58)) | Out-Null
    $setupPage.Controls.Add($setupLayout)

    $tailscaleLayout = [Windows.Forms.TableLayoutPanel]::new()
    $tailscaleLayout.Dock = "Fill"
    $tailscaleLayout.BackColor = $ui.Window
    $tailscaleLayout.ColumnCount = 1
    $tailscaleLayout.RowCount = 2
    $tailscaleLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $tailscaleLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 118)) | Out-Null
    $tailscaleLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $tailscalePage.Controls.Add($tailscaleLayout)

    $settingsLayout = [Windows.Forms.TableLayoutPanel]::new()
    $settingsLayout.Dock = "Fill"
    $settingsLayout.BackColor = $ui.Window
    $settingsLayout.ColumnCount = 1
    $settingsLayout.RowCount = 1
    $settingsLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $settingsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $settingsPage.Controls.Add($settingsLayout)

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

Tailscale tab
- Check Tailscale prints status, Tailscale IP, version, routes, DNS, and running Tailscale processes.
- Repair Tailscale reruns tailscale up with the current auth key/hostname settings, or opens the manual login URL when no auth key is used.
- Remove Tailscale logs out where possible, stops Tailscale, removes /userdata/tailscale, and reboots the JetKVM.

Settings tab
- Custom script URL is only used when Step 3 is set to Custom URL.
- Local script file is only used when Step 3 is set to Local file.
- The JetFUEL repo script is a copied reference/fallback copy of JetKVM's installer. It exists in case JetKVM changes the hosted script later.
- Custom scripts must keep the same command-line contract:
  [-v|--version <tailscale-version>] [-y|--yes] [-c|--clean] <JetKVM-IP> [-- <tailscale up args...>]
- Custom scripts must install/configure Tailscale on the JetKVM, handle reboot/return, and print any Tailscale login URL.

Status log
- Shows the detailed output from preflight, install, repair, remove, and checks.
- Use Copy logs when reporting an issue or saving the output.
- Drag the splitter above the log to make it larger or smaller.
"@
    $helpPage.Controls.Add($helpBox)

    $pageHost.Controls.AddRange(@($helpPage, $settingsPage, $tailscalePage, $setupPage))
    $showPage = {
        param([string]$Name)
        $setupPage.Visible = ($Name -eq "Setup")
        $tailscalePage.Visible = ($Name -eq "Tailscale")
        $settingsPage.Visible = ($Name -eq "Settings")
        $helpPage.Visible = ($Name -eq "Help")
        Set-ButtonStyle $setupTabButton $(if ($Name -eq "Setup") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $tailscaleTabButton $(if ($Name -eq "Tailscale") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $settingsTabButton $(if ($Name -eq "Settings") { "Primary" } else { "Secondary" })
        Set-ButtonStyle $helpTabButton $(if ($Name -eq "Help") { "Primary" } else { "Secondary" })
    }
    $setupTabButton.Add_Click({ & $showPage "Setup" })
    $tailscaleTabButton.Add_Click({ & $showPage "Tailscale" })
    $settingsTabButton.Add_Click({ & $showPage "Settings" })
    $helpTabButton.Add_Click({ & $showPage "Help" })

    $pageShell.Controls.Add($navPanel, 0, 0)
    $pageShell.Controls.Add($pageHost, 0, 1)
    $main.Controls.Add($pageShell, 0, 1)
    & $showPage "Setup"

    $precheckGroup = New-Group "Step 1 - Prechecks"
    $preGrid = New-StepGrid 3
    $preGrid.RowStyles.Clear()
    foreach ($height in @(38, 38, 42)) {
        $preGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, $height)) | Out-Null
    }
    $precheckGroup.Controls.Add($preGrid)
    $bashStatus = New-RowLabel "[ ] Git Bash: not checked"
    $sshStatus = New-RowLabel "[ ] SSH tools: not checked"
    $sshLoginStatus = New-RowLabel "[ ] JetKVM SSH login: enable Developer Mode first"
    $kvmStatus = New-RowLabel "[ ] JetKVM network: enter IP, then preflight"
    $httpStatus = New-RowLabel "[ ] JetKVM web UI: not checked"
    $preflightButton = [Windows.Forms.Button]::new()
    $preflightButton.Text = "Run preflight"
    $preflightButton.Dock = "None"
    $preflightButton.Anchor = "None"
    $preflightButton.Size = [Drawing.Size]::new(132, 34)
    $preflightButton.Margin = [Windows.Forms.Padding]::new(6)
    Set-ButtonStyle $preflightButton "Secondary"
    $preGrid.Controls.Add($bashStatus, 0, 0)
    $preGrid.Controls.Add($kvmStatus, 1, 0)
    $preGrid.Controls.Add($sshStatus, 0, 1)
    $preGrid.Controls.Add($httpStatus, 1, 1)
    $preGrid.Controls.Add($sshLoginStatus, 0, 2)
    $preGrid.SetColumnSpan($sshLoginStatus, 2)
    $preGrid.Controls.Add($preflightButton, 2, 0)
    $preGrid.SetRowSpan($preflightButton, 2)
    $setupLayout.Controls.Add($precheckGroup, 0, 0)

    $step2Group = New-Group "Step 2 - JetKVM and SSH"
    $step2Grid = New-StepGrid 4
    $step2Grid.RowStyles.Clear()
    foreach ($height in @(48, 48, 48, 48)) {
        $step2Grid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, $height)) | Out-Null
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
    $step3Grid = New-StepGrid 10
    $step3Grid.Dock = "Top"
    $step3Grid.Height = 420
    $step3Grid.ColumnStyles.Clear()
    $step3Grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 155)) | Out-Null
    $step3Grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $step3Grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 10)) | Out-Null
    $step3Group.Controls.Add($step3Grid)
    $installerSourceBox = [Windows.Forms.ComboBox]::new()
    $installerSourceBox.Dock = "Fill"
    $installerSourceBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $installerSourceBox.Margin = [Windows.Forms.Padding]::new(0, 5, 10, 5)
    $installerSourceBox.BackColor = $ui.Input
    $installerSourceBox.ForeColor = $ui.InputText
    $installerSourceBox.Font = [Drawing.Font]::new("Segoe UI", 9)
    [void]$installerSourceBox.Items.AddRange(@("Official JetKVM", "JetFUEL repo", "Custom URL", "Local file"))
    $installerSourceBox.SelectedItem = "Official JetKVM"
    $installerSourceHelp = New-RowLabel "Default uses JetKVM's current script. See Settings for the local reference copy and custom source requirements."
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
    $cleanCheck = [Windows.Forms.CheckBox]::new()
    $cleanCheck.Text = "Clean Tailscale install on JetKVM (creates a new Tailscale machine identity)"
    $cleanCheck.Dock = "Fill"
    Set-CheckStyle $cleanCheck
    $step3Grid.Controls.Add((New-RowLabel "Install script"), 0, 0)
    $step3Grid.Controls.Add($installerSourceBox, 1, 0)
    $step3Grid.SetColumnSpan($installerSourceBox, 2)
    $step3Grid.Controls.Add($installerSourceHelp, 1, 1)
    $step3Grid.SetColumnSpan($installerSourceHelp, 2)
    $step3Grid.Controls.Add($useAuthKeyCheck, 1, 2)
    $step3Grid.SetColumnSpan($useAuthKeyCheck, 2)
    $step3Grid.Controls.Add((New-RowLabel "Tailscale auth key"), 0, 3)
    $step3Grid.Controls.Add($authBox, 1, 3)
    $step3Grid.SetColumnSpan($authBox, 2)
    $step3Grid.Controls.Add($authHelp, 1, 4)
    $step3Grid.SetColumnSpan($authHelp, 2)
    $step3Grid.Controls.Add((New-RowLabel "Tailscale hostname"), 0, 5)
    $step3Grid.Controls.Add($hostBox, 1, 5)
    $step3Grid.SetColumnSpan($hostBox, 2)
    $step3Grid.Controls.Add($hostHelp, 1, 6)
    $step3Grid.SetColumnSpan($hostHelp, 2)
    $step3Grid.Controls.Add((New-RowLabel "Tailscale version"), 0, 7)
    $step3Grid.Controls.Add($versionBox, 1, 7)
    $step3Grid.SetColumnSpan($versionBox, 2)
    $step3Grid.Controls.Add($versionNote, 1, 8)
    $step3Grid.SetColumnSpan($versionNote, 2)
    $step3Grid.Controls.Add($cleanCheck, 1, 9)
    $step3Grid.SetColumnSpan($cleanCheck, 2)
    $setupLayout.Controls.Add($step3Group, 1, 0)
    $setupLayout.SetRowSpan($step3Group, 3)

    $manualSteps = New-Group "Step 4 - Required JetKVM UI steps"
    $manualSteps.BackColor = [Drawing.Color]::FromArgb(69, 46, 16)
    $manualSteps.ForeColor = [Drawing.Color]::FromArgb(253, 230, 138)
    $manualGrid = New-StepGrid 3
    $manualGrid.RowStyles.Clear()
    $manualGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 70)) | Out-Null
    $manualGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 40)) | Out-Null
    $manualGrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $manualSteps.Controls.Add($manualGrid)
    $stepsText = [Windows.Forms.Label]::new()
    $stepsText.Text = "Important: the installer cannot continue until Developer Mode SSH is enabled on the JetKVM.`r`n`r`n1. Open the JetKVM UI, set or confirm the local password if wanted, and install any JetKVM system updates from Settings.`r`n2. In Settings > Advanced, enable Developer Mode and paste the public SSH key.`r`n3. Save the JetKVM settings before running the Tailscale install."
    $stepsText.Dock = "Fill"
    $stepsText.ForeColor = [Drawing.Color]::FromArgb(255, 251, 235)
    $stepsText.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
    $securityText = [Windows.Forms.Label]::new()
    $securityText.Text = "Security after setup: once Tailscale is online, you can remove the SSH public key from JetKVM or disable Developer Mode again if you do not need SSH access."
    $securityText.Dock = "Fill"
    $securityText.ForeColor = [Drawing.Color]::FromArgb(253, 230, 138)
    $securityText.Font = [Drawing.Font]::new("Segoe UI", 9)
    $copyKeyButton = [Windows.Forms.Button]::new()
    $copyKeyButton.Text = "Copy public key"
    $copyKeyButton.Dock = "Fill"
    $copyKeyButton.Margin = [Windows.Forms.Padding]::new(8, 2, 8, 4)
    Set-ButtonStyle $copyKeyButton "Secondary"
    $openUiButton2 = [Windows.Forms.Button]::new()
    $openUiButton2.Text = "Open JetKVM UI"
    $openUiButton2.Dock = "Fill"
    $openUiButton2.Margin = [Windows.Forms.Padding]::new(8, 2, 8, 4)
    Set-ButtonStyle $openUiButton2 "Secondary"
    $manualGrid.Controls.Add($stepsText, 0, 0)
    $manualGrid.SetColumnSpan($stepsText, 2)
    $manualGrid.SetRowSpan($stepsText, 2)
    $manualGrid.Controls.Add($securityText, 0, 2)
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
    $setupActionPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 190)) | Out-Null
    $runButton = [Windows.Forms.Button]::new()
    $runButton.Text = "Step 5 - Run install"
    $runButton.Dock = "Fill"
    $runButton.Margin = [Windows.Forms.Padding]::new(8, 6, 0, 6)
    Set-ButtonStyle $runButton "Primary"
    $setupActionPanel.Controls.Add($statusLabel, 0, 0)
    $setupActionPanel.Controls.Add($runButton, 1, 0)
    $setupLayout.Controls.Add($setupActionPanel, 0, 3)
    $setupLayout.SetColumnSpan($setupActionPanel, 2)

    $actionPanel = [Windows.Forms.TableLayoutPanel]::new()
    $actionPanel.Dock = "Top"
    $actionPanel.Height = 72
    $actionPanel.BackColor = $ui.Surface
    $actionPanel.ColumnCount = 4
    $actionPanel.Padding = [Windows.Forms.Padding]::new(12)
    $actionPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    foreach ($width in @(170, 170, 170)) {
        $actionPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, $width)) | Out-Null
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
    $checkTailscaleButton.Margin = [Windows.Forms.Padding]::new(8, 6, 0, 6)
    Set-ButtonStyle $checkTailscaleButton "Secondary"
    $repairTailscaleButton = [Windows.Forms.Button]::new()
    $repairTailscaleButton.Text = "Repair Tailscale"
    $repairTailscaleButton.Dock = "Fill"
    $repairTailscaleButton.Margin = [Windows.Forms.Padding]::new(8, 6, 0, 6)
    Set-ButtonStyle $repairTailscaleButton "Secondary"
    $removeTailscaleButton = [Windows.Forms.Button]::new()
    $removeTailscaleButton.Text = "Remove Tailscale"
    $removeTailscaleButton.Dock = "Fill"
    $removeTailscaleButton.Margin = [Windows.Forms.Padding]::new(8, 6, 0, 6)
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
    $tailscaleHelp.Text = "Check Tailscale prints status, routes, DNS, version, and running processes from the JetKVM.`r`nRepair Tailscale runs tailscale up again using the current auth-key/hostname fields, or opens a browser login URL when no auth key is used.`r`nRemove Tailscale logs out where possible, stops Tailscale, removes /userdata/tailscale, and reboots the JetKVM."
    $tailscaleHelpGroup.Controls.Add($tailscaleHelp)
    $tailscaleLayout.Controls.Add($tailscaleHelpGroup, 0, 1)

    $settingsGroup = New-Group "Settings"
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

    $logPanel = [Windows.Forms.TableLayoutPanel]::new()
    $logPanel.Dock = "Fill"
    $logPanel.BackColor = $ui.Window
    $logPanel.RowCount = 2
    $logPanel.ColumnCount = 2
    $logPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $logPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 130)) | Out-Null
    $logPanel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 26)) | Out-Null
    $logPanel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
    $logTitle = [Windows.Forms.Label]::new()
    $logTitle.Text = "Status log"
    $logTitle.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $logTitle.Dock = "Fill"
    $logTitle.ForeColor = $ui.Text
    $copyLogsButton = [Windows.Forms.Button]::new()
    $copyLogsButton.Text = "Copy logs"
    $copyLogsButton.Dock = "Fill"
    $copyLogsButton.Margin = [Windows.Forms.Padding]::new(8, 0, 0, 3)
    Set-ButtonStyle $copyLogsButton "Secondary"
    $logBox = [Windows.Forms.RichTextBox]::new()
    $logBox.Dock = "Fill"
    $logBox.ScrollBars = "Vertical"
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

    $doPreflight = {
        param([bool]$Install)
        try {
            & $setBusy $true "Working..."
            $ip = $ipBox.Text.Trim()
            Assert-ValidIpOrHost -Value $ip

            & $log "Checking Windows prerequisites..."
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
            $cmd = "echo '--- date ---'; date 2>&1; echo '--- network ---'; ip route 2>&1; cat /etc/resolv.conf 2>&1; echo '--- tailscale status ---'; tailscale status 2>&1; echo '--- tailscale ip ---'; tailscale ip -4 2>&1; echo '--- tailscale version ---'; tailscale version 2>&1; echo '--- processes ---'; ps | grep tailscale | grep -v grep 2>&1"
            $result = Invoke-JetKvmSshCommand -JetKvmAddress $ip -KeyPath $keyPath -Command $cmd -TimeoutSeconds 45
            if ($result.Output) { $result.Output -split "`n" | ForEach-Object { & $log $_ } }
            if ($result.ExitCode -eq 0) { & $setBusy $false "Tailscale check complete" }
            else { throw "Tailscale status check failed with exit code $($result.ExitCode)." }
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
            $cmd = "echo '--- status before repair ---'; tailscale status 2>&1; echo '--- logout/reset local login state ---'; tailscale logout 2>&1 || true; echo '--- running tailscale up repair ---'; tailscale up $upArgText 2>&1; echo '--- status after repair ---'; tailscale status 2>&1; echo '--- ip after repair ---'; tailscale ip -4 2>&1"
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
    & $log "Use Copy public key, enable Developer Mode in JetKVM, then run setup."
    [void]$form.ShowDialog()
}

if ($NoGui) {
    throw "NoGui mode is not implemented yet. Run JetFuel.ps1 without -NoGui for the wizard."
}

Start-JetFuelGuiV2
