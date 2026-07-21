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
- Provides a Desktop tab that installs, updates, verifies, launches, and removes the community JetKVM Desktop companion client.
- Provides a Diagnostics tab for health checks, D-state process detection, JetKVM app/crash logs, saveable support reports, reboot tools, OTA access, and guarded DFU recovery resources.
- Keeps colour-coded logs and a copy-log button.
- Provides an Identity tab for JetKVM MAC status, generated local-administered MAC profiles, custom MAC override, and clearing the user override.
- Loads JetKVM's default EDID/USB identity presets, scans the Windows PC for monitor EDID and USB keyboard/mouse VID/PID candidates, then lets you choose human-readable display and USB identity candidates.
- Applies selected EDID and USB identity values to JetKVM by backing up and updating `/userdata/kvm_config.json` over SSH, then offering to reboot JetKVM so the values load.
- Scans this Windows PC for network adapters, optionally enables Wake-on-LAN on the selected adapter, and adds the PC as a JetKVM Wake on LAN target.
- Provides an opt-in `BIOS - WARNING` tab for supported Dell, HP, and Lenovo PCs to scan local BIOS settings and apply Wake-on-LAN / AC power recovery prep using bundled ConfigJon Firmware-Management scripts.
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

## Wake-on-LAN Target Setup

JetFUEL can help set up the JetKVM Wake on LAN button for the Windows PC running the wizard.

On the Identity tab:

- `Scan NICs` finds physical Windows network adapters, prefers active/default-route wired adapters, formats the MAC address, and calculates the IPv4 broadcast address.
- `Set up WOL` can optionally enable Wake-on-LAN on the selected Windows adapter, then writes the PC name, MAC, and broadcast IP into JetKVM's `wake_on_lan_devices` config list.

Local WOL enablement requires PowerShell as Administrator and a NIC driver that exposes Wake-on-Magic-Packet settings. Many PCs also need Wake-on-LAN enabled in BIOS/UEFI. Wired Ethernet is usually more reliable than Wi-Fi for WOL.

The JetKVM target write creates a timestamped backup of `/userdata/kvm_config.json` and then offers to reboot JetKVM so the web UI reloads the Wake on LAN device list.

## BIOS Prep (Dell/HP/Lenovo)

The `BIOS - WARNING` tab is optional and only affects the Windows PC running JetFUEL. It is not part of the Tailscale installation workflow and never runs automatically.

JetFUEL bundles pinned copies of ConfigJon Firmware-Management scripts for Dell, HP, and Lenovo so it can:

- Scan supported local BIOS/UEFI settings.
- Preview planned changes before anything is written.
- Enable BIOS Wake-on-LAN support where the model exposes a matching setting.
- Set power-on-after-AC-restore where the model exposes a matching setting.
- Disable known deep sleep / maximum power saving settings that can block Wake-on-LAN.

JetFUEL does not change PXE/network boot order.

BIOS passwords are typed only for the current run. JetFUEL passes them to the child PowerShell process through environment variables, redacts them from logs, and does not save them.

