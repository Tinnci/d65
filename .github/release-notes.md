## Install

- **`D65-<version>-macOS.zip`**: the Mac menu-bar app (Apple silicon, macOS 14+). It is built by CI and signed ad hoc, **not notarized**, so macOS refuses to open it at first. After unzipping, open it from System Settings → Privacy & Security → *Open Anyway*, or run `xattr -dr com.apple.quarantine D65Mac.app`. *Open at login* may not work with an ad hoc signature.
- **`d65-<version>-macos-arm64.zip`**: the command-line tool. Remove the quarantine attribute the same way.
- **No iPhone probe download.** The probe reads the ambient-light sensor through private APIs that aren't in this repository, and it must be signed with your own Apple ID. See [docs/runbook.md](https://github.com/Tinnci/d65/blob/main/docs/runbook.md).

Results so far come from one display and an uncalibrated sensor; see [status](https://github.com/Tinnci/d65/blob/main/docs/status.md). Checksums are in `SHA256SUMS.txt`.
