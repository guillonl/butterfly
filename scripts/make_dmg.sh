#!/bin/zsh
# Construit le DMG d'installation drag-and-drop de Butterfly :
# une fenêtre Finder stylée avec l'app à gauche, un alias /Applications à
# droite, et un fond avec une flèche. Consomme le bundle produit par
# scripts/build.sh et écrit dist/Butterfly-<version>.dmg.
#
#   bash scripts/make_dmg.sh
#
# Prérequis : create-dmg (brew install create-dmg).
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
BUILD="${BUTTERFLY_BUILD_DIR:-/private/tmp/butterfly-release-build}"
APP="$BUILD/Butterfly.app"
VOLNAME="Butterfly"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
DMG="dist/Butterfly-${VERSION}.dmg"

# 0. Pré-requis.
if ! command -v create-dmg >/dev/null; then
  echo "create-dmg manquant. Installe-le : brew install create-dmg" >&2
  exit 1
fi

# 1. Rebuilder systématiquement l'app dans un dossier local neutre. Le dépôt
#    peut vivre dans un dossier synchronisé, mais jamais le bundle à signer.
env BUTTERFLY_BUILD_DIR="$BUILD" bash scripts/build.sh

# 2. Tout le travail se fait dans un dossier temporaire local pour éviter les
#    attributs Finder/iCloud qui invalident une signature.
WORK="$(mktemp -d -t butterfly-dmg)"
trap 'rm -rf "$WORK"' EXIT
STAGING="$WORK/staging"
BG_TIFF="$WORK/dmg-background.tiff"
WORK_DMG="$WORK/Butterfly-${VERSION}.dmg"

# 3. Fond Retina : combine @1x et @2x en un TIFF multi-résolution.
[ -f assets/dmg-background.png ] || swift scripts/make_dmg_background.swift
tiffutil -cathidpicheck assets/dmg-background.png assets/dmg-background@2x.png -out "$BG_TIFF" >/dev/null

# 4. Staging propre, débarrassé des xattr Dropbox/quarantine/FinderInfo qui
#    cassent le montage ou polluent le layout du DMG.
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/Butterfly.app"
xattr -cr "$STAGING/Butterfly.app"

# 4b. Détache un éventuel volume « Butterfly » resté monté d'une exécution
#     précédente interrompue : sinon create-dmg ne peut pas recréer un volume
#     du même nom et échoue avec « hdiutil: create failed - Resource busy ».
while [ -d "/Volumes/$VOLNAME" ]; do
  hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || break
done

# 5. Construire le DMG. create-dmg retourne 2 (succès avec avertissement)
#    quand l'app n'est pas signée Developer ID : c'est notre cas tant qu'on
#    n'est pas notarisé, on ne traite donc en échec qu'un code > 2.
set +e
create-dmg \
  --volname "$VOLNAME" \
  --volicon "assets/AppIcon.icns" \
  --background "$BG_TIFF" \
  --window-pos 200 120 \
  --window-size 540 380 \
  --icon-size 110 \
  --icon "Butterfly.app" 140 188 \
  --hide-extension "Butterfly.app" \
  --app-drop-link 400 188 \
  --no-internet-enable \
  "$WORK_DMG" \
  "$STAGING"
RC=$?
set -e
if [ "$RC" -gt 2 ]; then
  echo "create-dmg a échoué (code $RC)" >&2
  exit "$RC"
fi

# 6. Signer le DMG avec la même identité que l'app.
IDENTITY="${BUTTERFLY_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN_ARGS+=(--timestamp); fi
codesign "${SIGN_ARGS[@]}" "$WORK_DMG"

# 7. Notariser et agrafer quand un profil notarytool est fourni. Sans profil,
#    le DMG local reste valide mais ne doit pas être présenté comme publié.
if [[ -n "${BUTTERFLY_NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
  xcrun notarytool submit "$WORK_DMG" \
    --keychain-profile "$BUTTERFLY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$WORK_DMG"
  xcrun stapler validate "$WORK_DMG"
fi

# 8. Déposer le .dmg fini dans dist/ et sur le Bureau, prêt à envoyer.
mkdir -p dist
rm -f "$DMG"
cp "$WORK_DMG" "$DMG"
DESKTOP_DMG="/Users/leoguillon/Desktop/Butterfly-${VERSION}.dmg"
cp "$WORK_DMG" "$DESKTOP_DMG"
echo "OK → $DMG"
echo "   → $DESKTOP_DMG (copie prête à envoyer, signée : $IDENTITY)"
