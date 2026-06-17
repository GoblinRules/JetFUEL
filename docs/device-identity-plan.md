# JetKVM device identity plan

This note records what JetFUEL can safely automate for JetKVM network, display, and USB identity.

The three areas are separate:

- Network identity: Ethernet MAC address.
- Display identity: HDMI EDID exposed to the attached host.
- USB identity: the USB gadget identifiers and enabled HID/storage/audio functions exposed to the attached host.

## References

- JetKVM Developer Mode / SSH docs: https://jetkvm.com/docs/advanced-usage/developing
- JetKVM local access docs: https://jetkvm.com/docs/networking/local-access
- JetKVM HDMI EDID docs: https://jetkvm.com/docs/video/hdmi-edid
- JetKVM MAC address issue: https://github.com/jetkvm/kvm/issues/375
- JetKVM system release v0.2.4: https://github.com/jetkvm/rv1106-system/releases/tag/v0.2.4
- JetKVM USB info UI: https://github.com/jetkvm/kvm/blob/main/ui/src/components/UsbInfoSetting.tsx
- JetKVM USB device UI: https://github.com/jetkvm/kvm/blob/main/ui/src/components/UsbDeviceSetting.tsx
- JetKVM EDID docs/source: https://github.com/jetkvm/kvm
- JetKVM system MAC setup script: https://github.com/jetkvm/rv1106-system/blob/main/project/app/jetkvm/jetkvm-lib.sh
- BSD Hardware EDID catalogue: https://github.com/bsdhw/EDID
- BSD Hardware trends: https://bsd-hardware.info/?view=trends
- EDID reference site: https://edid.tv/
- MACLookup API documentation: https://maclookup.app/api-v2/documentation
- MACLookup downloadable database: https://maclookup.app/downloads/json-database

Source snapshots checked:

- `jetkvm/kvm` HEAD: `3ae3fae42192f8bf493da1965ede5f6dfa873ab9`
- `jetkvm/rv1106-system` HEAD: `ccd1c03732055518f85d7ccb1d3200056aad21ff`
- `rv1106-system` release `v0.2.4`, published 2025-05-03, includes "allow user to override mac address".

## MAC address

JetKVM's current system boot scripts support a user MAC override file:

```text
/userdata/jetkvm/mac_address
```

The boot script also uses:

```text
/userdata/.mac_address
```

for the system-generated stable MAC on devices whose EEPROM MAC is missing or invalid. Older community workarounds wrote directly to the EEPROM/I2C registers or edited startup scripts, but the user override file is the safer supported path to automate.

Recommended JetFUEL behaviour:

- Add this under an advanced identity section, not the default install path.
- Show the current JetKVM MAC address first.
- Offer `Do not change MAC` as the default.
- Offer `Generate stable local-administered MAC` using the `02:xx:xx:xx:xx:xx` range.
- Offer `Custom MAC` with strict validation.
- Apply by writing `/userdata/jetkvm/mac_address` over SSH, then rebooting or restarting networking.
- Warn that changing MAC can change DHCP reservations, local IP address, firewall rules, and Tailscale/network reachability until the user finds the new address.

Do not automatically clone the Windows installer's MAC address. Duplicate MAC addresses on the same LAN cause network conflicts. If a user explicitly wants a cloned MAC, treat that as an expert-only manual custom value with a warning.

Current JetFUEL implementation:

- Adds an `Identity` tab.
- Reads the active JetKVM MAC and user/system MAC files over SSH.
- Generates local-administered MACs for these profiles:
  - JetFUEL generated
  - Android / media
  - Fire TV / streaming
  - TP-Link smart plug / IoT
  - Generic IoT
- Allows a custom MAC value with stricter warnings when the value is not local-administered.
- Writes the user override to `/userdata/jetkvm/mac_address`.
- Clears `/userdata/jetkvm/mac_address` and legacy `/data/ethaddr.txt` when requested.
- Prompts for JetKVM reboot because the active Ethernet MAC changes at network startup.

Validation:

- Require `XX:XX:XX:XX:XX:XX`.
- Reject `00:00:00:00:00:00` and `FF:FF:FF:FF:FF:FF`.
- Prefer locally administered generated addresses for new values.
- Warn if the value does not have the locally administered bit set unless the user confirms it.

MACLookup notes:

MACLookup's API accepts full MAC addresses or prefixes and returns vendor details, block start/end, block size, block type, and random/private flags. The downloadable JSON/CSV databases are useful for future offline validation or optional vendor lookup. JetFUEL should not depend on the live API during normal setup because customer sites may not have internet access, and MAC generation should remain deterministic/offline.

## Display identity / EDID

JetKVM already supports custom EDID. The official docs say the WebUI can use predefined EDID presets or a custom EDID value.

The current JetKVM app source exposes JSON-RPC methods named:

```text
getEDID
setEDID
```

The native EDID implementation currently allows up to 256 bytes. JetFUEL should keep validation to 128 or 256 byte EDIDs unless JetKVM expands this.

Recommended JetFUEL behaviour:

