import Foundation

enum L10n {
    static let isFrench = Locale.preferredLanguages.first?.lowercased().hasPrefix("fr") ?? false

    private static let fr: [String: String] = [
        "hint.select": "Glisse sur le texte à corriger",
        "hint.esc": "esc",
        "drag.release": "Relâche pour analyser",
        "panel.detected": "Texte détecté",
        "panel.correction": "Correction",
        "panel.translation": "Traduction",
        "panel.copy": "Copier",
        "panel.copied": "Copié",
        "panel.reading": "Lecture du texte…",
        "panel.thinking": "Le papillon réfléchit…",
        "panel.noText": "Aucun texte détecté dans la zone sélectionnée.",
        "panel.error": "Le moteur IA n'a pas répondu.",
        "panel.engineMissing": "Aucun moteur IA disponible. Lance Ollama ou active Apple Intelligence.",
        "menu.capture": "Corriger à l'écran",
        "menu.engine": "Moteur IA",
        "menu.engine.auto": "Automatique",
        "menu.engine.ollama": "Qwen3 4B (Ollama, open source)",
        "menu.engine.apple": "Apple Intelligence",
        "menu.about": "À propos de Butterfly",
        "menu.quit": "Quitter Butterfly",
        "alert.screen.title": "Butterfly a besoin de voir l'écran",
        "alert.screen.message": "Pour lire le texte sous la loupe, autorise Butterfly dans Réglages Système → Confidentialité et sécurité → Enregistrement de l'écran, puis relance le raccourci ⌥⌘B.",
        "alert.screen.open": "Ouvrir les Réglages",
        "alert.screen.later": "Plus tard",
    ]

    private static let en: [String: String] = [
        "hint.select": "Drag over the text to fix",
        "hint.esc": "esc",
        "drag.release": "Release to analyze",
        "panel.detected": "Detected text",
        "panel.correction": "Correction",
        "panel.translation": "Translation",
        "panel.copy": "Copy",
        "panel.copied": "Copied",
        "panel.reading": "Reading text…",
        "panel.thinking": "The butterfly is thinking…",
        "panel.noText": "No text detected in the selected area.",
        "panel.error": "The AI engine did not respond.",
        "panel.engineMissing": "No AI engine available. Start Ollama or enable Apple Intelligence.",
        "menu.capture": "Fix on screen",
        "menu.engine": "AI engine",
        "menu.engine.auto": "Automatic",
        "menu.engine.ollama": "Qwen3 4B (Ollama, open source)",
        "menu.engine.apple": "Apple Intelligence",
        "menu.about": "About Butterfly",
        "menu.quit": "Quit Butterfly",
        "alert.screen.title": "Butterfly needs to see your screen",
        "alert.screen.message": "To read the text under the loupe, allow Butterfly in System Settings → Privacy & Security → Screen Recording, then press ⌥⌘B again.",
        "alert.screen.open": "Open Settings",
        "alert.screen.later": "Later",
    ]

    static func t(_ key: String) -> String {
        (isFrench ? fr : en)[key] ?? en[key] ?? key
    }

    /// Nom localisé d'une langue cible pour l'UI (ex. "en" → "Anglais")
    static func languageName(_ code: String) -> String {
        let locale = Locale(identifier: isFrench ? "fr" : "en")
        let name = locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).capitalized + name.dropFirst()
    }
}
