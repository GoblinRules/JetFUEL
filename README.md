# JetFUEL

<p align="center">
  <img src="assets/icon.png" alt="JetFUEL logo" width="180">
</p>

JetFUEL is a Windows 10/11 PowerShell setup wizard for installing Tailscale on a JetKVM.

It is designed for non-technical users: the wizard walks through prechecks, SSH key setup, the required JetKVM UI steps, and the Tailscale install flow.

## Quick Start

Open PowerShell as Administrator, then run:

```powershell
irm https://raw.githubusercontent.com/GoblinRules/JetFUEL/main/Install-JetFuel.ps1 | iex
```

That bootstrap downloads JetFUEL into:

```text
%LOCALAPPDATA%\JetFUEL
```

Then it launches the wizard.

Administrator PowerShell is recommended because the bootstrap may need to install or detect Windows prerequisites such as Git Bash.

## Run From A Local Clone

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\JetFuel.ps1
```

## What It Does

- Checks for Git Bash or WSL bash.
- Offers to install Git for Windows with `winget` if Git Bash is missing.
- Checks for Windows SSH tools.
- Creates an SSH key pair when needed.
- Copies the public key so it can be pasted into JetKVM Developer Mode.
- Checks JetKVM network, web UI, and SSH reachability.
- Guides the required JetKVM UI steps.
- Runs the JetKVM Tailscale installer.
- Supports optional Tailscale auth keys.
- Supports optional Tailscale hostname naming.
- Supports clean Tailscale installs.
- Provides Tailscale check, repair, and remove actions.
- Checks and repairs the JetKVM Tailscale boot hook at `/userdata/init.d/S22tailscale`.
- Keeps colour-coded logs and a copy-log button.
- Provides an Identity tab for JetKVM MAC status, generated local-administered MAC profiles, custom MAC override, and clearing the user override.
- Loads JetKVM's default EDID/USB identity presets, scans the Windows PC for monitor EDID and USB keyboard/mouse VID/PID candidates, then lets you choose human-readable display and USB identity candidates.
- Applies selected EDID and USB identity values to JetKVM by backing up and updating `/userdata/kvm_config.json` over SSH, then offering to reboot JetKVM so the values load.
- Applies optional JetKVM device defaults for auto update, keyboard layout, display brightness/timers, HDMI sleep, network hostname/domain, mDNS, and IPv6 mode.
- When a network hostname is enabled, writes JetKVM's runtime `/etc/hostname` and `/etc/hosts` as well as config, then offers a reboot so DHCP startup can use the new name.

## EDID And USB Identity

JetFUEL can scan the Windows machine running the wizard for monitor EDID records and USB keyboard/mouse/HID VID/PID candidates.

On the Identity tab:

- `Scan PC` loads JetKVM's built-in EDID/USB presets, then reads local monitor EDID and USB input candidates. USB candidates include a Windows serial or instance value when Windows exposes one.
- `Apply EDID` writes the selected EDID hex content to JetKVM's `hdmi_edid_string` config value. This is the same content JetKVM's web UI labels as `EDID File`.
- `Apply USB` writes the selected VID/PID/manufacturer/product to JetKVM's `usb_config` value.

Both apply actions create a timestamped backup of `/userdata/kvm_config.json` first, then offer to reboot JetKVM so the KVM service reloads the setting.

USB identity changes the JetKVM composite USB gadget identity. It does not fully clone every descriptor from a separate physical keyboard or mouse.

See [docs/edid-selector-plan.md](docs/edid-selector-plan.md).

JetFUEL is also tracking broader JetKVM identity options for display EDID, USB keyboard/mouse identity, and advanced MAC address override. See [docs/device-identity-plan.md](docs/device-identity-plan.md).

Current identity support includes generated MAC profiles such as Android/media, Fire TV/streaming, TP-Link smart plug/IoT, and generic IoT. These profiles use local-administered generated MAC addresses by default; JetFUEL does not clone the Windows PC MAC address.

## Wizard Flow

1. Enter the JetKVM IP address or hostname.
2. Click `Run preflight` in Step 1.
3. Create or select an SSH key.
4. Click `Copy public key`.
5. Open the JetKVM UI.
6. In JetKVM Settings > Advanced, enable Developer Mode and paste the SSH public key.
7. Save the JetKVM settings.
8. Choose Tailscale options.
9. Click `Step 5 - Run install`.

After Tailscale is online, you can remove the SSH public key from JetKVM or disable Developer Mode again if you do not need SSH access.

## Installer Script Sources

Step 3 lets you choose which install script to use:

- `Official JetKVM`: downloads JetKVM's current hosted installer script.
- `JetFUEL repo`: uses the local reference copy stored in this repository.
- `Custom URL`: downloads a compatible custom script URL configured in Settings.
- `Local file`: runs a compatible local script configured in Settings.

The default is `Official JetKVM`.

The repository includes a copy of JetKVM's installer script as `install-tailscale.sh`. It is included as a reference/fallback in case JetKVM changes the hosted script later. Because the upstream script does not publish a separate script version, JetFUEL records a fetch timestamp and SHA256 hash in `install-tailscale.metadata.json`.

Custom scripts must keep the same command-line contract:

```text
[-v|--version <tailscale-version>] [-y|--yes] [-c|--clean] <JetKVM-IP> [-- <tailscale up args...>]
```

They must install/configure Tailscale on the JetKVM, handle reboot/return, and print any Tailscale login URL.

## JetKVM Device Settings

The Settings tab can apply a small set of JetKVM config-backed defaults by editing `/userdata/kvm_config.json` over SSH and then offering to reboot the JetKVM.

Current settings include:

- General: auto update enabled/disabled.
- Keyboard: English (UK) or English (US) keyboard layout.
- Hardware: display brightness, dim timer, off timer, and HDMI sleep mode.
- Network: optional hostname, domain mode, mDNS mode, and IPv6 mode.

Hostname changes are written to `/userdata/kvm_config.json`, `/etc/hostname`, and `/etc/hosts`. Reboot the JetKVM after applying if you need the DHCP lease name to change; with `udhcpc`, a simple lease renew can keep the old lease hostname until startup uses the new hostname.

JetFUEL does not currently set the local JetKVM password. Use JetKVM Settings > Access for that flow. JetKVM's Hide Header and Hide Status Bar options are browser UI preferences, not device config values, so JetFUEL does not push them globally over SSH.

## Tailscale Auth Key Notes

Tailscale auth keys are optional.

Use the auth key checkbox only when you have a pre-authentication key from the Tailscale admin console. It should usually start with:

```text
tskey-auth-
```

The key ID shown in the Tailscale admin table, often ending in `CNTRL`, is not enough.

## Troubleshooting

- Run PowerShell as Administrator for the smoothest setup.
- If Git Bash is missing, JetFUEL can install Git for Windows only when `winget` is installed and working.
- If `winget` says the application cannot be started, use the wizard's App Installer repair option to open the Microsoft Store and install/reinstall App Installer, or choose the Git download option and install Git for Windows manually.
- If the JetKVM stays in `NeedsLogin`, use `Check Tailscale` and look for a login URL in the status log.
- If Tailscale goes offline after a reboot, use `Check Tailscale` to verify `/userdata/init.d/S22tailscale`, then use `Repair Tailscale` to recreate the boot hook and rerun `tailscale up`.
- If `Repair Tailscale` says JetKVM must restart, allow the reboot. After the JetKVM comes back, run `Check Tailscale`; if it still shows `NeedsLogin`, run `Repair Tailscale` again with a reusable `tskey-auth-...` key or use the browser login URL.
- Tailscale auth keys must be full pre-authentication secrets beginning with `tskey-auth-`. The key ID ending in `CNTRL` is not enough.
- Tailscale installation may fail if the JetKVM itself is set up/authenticated using Google auth. Use local JetKVM authentication for this SSH/Developer Mode flow.
- If SSH login fails, confirm Developer Mode is enabled, the public key was saved in JetKVM Settings > Advanced, and the selected private key matches the public key.

## Disclaimer

JetFUEL is an unofficial helper tool. It is not made by, endorsed by, or supported by JetKVM or Tailscale.

This tool enables Developer Mode SSH on your JetKVM as part of the setup flow. Developer Mode can weaken device security while enabled. Review the steps before running them, and disable Developer Mode or remove the SSH key afterwards if you do not need ongoing SSH access.

Use at your own risk. You are responsible for reviewing scripts before running them, especially when using `irm | iex`, custom installer URLs, or local installer scripts.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
