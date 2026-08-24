#!/bin/zsh
# Build Butterfly.app : compile SPM, assemble le bundle, signe ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

swift build -c release

APP_NAME="${BUTTERFLY_APP_NAME:-Butterfly}"
BUNDLE_ID="${BUTTERFLY_BUNDLE_ID:-com.leoguillon.butterfly}"

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
# Une identité stable est indispensable aux permissions TCC : une signature ad
# hoc réduit la règle désignée au hash du binaire et macOS considère chaque
# reconstruction comme une nouvelle app. Le certificat local est réservé au
# développement ; une release publique fournit explicitement le Developer ID.
IDENTITY="${BUTTERFLY_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"Developer ID Application: Léo Guillon (5584397M43)"'; then
    IDENTITY="Developer ID Application: Léo Guillon (5584397M43)"
  elif security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"Butterfly Dev"'; then
    IDENTITY="Butterfly Dev"
  else
    echo "Aucune identité stable trouvée. Définissez BUTTERFLY_SIGN_IDENTITY." >&2
    exit 1
  fi
fi
# --options runtime : Hardened Runtime, bloque l'injection de dylib dans un
# process qui détient des permissions sensibles (écran, accessibilité).
signed=0
for _ in 1 2 3; do
  xattr -cr "$APP"
  xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
  xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
  SIGN_ARGS=(--force --options runtime --sign "$IDENTITY")
  if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
    SIGN_ARGS+=(--timestamp)
  fi
  codesign --remove-signature "$APP/Contents/MacOS/Butterfly" 2>/dev/null || true
  if codesign "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" "$APP/Contents/MacOS/Butterfly" && \
     codesign "${SIGN_ARGS[@]}" "$APP"; then
    signed=1
    break
  fi
done
[[ "$signed" == 1 ]] || { echo "Signature impossible après 3 essais" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
echo "OK → $APP (signé : $IDENTITY, hardened runtime)"
