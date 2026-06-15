#!/bin/zsh
# Build Butterfly.app : compile SPM, assemble le bundle, signe ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

# Variante optionnelle (pour installer une « Butterfly Beta » À CÔTÉ de la
# version stable, sans conflit) : un nom et un bundle id distincts donnent un
# .app séparé, des préférences séparées et des permissions TCC séparées.
#   BUTTERFLY_APP_NAME="Butterfly Beta" BUTTERFLY_BUNDLE_ID="com.leoguillon.butterfly.beta" bash scripts/build.sh
APP_NAME="${BUTTERFLY_APP_NAME:-Butterfly}"
BUNDLE_ID="${BUTTERFLY_BUNDLE_ID:-com.leoguillon.butterfly}"

APP="dist/${APP_NAME}.app"
mkdir -p dist
xattr -w com.dropbox.ignored 1 dist 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Butterfly "$APP/Contents/MacOS/Butterfly"
cp Info.plist "$APP/Contents/Info.plist"
# Applique le nom/identifiant de la variante au bundle copié.
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Identité stable « Butterfly Dev » si présente (les permissions TCC
# survivent alors aux rebuilds), sinon signature ad hoc.
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Butterfly Dev"; then
  IDENTITY="Butterfly Dev"
fi
# --options runtime : Hardened Runtime, bloque l'injection de dylib dans un
# process qui détient des permissions sensibles (écran, accessibilité).
codesign --force --options runtime --sign "$IDENTITY" "$APP"
echo "OK → $APP (signé : $IDENTITY, hardened runtime)"
