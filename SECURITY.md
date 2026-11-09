# Security

WES·MACLEAN uses local macOS APIs. It has no analytics, telemetry, account service, network requests, or automatic updater. The process list is sampled locally while the memory panel is open or on an explicit refresh. Operation logs contain local paths and remain on the device.

## Privileged helper

The optional helper exposes exactly three XPC methods: `version`, `reclaim`, and `remove`. Both peers validate an Apple-anchored code-signing requirement containing the expected bundle identifier and the configured certificate fingerprint. The server also checks that the connecting UID matches the console user. An ad-hoc development build has no usable helper identity and rejects installation before asking for authorization.

The helper runs only `/usr/sbin/purge`, with no arguments, a fixed working directory and a restricted environment. The XPC interface accepts no command, path, or environment. Reclaim runs serially, times out after 45 seconds, and has a 30-second cooldown after success. The helper exits after roughly two minutes of inactivity. Removal targets only its two fixed installation paths.

Initial installation uses `SMJobBless`. This API is deprecated; migration to a modern notarized distribution using `SMAppService` remains future work. No password is stored and no sudoers rule is added. The repository does not include signing certificates, keys, host deployment scripts, or signed release binaries.

## Cleanup boundaries

Cleanup runs as the current user and moves selected files to Finder Trash. It checks location, symlinks, file identity and running application state again before each move. It does not automatically empty Trash, uninstall root services, or search personal documents. Application data defaults to unselected. Filesystem checks and a subsequent path-based Trash operation are not atomic against a hostile process running as the same user; this tool is not a sandbox boundary against that user.

SMC access is read-only: key-info and read-bytes commands only. There is no fan-control or hardware-write interface.

## Reporting

For a security issue, use GitHub's private vulnerability reporting option if enabled. If unavailable, open a minimal issue requesting a private contact, without exploit details, logs or personal paths. Do not attach credentials, signing keys, serial numbers, or full operation logs.
