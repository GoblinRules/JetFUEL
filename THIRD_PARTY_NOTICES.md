# Third-Party Notices

## JetKVM Desktop

JetFUEL's optional managed Web UI downloads and launches the [jetkvm-desktop](https://github.com/lkarlslund/jetkvm-desktop/) community client by Lars Karlslund.

- License: MIT
- Copyright: Lars Karlslund and jetkvm-desktop contributors
- Distribution: downloaded on demand from the project's GitHub Releases; no binary or source copy is bundled in JetFUEL
- Integrity: JetFUEL verifies the SHA-256 digest published by GitHub for the selected Windows x64 release asset before installation
- Runtime compatibility: if the upstream ZIP omits known MinGW files, JetFUEL may copy matching x64 runtime files from the user's existing Git for Windows installation into its managed client directory. These files are not stored in this repository and are removed with the managed client.
- License preservation: JetFUEL writes the upstream MIT text beside every managed installation as `LICENSE-jetkvm-desktop.txt`.

The upstream license and notices shipped with a downloaded release continue to apply to that client.

## ConfigJon Firmware-Management

JetFUEL includes pinned copies of selected ConfigJon Firmware-Management scripts. See [third_party/ConfigJon-Firmware-Management/LICENSE](third_party/ConfigJon-Firmware-Management/LICENSE) and the project at https://github.com/ConfigJon/Firmware-Management.