- Add a display identity selector.
- Keep `JetKVM default` as the default.
- Include JetKVM's own presets.
- Add curated presets from BSD Hardware / EDID sources with attribution.
- Add `Use this PC monitor` to capture EDID from the Windows machine running JetFUEL.
- Add `Custom EDID` paste/file input for advanced users.

Windows capture options:

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\*\*\Device Parameters' |
  Where-Object { $_.EDID } |
  Select-Object PSChildName, EDID
```

and:

```powershell
Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID
```

The registry EDID bytes are the most useful source because JetKVM needs raw EDID data.

Validation:

- Strip whitespace from pasted hex.
- Require header `00ffffffffffff00`.
- Require 128 or 256 bytes.
- Validate each 128 byte block checksum: sum modulo 256 must be zero.
- Show parsed vendor/product/resolution when possible.
- Reject invalid EDID by default.

Apply path:

1. Read and validate EDID locally.
2. JetKVM's app supports `setEDID`, but that JSON-RPC path is carried over the app/WebRTC data channel rather than a simple local HTTP endpoint.
3. JetFUEL applies EDID by backing up `/userdata/kvm_config.json`, writing `hdmi_edid_string` over SSH, then prompting for a JetKVM reboot so the KVM service reloads it.
4. Keep WebUI/RPC apply as a future improvement only if a reliable local RPC transport is exposed.

## USB keyboard and mouse identity

JetKVM supports changing the composite USB gadget identity and enabled USB functions.

Current USB identity fields:

```text
vendor_id
product_id
serial_number
manufacturer
product
```

Current device function flags:

```text
keyboard
absolute_mouse
relative_mouse
mass_storage
serial_console
audio
```

The JetKVM WebUI currently includes these USB identity presets:

- JetKVM / USB Emulation Device: `0x1d6b:0x0104`
- Logitech USB Input Device: `0x046d:0xc52b`
- Microsoft Wireless MultiMedia Keyboard: `0x045e:0x005f`
- Dell Multimedia Pro Keyboard: `0x413c:0x2011`

Recommended JetFUEL behaviour:

- Add a USB identity selector.
- Default to JetKVM's current identity.
- Include the same JetKVM presets.
- Add `Use this PC USB device` to choose a detected keyboard, mouse, or unified receiver from Windows.
- Add custom VID/PID/manufacturer/product fields for advanced users.
- Add separate checkboxes for keyboard, absolute mouse, relative mouse, mass storage, serial console, and audio.

Current JetFUEL implementation:

- `Scan this PC identity` logs local monitor EDID records and USB keyboard/mouse/HID VID/PID candidates.
- Scan results are also shown in dropdowns using human-readable names where Windows exposes them.
- The selected display EDID and USB identity candidate can be applied from the Identity tab.
- `Apply EDID` validates 128/256 byte EDID hex, backs up `/userdata/kvm_config.json`, writes `hdmi_edid_string`, syncs the file, and offers to reboot JetKVM.
- `Apply USB` writes the selected VID/PID/manufacturer/product into `usb_config`, syncs the file, and offers to reboot JetKVM.
- USB apply changes the JetKVM composite gadget identity only. It does not promise an exact clone of all physical keyboard/mouse descriptors.

Windows capture options:

```powershell
Get-CimInstance Win32_PnPEntity |
  Where-Object { $_.PNPDeviceID -match 'VID_[0-9A-F]{4}&PID_[0-9A-F]{4}' -and $_.PNPClass -in @('Keyboard','Mouse','HIDClass') } |
  Select-Object Name, Manufacturer, PNPClass, PNPDeviceID
```

Parse `VID_####` and `PID_####` into JetKVM's `0x####` format.

Important limitation:

JetKVM exposes one composite USB gadget identity. It can present enabled functions such as keyboard and mouse, but JetFUEL should not promise an exact clone of separate physical keyboard and mouse descriptors. If the local keyboard and mouse have different VID/PID values, the UI should ask which device identity to emulate or recommend a unified receiver style preset.

## Proposed JetFUEL UI

Add an `Identity` or `Display / USB` section after the core Tailscale flow is stable.

Suggested layout:

- Display EDID:
  - JetKVM default
  - JetKVM preset
  - Common preset
  - This PC monitor
  - Custom EDID
- USB identity:
  - JetKVM default
  - JetKVM preset
  - This PC USB device
  - Custom USB identity
- USB functions:
  - Keyboard
  - Absolute mouse
  - Relative mouse
  - Mass storage
  - Serial console
  - Audio
- Network MAC:
  - Show current MAC
  - Do not change
  - Generate stable local-administered MAC
  - Custom MAC

Keep MAC changes behind an advanced warning. EDID and USB changes can be normal options because JetKVM already exposes them in its WebUI, but they should still show a recovery note before applying.

## Open implementation questions

- Whether JetKVM JSON-RPC can be used reliably from JetFUEL without browser/WebRTC session state.
- Whether USB identity and EDID should be applied during initial setup or as a separate post-install action.
- Whether to store curated EDIDs locally in `data/edid-presets.json`.
- Whether to include only common 1080p/1200p/1440p presets initially, or also 4K/ultrawide options.
- Whether to add an export/import option for the user's captured EDID and USB identity profile.
