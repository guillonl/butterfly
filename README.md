<p align="center">
  <img src="assets/icon-preview.png" width="128" alt="Butterfly" />
</p>

<h1 align="center">Butterfly</h1>

<p align="center">
  <strong>Corrige et traduis n'importe quel texte sur ton Mac.</strong><br/>
  Sélectionne une zone à l'écran ou du texte dans une app, Butterfly s'occupe du reste.<br/>
  <strong>Local, privé et toujours accessible depuis la barre des menus.</strong>
</p>

<p align="center">
  <img src="assets/screenshot-panel.png" width="440" alt="Panneau de résultat Butterfly" />
</p>

## En trois gestes

1. **Capture.** Appuie sur `⌥⌘B` et encadre du texte à l'écran, ou sélectionne du texte puis appuie sur `⌃⌘B`.
2. **Vérifie.** Butterfly sépare clairement le texte détecté, la correction et la traduction.
3. **Réutilise.** Copie un résultat, change la langue ou clique un mot pour obtenir une autre formulation.

Tout se passe localement avec Apple Intelligence, ou avec Ollama sur les Mac non compatibles. Aucune clé API et aucun compte ne sont nécessaires.

## Deux façons de récupérer le texte

Deux façons d'attraper du texte, au choix :

1. **N'importe quoi à l'écran (loupe, ⌥⌘B).** Appuie sur **⌥⌘B** : l'écran gèle et une loupe en verre suit ton curseur. Clique-glisse sur le texte à traiter, où qu'il soit (un mail, un Slack, une image, un PDF, une vidéo en pause) : c'est de la reconnaissance visuelle, ça marche même là où le texte n'est pas sélectionnable. Échap pour annuler.
2. **Du texte déjà sélectionnable (⌃⌘B).** Sélectionne du texte dans n'importe quelle app, puis **⌃⌘B**. Pas de loupe ni d'OCR : Butterfly lit directement ta sélection.

Dans les deux cas, un panneau compact apparaît avec trois cartes distinctes : le texte détecté, sa **correction** et sa **traduction**.

