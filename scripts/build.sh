#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/dist}"
STAGE="$(mktemp -d /private/tmp/still-codex-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
# Byte copies keep File Provider metadata out of the signed bundle and compiler inputs.
python3 - "$ROOT" "$STAGE" <<'PY'
import pathlib,sys
src, dst = map(pathlib.Path,sys.argv[1:])
for folder in ['Sources','Resources']:
    for f in (src/folder).rglob('*'):
        if f.is_file():
            t=dst/f.relative_to(src); t.parent.mkdir(parents=True, exist_ok=True); t.write_bytes(f.read_bytes())
(dst/'Info.plist').write_bytes((src/'Info.plist').read_bytes())
PY
APP="$STAGE/栖言 Codex 账号.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGE/cache" "$DEST"
xcrun swiftc -swift-version 5 -O -whole-module-optimization \
  -target "${ARCH:-$(uname -m)}-apple-macosx14.0" -module-cache-path "$STAGE/cache" \
  -framework AppKit -framework SwiftUI -framework Security -framework CryptoKit \
  "$STAGE"/Sources/*.swift -o "$APP/Contents/MacOS/StillCodexSwitcher"
cp "$STAGE/Info.plist" "$APP/Contents/Info.plist"
cp "$STAGE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/StillCodexSwitcher" --self-test
python3 - "$APP" "$DEST" <<'PY'
import pathlib,sys,zipfile
app,dst=map(pathlib.Path,sys.argv[1:])
with zipfile.ZipFile(dst/'Codex-Account-Switcher-macOS.zip','w',zipfile.ZIP_DEFLATED) as z:
    for f in app.rglob('*'):
        if f.is_file(): z.write(f,f.relative_to(app.parent))
PY
printf '\nBuilt: %s/Codex-Account-Switcher-macOS.zip\n' "$DEST"
