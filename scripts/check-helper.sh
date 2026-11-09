#!/bin/bash
set -euo pipefail
MACLEAN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${MACLEAN_SIGNING_IDENTITY:?Set your Apple certificate SHA-1 and run scripts/build.sh first}"
export MACLEAN_SIGNING_IDENTITY
python3 "$MACLEAN_ROOT/scripts/configure.py"
xcrun swift build --package-path "$MACLEAN_ROOT" -c release --product HelperConnectionProbe
MACLEAN_BIN="$(xcrun swift build --package-path "$MACLEAN_ROOT" -c release --show-bin-path)"
MACLEAN_TEST_STAGE="$(mktemp -d /private/tmp/maclean-auth-check.XXXXXX)"
trap 'rm -rf "$MACLEAN_TEST_STAGE"' EXIT
cp "$MACLEAN_BIN/HelperConnectionProbe" "$MACLEAN_TEST_STAGE/probe"
xattr -c "$MACLEAN_TEST_STAGE/probe"
codesign --force --sign "$MACLEAN_SIGNING_IDENTITY" --timestamp=none --options runtime --identifier local.wesp.Lime "$MACLEAN_TEST_STAGE/probe"
"$MACLEAN_TEST_STAGE/probe"
codesign --force --sign "$MACLEAN_SIGNING_IDENTITY" --timestamp=none --options runtime --identifier local.wesp.Unrelated "$MACLEAN_TEST_STAGE/probe"
"$MACLEAN_TEST_STAGE/probe" --expect-rejection
codesign --force --sign - --options runtime --identifier local.wesp.Lime "$MACLEAN_TEST_STAGE/probe"
"$MACLEAN_TEST_STAGE/probe" --expect-rejection
# Inspect the clean archive, rather than the FileProvider-managed Desktop copy.
ditto -x -k "$MACLEAN_ROOT/dist/WES·MACLEAN-1.3.1-$(uname -m).zip" "$MACLEAN_TEST_STAGE"
MACLEAN_CHECK_APP="$MACLEAN_TEST_STAGE/WES·MACLEAN.app"
codesign --verify --deep --strict "$MACLEAN_CHECK_APP"
codesign --verify --strict -R="anchor apple generic and identifier \"local.wesp.Lime\" and certificate leaf = H\"$MACLEAN_SIGNING_IDENTITY\"" "$MACLEAN_CHECK_APP"
codesign --verify --strict -R="anchor apple generic and identifier \"local.wesp.MacleanHelper\" and certificate leaf = H\"$MACLEAN_SIGNING_IDENTITY\"" "$MACLEAN_CHECK_APP/Contents/Library/LaunchServices/local.wesp.MacleanHelper"
python3 - "$MACLEAN_CHECK_APP" <<'PY'
import pathlib, plistlib, struct, sys
app=pathlib.Path(sys.argv[1]);label='local.wesp.MacleanHelper'
data=(app/'Contents/Library/LaunchServices'/label).read_bytes()
magic,cpu,sub,typ,ncmds,size,flags,reserved=struct.unpack_from('<8I',data)
assert magic==0xfeedfacf
sections={};offset=32
for _ in range(ncmds):
    cmd,sz=struct.unpack_from('<II',data,offset)
    if cmd==0x19:
        nsects=struct.unpack_from('<I',data,offset+64)[0]
        for i in range(nsects):
            pos=offset+72+80*i
            name=data[pos:pos+16].split(b'\0')[0].decode()
            length=struct.unpack_from('<Q',data,pos+40)[0];start=struct.unpack_from('<I',data,pos+48)[0]
            if name in ('__info_plist','__launchd_plist'): sections[name]=plistlib.loads(data[start:start+length])
    offset+=sz
info=sections['__info_plist'];job=sections['__launchd_plist'];main=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']==job['Label']==label
assert job['MachServices']=={label:True}
assert not job.get('KeepAlive',False) and not job.get('RunAtLoad',False)
assert not any(k in job for k in ('Program','ProgramArguments','EnvironmentVariables'))
assert len(info['SMAuthorizedClients'])==1 and 'local.wesp.Lime' in info['SMAuthorizedClients'][0]
assert set(main['SMPrivilegedExecutables'])=={label}
print('PASS: clean package signatures and embedded installer metadata')
PY
