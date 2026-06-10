# Butterfly 🦋

Loupe Liquid Glass pour macOS Tahoe (26) : un raccourci, une zone de texte
sélectionnée à l'écran, et Butterfly corrige les fautes et traduit, en local,
gratuitement.

## Utilisation

1. **⌥⌘B** (Option + Cmd + B) : l'écran gèle, une loupe en verre suit le curseur.
2. **Clique-glisse** sur le texte à analyser (Échap pour annuler).
3. Le panneau en verre affiche : texte détecté → correction → traduction
   (langue cible changeable dans le panneau, anglais par défaut).
4. Boutons copier sur chaque résultat.

L'app vit dans la barre de menus (icône papillon). Si Bartender est actif,
l'icône peut être rangée dans son overflow.

## Moteurs IA (100 % locaux, gratuits)

| Moteur | Rôle | Notes |
|---|---|---|
| Ollama + qwen3:4b | principal | open source (Apache 2.0), `/no_think` injecté |
| Apple Intelligence | secours | FoundationModels on-device |

Sélection auto par défaut (menu barre de menus → AI engine). Butterfly démarre
le serveur Ollama lui-même si nécessaire. Si le tag `qwen3:4b-instruct`
(non-thinking, préféré) est installé un jour via `ollama pull qwen3:4b-instruct`,
l'app l'utilisera automatiquement.

## Permissions

**Enregistrement de l'écran** (obligatoire pour lire le texte sous la loupe) :
Réglages Système → Confidentialité et sécurité → Enregistrement de l'écran →
activer Butterfly, puis laisser macOS relancer l'app. Le raccourci ⌥⌘B
n'utilise pas l'API d'accessibilité (hotkey Carbon), aucune autre permission.

## Dev

```bash
swift build -c release          # build
bash scripts/build.sh           # build + bundle dist/Butterfly.app signé
cp -R dist/Butterfly.app /Applications/   # déploiement

# Modes de test (binaire direct)
./.build/release/Butterfly --selftest      # moteur IA bout en bout (stdout)
./.build/release/Butterfly --demo          # panneau résultat avec données fictives
./.build/release/Butterfly --demo-overlay  # ouvre l'overlay loupe au lancement
BUTTERFLY_DEBUG=1 ...                      # logs de détection Ollama

swift scripts/make_icon.swift              # regénérer l'icône papillon
```

Architecture : `HotKeyManager` (Carbon) → `ScreenCaptureService`
(ScreenCaptureKit, écran gelé) → `OverlayController/View` (loupe SwiftUI,
sélection) → `OCRService` (Vision) → `TextEngine` (Ollama/Apple) →
`ResultPanelController/View` (panneau `glassEffect`).

Piège connu : ne jamais envoyer `"think": false` à l'API chat d'Ollama avec le
runner chatml de l'app macOS, le raisonnement fuit dans `content`. Le soft
switch `/no_think` + retry sur réponse vide est la combinaison fiable.
