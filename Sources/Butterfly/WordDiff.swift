import Foundation

/// Diff mot à mot entre le texte détecté et le texte corrigé, pour l'affichage
/// « faute barrée / correction en vert » de la fenêtre principale.
///
/// Fonction pure (LCS sur les tokens), testable via `--test-diff` : même
/// pattern que `resizedFrame(...)` (logique extraite, pas de drag synthétique).
enum WordDiff {
    enum Segment: Equatable {
        /// Mot identique des deux côtés.
        case same(String)
        /// Mot du texte original absent du corrigé (faute).
        case removed(String)
        /// Mot du corrigé absent de l'original (correction).
        case added(String)
    }

    /// Découpe en mots sur espaces et retours ligne (même règle que
    /// `TappableText.tokens` pour que les index restent comparables).
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    /// Compare deux textes token par token. La ponctuation attachée compte
    /// dans le token (« des » ≠ « dès, ») : c'est voulu, une virgule ajoutée
    /// est une correction à montrer.
    static func diff(original: String, corrected: String) -> [Segment] {
        let a = tokens(original)
        let b = tokens(corrected)
        guard !a.isEmpty else { return b.map { .added($0) } }
        guard !b.isEmpty else { return a.map { .removed($0) } }

        // Table LCS classique (textes courts : < 500 tokens, O(n·m) suffit).
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        // Backtrack : en cas d'égalité on émet la suppression avant l'ajout,
        // pour lire « faute barrée puis correction » dans cet ordre.
        var segments: [Segment] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                segments.append(.same(a[i]))
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                segments.append(.removed(a[i]))
                i += 1
            } else {
                segments.append(.added(b[j]))
                j += 1
            }
        }
        while i < a.count { segments.append(.removed(a[i])); i += 1 }
        while j < b.count { segments.append(.added(b[j])); j += 1 }
        return segments
    }

    /// Nombre de « fautes » à afficher : groupes contigus de tokens modifiés
    /// (une substitution removed+added = 1 faute, pas 2).
    static func faultCount(original: String, corrected: String) -> Int {
        var count = 0
        var inChange = false
        for segment in diff(original: original, corrected: corrected) {
            switch segment {
            case .same:
                inChange = false
            case .removed, .added:
                if !inChange { count += 1 }
                inChange = true
            }
        }
        return count
    }
}
