# Changelog

## 1.3.2

- Count the complete app bundle when framework symlinks precede real version directories.
- Show permission failures with a Finder recovery action and native authorization instructions.
- Refresh the selected app when returning from a system uninstall.
- Track the exact app through Finder renames without requesting access to list Trash.
- Preserve selected related files when app removal fails, regardless of selection order.
- Expand cleanup issues by default so failures are visible.

## 1.3.1

- Recognize the fanless M1 MacBook Air.
- Read the verified M1 Air temperature key and reject invalid readings.
- Add sensor fallback and unsigned-helper regression coverage.
- Add a portable, explicit signing configuration and local development build.
- Publish source under MIT, with build, privacy and security documentation.

## 1.3.0

- Add a fixed-purpose, mutually authenticated XPC helper for file-cache reclaim.
- Require administrator authorization at installation rather than every reclaim.
- Add cooldown, timeout, idle exit, connection checks and helper removal.

## 1.2.0

- Add the menu bar app-memory panel and periodic refresh while open.
- Aggregate application and helper-process RSS.
- Retain menu bar visibility and saved positioning.

## 1.1.0

- Add the compact two-row status layout, SMC readings and native main window.

## 1.0.0

- Add system metrics, application uninstall review and Trash-based cleanup.
