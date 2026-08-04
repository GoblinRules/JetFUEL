# Third-Party Notices

## Microsoft Edge WebView2

JetFUEL's optional embedded Web UI downloads the pinned `Microsoft.Web.WebView2` SDK package from Microsoft's NuGet distribution and loads its WinForms support files from JetFUEL's private application-data directory.

- Package: `Microsoft.Web.WebView2`
- SDK version: `1.0.4078.44`
- Distribution: downloaded on demand from `api.nuget.org`; no SDK binary is bundled in this repository
- Integrity: JetFUEL verifies a pinned SHA-256 before installing the package files
- License preservation: the package's `LICENSE.txt` is installed beside the private support files as `LICENSE-WebView2.txt`
- Runtime: when required, JetFUEL downloads Microsoft's Evergreen WebView2 Runtime installer and verifies its Microsoft Corporation Authenticode signature before execution. JetFUEL cleanup does not uninstall this shared runtime.

Microsoft's license terms shipped in the downloaded package and runtime continue to apply.

## ConfigJon Firmware-Management

JetFUEL includes pinned copies of selected ConfigJon Firmware-Management scripts. See [third_party/ConfigJon-Firmware-Management/LICENSE](third_party/ConfigJon-Firmware-Management/LICENSE) and the project at https://github.com/ConfigJon/Firmware-Management.
