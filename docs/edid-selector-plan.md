# EDID selector plan

This note records the EDID references and implementation approach for adding an EDID selector to the JetFUEL deployment UI.

## References

- JetKVM HDMI EDID docs: https://jetkvm.com/docs/video/hdmi-edid
- JetKVM source: https://github.com/jetkvm/kvm
- BSD Hardware EDID catalogue: https://github.com/bsdhw/EDID
- BSD Hardware trends: https://bsd-hardware.info/?view=trends
- EDID lookup/reference site: https://edid.tv/

At the time this note was added, `edid.tv` did not respond reliably from the fetch tools. Keep it as a human reference until we confirm whether it has a stable machine-readable interface.

## JetKVM behaviour

JetKVM already supports EDID configuration in its WebUI. The official docs say the WebUI can use predefined EDID presets or a custom EDID value.

The current JetKVM UI source includes these preset choices:

- JetKVM Default
- Acer B246WL, 1920x1200
- ASUS PA248QV, 1920x1200
- DELL D2721H, 1920x1080
- DELL IDRAC EDID, 1280x1024

JetKVM uses JSON-RPC methods named `getEDID` and `setEDID`. The backend saves the selected EDID to config, which is important because the selected EDID should survive reboot.

## Proposed UI

Add an `EDID` selector to the deployment workflow, probably as its own tab or a compact section near the video/setup options.

Suggested options:

- `JetKVM default`: safe baseline.
- `JetKVM preset`: expose the same built-in JetKVM presets.
- `Common resolution`: curated list based on common BSD Hardware monitor trends.
- `This PC monitor`: read EDID from the Windows machine running JetFUEL and offer connected monitors as choices.
- `Custom EDID`: paste hex or load a local `.bin`, `.dat`, or `.hex` file.

Avoid live-scraping trends during normal wizard use. Use a local curated preset file and update it manually when needed.

## Local data files

Recommended future files:

- `data/edid-presets.json`: curated presets with label, category, source URL, resolution, vendor/model, tags, and EDID hex.
- `docs/edid-selector-plan.md`: this implementation note.

The preset file should retain source attribution for any EDID copied from BSD Hardware or JetKVM.

## Windows monitor capture

For the `This PC monitor` option, read monitor EDID from Windows:

- Registry: `HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\*\*\Device Parameters\EDID`
- Display metadata: `Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID`

The registry EDID is the most useful source because it contains the raw bytes needed by JetKVM.

Keyboard and mouse identifiers are separate USB HID/USB gadget identity settings, not EDID. They can be collected later using `Win32_Keyboard`, `Win32_PointingDevice`, or `Win32_PnPEntity`.

See [device-identity-plan.md](device-identity-plan.md) for the broader MAC, EDID, and USB identity investigation.

## Validation rules

Before applying an EDID:

- Require hex input, ignoring whitespace.
- Require a multiple of 128 bytes.
- For JetKVM compatibility, allow only 128 or 256 byte EDIDs unless JetKVM expands support.
- Require the EDID header: `00ffffffffffff00`.
- Validate each 128-byte block checksum: sum of all bytes in the block modulo 256 must be zero.
- Show the parsed vendor/product/resolution when possible.
- Warn before applying an EDID that fails validation. Prefer rejecting invalid EDID by default.

## Apply path

Preferred path:

1. Read the selected EDID.
2. Validate it locally.
3. Apply it to JetKVM using `setEDID`.
4. Read back using `getEDID`.
5. Log the selected label and validation result.

Fallback path:

1. Copy the validated EDID to clipboard.
2. Open the JetKVM WebUI EDID settings.
3. Instruct the user to paste and save.

The JSON-RPC path needs implementation validation because JetKVM appears to use the WebRTC/RPC channel from the WebUI rather than a simple unauthenticated HTTP endpoint.

## Open decisions

- Whether EDID selection should happen during the main Tailscale install or be a separate optional post-install step.
- Whether to include only 1080p/1200p presets initially or add 1440p/4K options.
- Whether to add EDID checksum repair for custom input, or only validate and reject.
- Whether JetFUEL should ever change USB HID identifiers. That should stay separate from EDID unless JetKVM exposes a supported path.
