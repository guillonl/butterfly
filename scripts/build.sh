#!/bin/zsh
# Build Butterfly.app : compile SPM, assemble le bundle, signe ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

swift build -c release

APP_NAME="Butterfly"
BUNDLE_ID="com.leoguillon.butterfly"

BUILD="${BUTTERFLY_BUILD_DIR:-$ROOT/dist}"
APP="$BUILD/${APP_NAME}.app"
mkdir -p "$BUILD"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Butterfly "$APP/Contents/MacOS/Butterfly"
cp Info.plist "$APP/Contents/Info.plist"
# Applique le nom/identifiant stable au bundle copié.
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f assets/icon_1024.png ]; then
  sips -z 128 128 assets/icon_1024.png \
    --out "$APP/Contents/Resources/ButterflyMenuBar.png" >/dev/null
fi

# Developer ID pour une distribution notarizable, sinon signature ad hoc. Une
# identité ne doit jamais être choisie implicitement : un certificat local peut
# afficher une demande Trousseau invisible et laisser un bundle à moitié signé.
IDENTITY="-"
if [[ -n "${BUTTERFLY_SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$BUTTERFLY_SIGN_IDENTITY"
fi
# --options runtime : Hardened Runtime, bloque l'injection de dylib dans un
# process qui détient des permissions sensibles (écran, accessibilité).
signed=0
for _ in 1 2 3; do
  xattr -cr "$APP"
  SIGN_ARGS=(--force --options runtime --sign "$IDENTITY")
  if [[ "$IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--timestamp)
  fi
  if codesign "${SIGN_ARGS[@]}" "$APP"; then
    signed=1
    break
  fi
done
[[ "$signed" == 1 ]] || { echo "Signature impossible après 3 essais" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
echo "OK → $APP (signé : $IDENTITY, hardened runtime)"