Credit: BIOS scan/apply support uses [ConfigJon Firmware-Management](https://github.com/ConfigJon/Firmware-Management), bundled under its MIT license.

Useful vendor resources:

- Lenovo direct download: https://download.lenovo.com/pccbbs/thinkvantage_en/system_update_5.08.03.59.exe
- Lenovo download page: https://support.lenovo.com/gb/en/solutions/ht037099
- HP direct download: https://ftp.hp.com/pub/softpaq/sp143501-144000/sp143621.exe
- HP download page: https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HP_BCU.html
- Dell direct download: model-specific; use Dell Support for the target model/service tag.
- Dell download page: https://www.dell.com/support/contents/en-uk/article/product-support/self-support-knowledgebase/fix-common-issues/bios-uefi
- ConfigJon site: https://www.configjon.com/

## Wizard Flow

1. In `1 - Deployment details`, enter the JetKVM address, optional Tailscale name/auth key, SSH key, and installer options.
2. In `2 - Preflight checks`, click `Run preflight`.
3. In `3 - Developer Mode SSH required`, click `Copy public key` and open the JetKVM UI.
4. In JetKVM Settings > Advanced, enable Developer Mode, paste the SSH public key, and save.
5. Click `4 - Install Tailscale`.

After Tailscale is online, you can remove the SSH public key from JetKVM or disable Developer Mode again if you do not need SSH access.

## JetKVM Desktop Companion

The `Desktop` tab integrates [jetkvm-desktop](https://github.com/lkarlslund/jetkvm-desktop/), a separate community native client by Lars Karlslund.

- `Install / update` downloads the latest `jetkvm-desktop-windows-amd64.zip` release from the fixed upstream GitHub repository, verifies GitHub's published SHA-256 digest and required runtime files, and installs it under `%LOCALAPPDATA%\JetFUEL\tools\jetkvm-desktop`.
- If an upstream Windows package omits its known MinGW runtime files, JetFUEL can supply matching x64 copies from the local Git for Windows installation used by the setup workflow. Architecture and completeness are checked before an existing managed installation is changed.
- `Discover JetKVMs` launches the client without an address so it can discover local devices.
- `Connect to Setup address` passes the JetKVM hostname or IP from the Setup tab to the client.
- `Remove client` removes only JetFUEL's managed copy.

JetFUEL does not collect or store the JetKVM password used by this client. Authentication prompts remain inside the separate desktop client. JetKVM Desktop is MIT licensed and is not bundled with this repository; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Installer Script Sources

The `Install script` field in Deployment details lets you choose which install script to use:

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

## Diagnostics, Updates, And Recovery

The `Diagnostics` tab uses the Setup tab JetKVM address and SSH key. Its health actions are read-only:

- `Quick check` collects the JetKVM build/system versions, uptime and load, memory, uninterruptible D-state processes, important services, network, storage, Tailscale state, JetFUEL boot-hook/watchdog state, and recent kernel messages.
- `Save full report` adds the process list, `/userdata/jetkvm/last.log`, text crash logs from `/userdata/jetkvm/crashdump`, display/USB state, thermal readings, persistent-file inventory, and the full kernel log.
- `View app log` and `View crash logs` load the relevant debug text into JetFUEL's colour-coded status log.

Diagnostic reports can contain IP and MAC addresses, device identifiers, and application log content. Review a saved report before sharing it.

Restart and update actions have different scopes:

- `Reboot JetKVM` requests a normal Linux reboot.
- `Force reboot` uses `reboot -f`, skips the normal orderly shutdown path, and is only for a device that will not recover with a normal reboot.
- A true electrical power cycle cannot be performed by software running on the JetKVM after its own input power has been removed. Use switched USB/PoE power, an independent smart plug, or physically disconnect and restore power.
- `Open OTA settings` opens the JetKVM UI. Settings > General > Check for Updates is the recommended update path.
- `Manual app update` is an advanced fallback. It queries JetKVM's official release API for the detected hardware SKU, verifies the app SHA-256, stages the app, and reboots. It updates the app component only and bypasses the normal staged rollout.

The recovery downloads are not routine update tools:

- [DriverAssistant v5.14](https://github.com/jetkvm/rv1106-system/releases/download/v0.2.5/DriverAssitant_v5.14.zip) installs the Rockchip USB recovery driver on Windows.
- [SocToolKit v2.5](https://github.com/jetkvm/rv1106-system/releases/download/v0.2.5/SocToolKit_v2.5_20250701_01_win.zip) flashes a recovery image while the JetKVM is physically placed into Maskrom/DFU mode.
- The [latest jetkvm-v2 recovery image](https://api.jetkvm.com/releases/system_recovery/latest?sku=jetkvm-v2) must only be used for the matching hardware SKU.
- Follow the [official JetKVM factory reset/DFU guide](https://jetkvm.com/docs/advanced-usage/factory-reset-dfu). Recovery flashing can erase or reset the device.

## Tailscale Auth Key Notes

Tailscale auth keys are optional.

Use the auth key checkbox only when you have a pre-authentication key from the Tailscale admin console. It should usually start with:

```text
tskey-auth-
```

The key ID shown in the Tailscale admin table, often ending in `CNTRL`, is not enough.

## Exit and cleanup

Use the red `EXIT` button in the wizard header when you are finished.

- `No` exits only.
- `Yes` removes JetFUEL temp folders and the downloaded `%LOCALAPPDATA%\JetFUEL` bootstrap copy when present.
- This cleanup also removes a JetFUEL-managed JetKVM Desktop client stored below `%LOCALAPPDATA%\JetFUEL\tools`.
- SSH keys are left in place.
- Git for Windows / Git Bash is only uninstalled after a second confirmation because other tools may depend on it.

## Troubleshooting

- Run PowerShell as Administrator for the smoothest setup.
- If Git Bash is missing, JetFUEL can install Git for Windows only when `winget` is installed and working.
- If `winget` says the application cannot be started, use the wizard's App Installer repair option to open the Microsoft Store and install/reinstall App Installer, or choose the Git download option and install Git for Windows manually.
- If the JetKVM stays in `NeedsLogin`, use `Check Tailscale` and look for a login URL in the status log.
- If Tailscale goes offline after a reboot, use `Check Tailscale` to verify `/userdata/init.d/S22tailscale`, then use `Repair Tailscale` to recreate JetFUEL's robust boot hook/watchdog and rerun `tailscale up`.
- If Tailscale says `failed to connect to local tailscaled`, the daemon did not start, its socket was not ready, or its LocalAPI is hung. `Repair Tailscale` writes a boot hook that waits for networking and `/dev/net/tun` before starting `tailscaled`. Its watchdog restarts an exited daemon, a daemon with no socket, or a daemon whose health probe times out three times consecutively.
- If `Repair Tailscale` says JetKVM must restart, allow the reboot. After the JetKVM comes back, run `Check Tailscale`; if it still shows `NeedsLogin`, run `Repair Tailscale` again with a reusable `tskey-auth-...` key or use the browser login URL.
- Tailscale auth keys must be full pre-authentication secrets beginning with `tskey-auth-`. The key ID ending in `CNTRL` is not enough.
- Newer OpenSSH clients can print `connection is not using a post-quantum key exchange algorithm` when talking to JetKVM SSH. JetFUEL suppresses it where supported; it is an SSH warning and should not be treated as the Tailscale install failure.
- Tailscale installation may fail if the JetKVM itself is set up/authenticated using Google auth. Use local JetKVM authentication for this SSH/Developer Mode flow.
- If SSH login fails, confirm Developer Mode is enabled, the public key was saved in JetKVM Settings > Advanced, and the selected private key matches the public key.
- If Wake-on-LAN does not wake the Windows PC, confirm WOL is enabled in BIOS/UEFI, Windows adapter power management, and the NIC advanced driver settings. Prefer wired Ethernet. Some Wi-Fi adapters and USB Ethernet adapters cannot wake a fully powered-off PC.
- If BIOS prep reports unsupported or missing settings, the local model may use different firmware setting names. Check the vendor BIOS tool/download page for that model and use the BIOS UI manually where needed.
- If the BIOS tab reports a bundled ConfigJon script is missing, rerun the latest `irm https://tails.revhooks.cc | iex` bootstrap so the `third_party\ConfigJon-Firmware-Management` files are downloaded.
- If JetKVM video or services become slow or unresponsive, run Diagnostics > Quick check and inspect `UPTIME AND LOAD` plus `D-STATE PROCESSES`. Save a full report before rebooting if the fault is repeatable.
- If the JetKVM app crashes, use Diagnostics > View app log and View crash logs. A saved full report includes those text logs and kernel messages for support analysis.
- Use normal OTA updates before the manual app updater. Use DriverAssistant/SocToolKit only for physical DFU recovery, not as general Windows or JetKVM update utilities.

## Disclaimer

JetFUEL is an unofficial helper tool. It is not made by, endorsed by, or supported by JetKVM or Tailscale.

This tool enables Developer Mode SSH on your JetKVM as part of the setup flow. Developer Mode can weaken device security while enabled. Review the steps before running them, and disable Developer Mode or remove the SSH key afterwards if you do not need ongoing SSH access.

Use at your own risk. You are responsible for reviewing scripts before running them, especially when using `irm | iex`, custom installer URLs, or local installer scripts.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).

Bundled ConfigJon Firmware-Management scripts are MIT licensed by ConfigJon. Their copied license is stored at [third_party/ConfigJon-Firmware-Management/LICENSE](third_party/ConfigJon-Firmware-Management/LICENSE).
