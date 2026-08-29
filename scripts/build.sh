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

# Modèle Whisper embarqué (distribution clé en main : l'utilisateur ne
# télécharge rien). Source : le cache local de développement. Opt-out pour
# les itérations rapides : BUTTERFLY_SKIP_EMBED=1.
WHISPER_CACHE="$HOME/Library/Application Support/Butterfly/WhisperModels"
if [ "${BUTTERFLY_SKIP_EMBED:-0}" != "1" ]; then
  MODEL_DIR=$(find "$WHISPER_CACHE" -type d -name "*turbo*" -maxdepth 4 2>/dev/null | head -1)
  if [ -n "$MODEL_DIR" ]; then
    mkdir -p "$APP/Contents/Resources/WhisperModels"
    cp -R "$MODEL_DIR" "$APP/Contents/Resources/WhisperModels/"
    echo "Modèle Whisper embarqué : $(basename "$MODEL_DIR") ($(du -sh "$MODEL_DIR" | cut -f1))"
  else
    echo "⚠️  Pas de modèle Whisper en cache ($WHISPER_CACHE) : bundle sans modèle embarqué."
  fi
fi

# Identité stable « Butterfly Dev » si présente (les permissions TCC
# survivent alors aux rebuilds), sinon signature ad hoc.
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Butterfly Dev"; then
  IDENTITY="Butterfly Dev"
fi
# --options runtime : Hardened Runtime, bloque l'injection de dylib dans un
# process qui détient des permissions sensibles (écran, accessibilité).
codesign --force --options runtime --entitlements Butterfly.entitlements --sign "$IDENTITY" "$APP"
echo "OK → $APP (signé : $IDENTITY, hardened runtime)"
