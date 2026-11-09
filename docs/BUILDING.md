# Building and signing

Use Xcode 16 or newer; the test suite uses Swift Testing alongside XCTest. The Swift package declares macOS 13 as the deployment target. `scripts/build.sh` builds for the host architecture using `xcode-select` or an explicit `DEVELOPER_DIR`. ARM64 has hardware validation; Intel and older macOS versions still need device testing.

Run `python3 scripts/configure.py` before invoking Swift Package Manager directly. Configuration generates two ignored files: `Sources/MacleanShared/SignerIdentity.swift` and `HelperSupport/Info.plist`. With no `MACLEAN_SIGNING_IDENTITY`, a zero fingerprint disables helper installation. Set a 40-character SHA-1 fingerprint for an available Apple signing identity to build the full privileged flow. Never commit the generated configuration.

The build assembles an app and a ZIP under `dist/`. Default development apps are ad-hoc signed and do not embed the privileged helper. Apple-signed builds embed the helper, pin both sides to the same certificate and include the matching SMJobBless metadata. Switching signing configuration requires rebuilding the entire app; the script replaces its own previous app output so a stale helper is not retained.

```sh
./scripts/build.sh
'dist/WES·MACLEAN.app/Contents/MacOS/Lime' --diagnose
```

`--diagnose` prints a one-shot local system snapshot and exits. It does not install a service or reclaim memory. An optional `--status-preview /tmp/maclean-status.png` renders the same status bar drawing for inspection.

For signed integration testing, run `scripts/build.sh` then `scripts/check-helper.sh` with the same signing identity. The check accepts the expected client, rejects a different bundle identifier and rejects ad-hoc signing. It also validates the archive's signatures and embedded installer metadata. It uses an anonymous listener and does not mutate installed system services. The acceptance check requires a logged-in console user.

Public binary distribution is a separate release step: obtain an appropriate Developer ID identity, timestamp and notarize the app, staple the ticket, and test installation on a clean Mac. The current local build script uses no timestamp and performs no notarization. Do not describe its output as a notarized public installer.

## Compatibility checklist

Before changing deployment support, test sensor sampling, menu bar interaction, app-memory aggregation, Trash recovery, helper installation, reclaim, removal and reinstallation on each supported macOS/hardware combination. The automated suite covers logic and rejection paths; hardware-dependent flows need device testing.
