#!/bin/zsh
# Construit le DMG d'installation drag-and-drop de Butterfly :
# une fenêtre Finder stylée avec l'app à gauche, un alias /Applications à
# droite, et un fond avec une flèche. Consomme dist/Butterfly.app (produit
# par scripts/build.sh) et écrit dist/Butterfly-<version>.dmg.
#
#   bash scripts/make_dmg.sh
#
# Prérequis : create-dmg (brew install create-dmg).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Butterfly.app"
VOLNAME="Butterfly"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
DMG="dist/Butterfly-${VERSION}.dmg"

# 0. Pré-requis.
if ! command -v create-dmg >/dev/null; then
  echo "create-dmg manquant. Installe-le : brew install create-dmg" >&2
  exit 1
fi

# 1. S'assurer que l'app existe (sinon la builder + signer).
[ -d "$APP" ] || bash scripts/build.sh

# 2. Tout le travail se fait dans un dossier temporaire LOCAL (hors Dropbox).
#    Le repo vit sous ~/Library/CloudStorage/Dropbox : le file provider y
#    intercepte les I/O et fait échouer `hdiutil create` (« Resource busy »),
#    car hdiutil attache un vrai device disque. On construit donc hors-cloud
#    puis on copie le .dmg fini dans dist/.
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

# 6. Signer le DMG avec la même identité locale que l'app (cohérence ; cela ne
#    le notarise pas et ne lève pas l'écran Gatekeeper, cf. README).
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Butterfly Dev"; then
  IDENTITY="Butterfly Dev"
fi
codesign --force --sign "$IDENTITY" "$WORK_DMG"

# 7. Déposer le .dmg fini dans dist/ (copie d'un fichier déjà formé : Dropbox
#    n'interfère plus, contrairement à hdiutil qui attachait un device) et sur
#    le Bureau, prêt à envoyer.
mkdir -p dist
rm -f "$DMG"
cp "$WORK_DMG" "$DMG"
DESKTOP_DMG="$HOME/Desktop/Butterfly-${VERSION}.dmg"
cp "$WORK_DMG" "$DESKTOP_DMG"
echo "OK → $DMG"
echo "   → $DESKTOP_DMG (copie prête à envoyer, signée : $IDENTITY)"
