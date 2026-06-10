#!/bin/zsh
# Build Butterfly.app : compile SPM, assemble le bundle, signe ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/Butterfly.app"
mkdir -p dist
xattr -w com.dropbox.ignored 1 dist 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Butterfly "$APP/Contents/MacOS/Butterfly"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Identité stable « Butterfly Dev » si présente (les permissions TCC
# survivent alors aux rebuilds), sinon signature ad hoc.
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Butterfly Dev"; then
  IDENTITY="Butterfly Dev"
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "OK → $APP (signé : $IDENTITY)"
