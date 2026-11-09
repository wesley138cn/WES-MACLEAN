# Contributing

Keep contributions within system metrics, application uninstall, junk cleanup and memory management. Preserve the native macOS UI and local-only data handling.

Run `python3 scripts/configure.py`, `xcrun swift test` and `./scripts/build.sh` before submitting changes. Include the macOS version, architecture and validation performed. For sensor changes, include model-specific hardware evidence. For privileged changes, also run signed integration checks and describe any manual installation/removal tests.

Do not add arbitrary-command XPC endpoints, weaken signature checks, store passwords or automatically delete user data. Preserve exact-path matching, confirmation and Trash recovery. Keep user-specific deployment files and generated signing configuration out of commits. New source must have a license compatible with MIT; document third-party provenance if dependencies are introduced.
