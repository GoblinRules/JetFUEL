# JetFUEL

JetFUEL is a Windows 10/11 setup wizard for installing Tailscale on a JetKVM.

It automates the Windows-side pieces:

- Checks for Git Bash and installs Git for Windows with `winget` when missing.
- If Git Bash is missing but WSL bash is present, asks whether to install Git for Windows or use WSL bash for this run.
- Creates an RSA SSH key pair when needed.
- Copies the public key so it can be pasted into JetKVM Developer Mode.
- Shows precheck indicators for Git Bash, local SSH tools, JetKVM ping, JetKVM web UI reachability, and JetKVM SSH login.
- Uses colour-coded logs: green for success, amber for warnings, red for errors.
- Downloads the official JetKVM Tailscale installer.
- Applies the known Git Bash ping compatibility patch.
- Runs the installer with a pinned Tailscale version, optional auth key, optional hostname, and optional clean install.

It guides the JetKVM UI pieces that are not exposed as stable public APIs:

- Set or change the local JetKVM password.
- Check/install JetKVM system updates.
- Enable Developer Mode and save the SSH public key.

## Run Locally

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\JetFuel.ps1
```

## Wizard Flow

1. Enter the JetKVM IP address or hostname.
2. Click `Run preflight` in Step 1 and confirm the indicators show the PC has Git Bash, SSH tools, and can reach the JetKVM.
3. Create or select an SSH key, then click `Copy public key`.
4. Open the JetKVM UI, set a local password if wanted, install JetKVM updates if offered, and enable Developer Mode with the copied public key.
5. Choose Tailscale options and click `Step 5 - Run install`.

The `SSH tools` precheck means this Windows PC has an SSH client available. The `JetKVM SSH login` precheck only turns green after Developer Mode is enabled on the JetKVM and the selected public key has been saved there.

Tailscale auth keys are optional. Enable the auth key checkbox only when you have one from the Tailscale admin console. They usually start with `tskey-auth-`.

## IRM / IEX Bootstrap

Once this repository is published, update the URL in `Install-JetFuel.ps1` if needed and run:

```powershell
irm https://raw.githubusercontent.com/Revellio/JetFUEL/main/Install-JetFuel.ps1 | iex
```

For a fork or private hosting location:

```powershell
irm https://example.com/Install-JetFuel.ps1 | iex
```

## Notes

JetKVM's current documentation installs Tailscale by running the official shell script from a local computer:

```sh
curl -fsSL https://jetkvm.com/install-tailscale.sh | sh -s -- <jetkvm_ip>
```

On Windows, that command needs a Unix-like shell such as WSL or Git Bash. JetFUEL prefers Git Bash because it can be installed with `winget` and works naturally with Windows SSH key paths. If Git Bash is not found but WSL bash is available, the wizard asks which path to use.

The wizard defaults to Tailscale `1.96.4` because JetKVM issue #1461 reported crashes with `1.98.1` and `1.98.2`. A later comment reports `1.98.3` working, but the official JetKVM installer may still block `1.98.x`; change the version only when you have confirmed the current JetKVM installer accepts it.