**Tu choisis ce que Butterfly fait** (clic droit sur l'icône → Réglages → Mode de traitement) :

- **Corriger et traduire** (par défaut)
- **Corriger seulement**, plus rapide, sans traduction
- **Traduire seulement**, traduction directe de l'original

Dans le panneau :

- La correction ne touche qu'aux fautes avérées ; si le texte est déjà parfait, un tag **« Aucune correction »** l'indique.
- **Clique un mot** dans la correction ou la traduction : une bulle propose des synonymes et tournures plus courtes (clic sur une alternative = remplacement, le bouton ↻ en relance d'autres).
- Le bouton **« Régénérer une autre proposition »** en bas reformule la correction (même sens, autre tournure), autant de fois que tu veux.
- **Panneau redimensionnable** par les bords et les coins, à la taille que tu veux : Butterfly la mémorise pour la prochaine fois.
- Un bouton copier sur chaque résultat, un « Voir plus » sur les textes longs, et le panneau scrolle au lieu de déborder de l'écran.

**Langues : détection automatique + presets.** La langue du texte est détectée toute seule. Chaque langue source mémorise sa cible : par défaut français → anglais et anglais → français ; si tu choisis « Allemand » dans le picker pour un texte français, tous les prochains textes français seront traduits en allemand, sans toucher au preset des autres langues.

Un clic sur l'icône Butterfly de la barre de menus ouvre l'**historique** de tes 50 dernières corrections. Chaque entrée permet de copier directement la correction ou la traduction. Un clic droit ouvre le menu des actions, du moteur IA et des réglages.

<p align="center">
  <img src="assets/screenshot-history.png" width="380" alt="Historique Butterfly" />
</p>

## Installation

### Prérequis

- macOS 26 ou plus récent
- Apple Intelligence activé, ou Ollama comme moteur local de secours
- deux autorisations macOS guidées au premier lancement : Enregistrement de l'écran et Accessibilité

### 1. Le plus simple : le DMG

1. Télécharge le dernier **`Butterfly-<version>.dmg`**, ouvre-le, puis glisse **Butterfly** dans **Applications**.
2. Au premier lancement, macOS bloque les apps qui ne viennent pas de l'App Store. C'est normal :
   - Double-clique **Butterfly** → un message apparaît → clique **« OK »** (pas « Mettre à la corbeille »).
   - Va dans **Réglages Système → Confidentialité et sécurité**, descends jusqu'à la section **Sécurité**, et clique **« Ouvrir quand même »** à côté de Butterfly, puis confirme.
   - C'est à faire **une seule fois**. (Sur macOS 15+ le clic droit → Ouvrir ne suffit plus, il faut bien passer par les Réglages.)
3. Ouvre Butterfly depuis **Applications**. Le guide de démarrage vérifie le moteur local et affiche un bouton pour chaque autorisation manquante.

<p align="center">
  <img src="assets/screenshot-onboarding.png" width="460" alt="Guide de démarrage Butterfly avec les trois prérequis" />
</p>

### 2. Le moteur d'intelligence

Butterfly utilise en priorité **Apple Intelligence**, l'IA intégrée à macOS : **rien à installer, rien à télécharger**, tout reste sur ton Mac. Il suffit qu'Apple Intelligence soit activé (Réglages Système → **Apple Intelligence et Siri**) — le guide de démarrage propose un bouton pour le faire.

> **Option avancée — Ollama.** Sur un Mac qui ne prend pas en charge Apple Intelligence, ou si tu préfères un modèle open source (Qwen3 4B), installe Ollama et Butterfly l'utilisera automatiquement :
> ```bash
> brew install --cask ollama-app
> ollama pull hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M
> ```
> Pas besoin de lancer Ollama toi-même, l'app démarre le serveur en arrière-plan quand il le faut.

### 3. Les autorisations

Au premier usage, macOS demande deux autorisations (le guide de démarrage propose un bouton pour chacune) :

- **Enregistrement de l'écran** — pour lire le texte sous la loupe (⌥⌘B). macOS proposera **« Quitter et rouvrir »** : clique ce bouton, c'est obligatoire.
- **Accessibilité** — pour corriger le texte sélectionné dans une autre app (⌃⌘B).

## Installer depuis les sources

```bash
git clone https://github.com/guillonl/butterfly.git
cd butterfly
bash scripts/build.sh                       # → dist/Butterfly.app (signé localement)
ditto dist/Butterfly.app /Applications/Butterfly.app
bash scripts/make_dmg.sh                     # → dist/Butterfly-<version>.dmg (drag-and-drop)
```

> **Signature & permissions.** Sans variable d'environnement, le build local est signé ad hoc. Pour distribuer, fournis `BUTTERFLY_SIGN_IDENTITY` et `BUTTERFLY_NOTARY_PROFILE` : le script signe en Developer ID, notarise et agrafe le DMG. Les builds se font dans `/private/tmp` afin que les métadonnées iCloud ne cassent pas la signature.

Butterfly 1.9 consolide automatiquement l'historique et les réglages d'une ancienne installation `Butterfly Beta` dans l'app stable, sans écraser les préférences déjà présentes.

## Raccourcis

| Action | Geste |
|---|---|
| Corriger un texte à l'écran (loupe) | ⌥⌘B puis clique-glisse |
| Corriger le texte sélectionné | sélectionne du texte dans n'importe quelle app, puis ⌃⌘B |
| Synonymes / autres tournures d'un mot | clique un mot dans le panneau |
| Redimensionner le panneau | glisse un bord ou un coin |
| Personnaliser les deux raccourcis | clic droit sur l'icône → Réglages… |
| Annuler la sélection | Échap |
| Historique | Clic sur l'icône papillon |
| Menu (moteur IA, réglages, quitter) | Clic droit sur l'icône |
| Fermer un panneau | Échap ou clic ailleurs |

Le raccourci « texte sélectionné » saute la loupe et l'OCR : il lit directement la sélection de l'app active (via l'API Accessibilité, avec repli sur une copie silencieuse qui restaure ton presse-papiers). Il demande une permission supplémentaire au premier usage : Réglages Système → Confidentialité et sécurité → **Accessibilité** → activer Butterfly.

### Réglages sobres et cohérents

Clic droit sur l'icône papillon → **Réglages…** :

- **Raccourcis personnalisables** : clique un raccourci puis tape la nouvelle combinaison (au moins ⌘, ⌥ ou ⌃).
- **Mode de traitement** : choisis entre **corriger et traduire**, **corriger seulement** (plus rapide, pas d'appel de traduction) ou **traduire seulement** (traduction directe de l'original, sans passer par la correction).
- **Ouvrir à la connexion** : garde Butterfly disponible dans la barre de menus dès l'ouverture de session.
- **Autorisations** : vérifie l'état d'Enregistrement de l'écran et d'Accessibilité, puis rouvre le guide si une étape manque.

<p align="center">
  <img src="assets/screenshot-settings.png" width="400" alt="Réglages des raccourcis" />
</p>

## Si quelque chose ne fonctionne pas

- **La loupe ne voit rien** : ouvre Réglages → Autorisations et vérifie Enregistrement de l'écran. macOS peut demander de quitter et rouvrir Butterfly.
- **Le raccourci de sélection ne trouve aucun texte** : autorise Butterfly dans Accessibilité, puis réessaie dans l'app source.
- **Aucun moteur IA disponible** : active Apple Intelligence ou installe Ollama avec la commande indiquée plus haut.
- **Un raccourci entre en conflit** : ouvre Réglages, clique la combinaison concernée et tape un nouveau raccourci avec `⌘`, `⌥` ou `⌃`.

## Vie privée et sécurité

Tout tourne sur ta machine : la capture d'écran, l'OCR (Vision d'Apple), la correction et la traduction (modèle local via Ollama sur 127.0.0.1 ou Apple Intelligence on-device). Aucune requête réseau vers un service externe, aucune télémétrie, aucune clé API.

À savoir :

- Les captures d'écran restent en mémoire le temps de l'analyse, elles ne sont jamais écrites sur disque.
- L'**historique** (50 dernières corrections) est stocké en clair dans les préférences locales de ton compte ; le bouton corbeille du panneau le purge entièrement. Évite d'analyser des secrets (mots de passe…) si d'autres comptes utilisent ta machine.
- Le repli « copie silencieuse » du raccourci sélection restaure ton presse-papiers, mais un gestionnaire de presse-papiers tiers peut avoir enregistré le texte au passage.
- L'app est signée avec le Hardened Runtime activé (anti-injection de code) et le binaire ne charge aucune dépendance tierce (zéro package externe).

## Pour les devs

```bash
swift build -c release                     # build
swift test                                 # tests de migration et comportements critiques
./script/build_and_run.sh --verify          # build, lance et confirme le processus
./.build/release/Butterfly --selftest      # test du moteur IA bout en bout (FR↔EN)
./.build/release/Butterfly --demo          # panneau résultat avec données fictives
./.build/release/Butterfly --demo-overlay  # ouvre l'overlay loupe au lancement
./.build/release/Butterfly --demo-history  # ouvre l'historique avec données fictives
./.build/release/Butterfly --demo-onboarding # ouvre le guide de démarrage
./.build/release/Butterfly --test-resize   # test pur de la logique de redimensionnement (bords/coins)
./.build/release/Butterfly --test-replace  # test pur du remplacement de mot par un synonyme
swift scripts/make_icon.swift              # regénérer l'icône papillon
./scripts/make_icns.sh                     # regénérer le PNG, l'aperçu et le .icns
swift scripts/make_dmg_background.swift    # regénérer le fond du DMG
```

Architecture : `HotKeyManager` (hotkey Carbon, zéro permission) → `ScreenCaptureService` (ScreenCaptureKit, écran gelé) → `OverlayView` (loupe SwiftUI) **ou** `SelectedTextService` (API Accessibilité, raccourci sélection) → `OCRService` (Vision) → `TextEngine` (Apple Foundation Models en priorité, Ollama en secours, streaming et modes corriger/traduire) → panneaux SwiftUI pilotés par `ButterflyTokens` (`ResultView` redimensionnable, `WordBubble` pour les synonymes).

## Licence

[MIT](LICENSE) © 2026 Léo Guillon
