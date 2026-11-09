#!/bin/bash
set -euo pipefail
LIME_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Use xcode-select or the caller's DEVELOPER_DIR. Never choose a private SDK path.
MACLEAN_SIGNING_IDENTITY="${MACLEAN_SIGNING_IDENTITY:-}"
export MACLEAN_SIGNING_IDENTITY LIME_ROOT
python3 "$LIME_ROOT/scripts/configure.py"
xcrun swift build --package-path "$LIME_ROOT" -c release
LIME_BIN="$(xcrun swift build --package-path "$LIME_ROOT" -c release --show-bin-path)"
LIME_STAGE="$(mktemp -d /private/tmp/wes-maclean.XXXXXX)"
trap 'rm -rf "$LIME_STAGE"' EXIT
LIME_APP="$LIME_STAGE/WES·MACLEAN.app"
export LIME_APP
mkdir -p "$LIME_APP/Contents/MacOS" "$LIME_APP/Contents/Resources" "$LIME_APP/Contents/Library/LaunchServices" "$LIME_ROOT/.build/Lime.iconset"
cp "$LIME_BIN/Lime" "$LIME_APP/Contents/MacOS/Lime"
if [ -n "$MACLEAN_SIGNING_IDENTITY" ]; then
  cp "$LIME_BIN/MacleanHelper" "$LIME_APP/Contents/Library/LaunchServices/local.wesp.MacleanHelper"
fi
xcrun swift "$LIME_ROOT/scripts/icon.swift" "$LIME_ROOT/.build/Lime.iconset"
iconutil -c icns "$LIME_ROOT/.build/Lime.iconset" -o "$LIME_APP/Contents/Resources/Lime.icns"
python3 - <<'PY'
import os, plistlib
from pathlib import Path
label='local.wesp.MacleanHelper';sha=os.environ['MACLEAN_SIGNING_IDENTITY'].upper()
info={'CFBundleName':'WES·MACLEAN','CFBundleDisplayName':'WES·MACLEAN','CFBundleIdentifier':'local.wesp.Lime',
      'CFBundleExecutable':'Lime','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.3.1','CFBundleVersion':'5',
      'CFBundleIconFile':'Lime','LSMinimumSystemVersion':'13.0','LSUIElement':True,'NSHighResolutionCapable':True,
      'NSPrincipalClass':'NSApplication','NSHumanReadableCopyright':'WESP 2026',
      'SMPrivilegedExecutables':{label:f'anchor apple generic and identifier "{label}" and certificate leaf = H"{sha}"'}}
if not sha: info.pop('SMPrivilegedExecutables')
(Path(os.environ['LIME_APP'])/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
xattr -cr "$LIME_APP"
if [ -n "$MACLEAN_SIGNING_IDENTITY" ]; then
  codesign --force --sign "$MACLEAN_SIGNING_IDENTITY" --options runtime --timestamp=none --identifier local.wesp.MacleanHelper "$LIME_APP/Contents/Library/LaunchServices/local.wesp.MacleanHelper"
  codesign --force --sign "$MACLEAN_SIGNING_IDENTITY" --options runtime --timestamp=none "$LIME_APP"
else
  codesign --force --sign - "$LIME_APP"
fi
codesign --verify --deep --strict "$LIME_APP"
mkdir -p "$LIME_ROOT/dist"
/usr/bin/ditto -c -k --keepParent "$LIME_APP" "$LIME_ROOT/dist/WES·MACLEAN-1.3.1-$(uname -m).zip"
if [ -d "$LIME_ROOT/dist/WES·MACLEAN.app" ]; then
  rm -rf "$LIME_ROOT/dist/WES·MACLEAN.app"
fi
/usr/bin/ditto --norsrc --noextattr "$LIME_APP" "$LIME_ROOT/dist/WES·MACLEAN.app"
xattr -cr "$LIME_ROOT/dist/WES·MACLEAN.app"
printf '%s\n' "$LIME_ROOT/dist/WES·MACLEAN.app"
