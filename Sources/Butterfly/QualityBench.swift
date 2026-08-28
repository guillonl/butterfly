import Foundation

/// Banc de qualité du moteur (--test-quality) : correction sur textes
/// propres, longs, scientifiques, jargon métier, anglais ; nettoyage de
/// dictée ; traduction technique. Évaluation par diff mot à mot : les
/// verdicts mesurent des critères vérifiables (corrections attendues
/// présentes, texte propre inchangé, termes techniques intacts), pas une
/// impression.
@MainActor
enum QualityBench {

    struct Case {
        let name: String
        let kind: Kind
        let source: String
        let text: String
        /// Fragments qui DOIVENT apparaître dans la sortie.
        let mustContain: [String]
        /// Fragments qui ne doivent PAS apparaître (fautes, mots interdits).
        let mustNotContain: [String]
        /// Part maximale de tokens modifiés (1.0 = pas de limite).
        let maxChangeRatio: Double

        enum Kind {
            case correction
            case dictation
            case translation(target: String)
        }
    }

    static let cases: [Case] = [
        Case(
            name: "fr · court avec fautes",
            kind: .correction, source: "fr",
            text: "Je te partage le fichier des que j'ai terminer la maquette.",
            mustContain: ["dès", "terminé"],
            mustNotContain: [],
            maxChangeRatio: 0.5
        ),
        Case(
            name: "fr · propre court (zéro changement attendu)",
            kind: .correction, source: "fr",
            text: "Nous traitons votre demande. Entre-temps, vous pouvez modifier vos comptes.",
            mustContain: ["Entre-temps"],
            mustNotContain: [],
            maxChangeRatio: 0.0
        ),
        Case(
            name: "fr · propre long (zéro changement attendu)",
            kind: .correction, source: "fr",
            text: "Bonjour Mathieu, merci pour ton retour détaillé sur la maquette. J'ai repris la hiérarchie de la page d'accueil comme convenu : le bandeau principal met désormais l'accent sur la promesse, et les témoignages remontent au-dessus de la grille tarifaire. Les contrastes ont été vérifiés sur fond sombre et sur fond clair. Si tout te convient, je prépare la passation avec l'équipe de développement dès lundi matin, et je reste disponible pour un appel rapide en fin de journée si tu préfères en discuter de vive voix.",
            mustContain: ["hiérarchie", "témoignages", "passation"],
            mustNotContain: [],
            maxChangeRatio: 0.0
        ),
        Case(
            name: "fr · long avec six fautes dispersées",
            kind: .correction, source: "fr",
            text: "Depuis la mise à jour, sa vas beaucoup mieux : les développeur ont corrigé la connection au serveur, et malgrés quelques lenteurs le matin, ont a constaté une nette amélioration. Le language utilisé dans les messages d'erreur reste toutefois trop technique pour les clients, et il faudrait le simplifier avant la prochaine version.",
            mustContain: ["ça va", "développeurs", "connexion", "malgré", "on a", "langage"],
            mustNotContain: ["sa vas", "malgrés"],
            maxChangeRatio: 0.3
        ),
        Case(
            name: "fr · scientifique (termes techniques intacts)",
            kind: .correction, source: "fr",
            text: "L'algorithme de rétropropagation calcule le gradient de la fonction de coût par dérivation en chaîne, puis met à jour les poids du réseau. Le taux d'apprentissage controle l'amplitude des mises à jour : trop élevé, la descente de gradient diverge ; trop faible, la convergence devient très lente. On observe aussi que la normalisation par lots stabilise l'entrainement des couches profondes.",
            mustContain: ["rétropropagation", "gradient", "dérivation en chaîne", "contrôle", "entraînement"],
            mustNotContain: ["controle", "entrainement"],
            maxChangeRatio: 0.15
        ),
        Case(
            name: "fr · jargon métier conservé",
            kind: .correction, source: "fr",
            text: "On fait la sprint review demain matin, j'apporte les mockups du nouveau onboarding et le design system mis à jour.",
            mustContain: ["sprint review", "mockups", "onboarding", "design system"],
            mustNotContain: [],
            maxChangeRatio: 0.15
        ),
        Case(
            name: "en · fautes classiques",
            kind: .correction, source: "en",
            text: "I had went to the store yesterday and buyed two apple for the team.",
            mustContain: ["bought", "apples"],
            mustNotContain: ["buyed", "had went"],
            maxChangeRatio: 0.5
        ),
        Case(
            name: "dictée · hésitations nettoyées",
            kind: .dictation, source: "fr",
            text: "euh donc en fait je voulais te dire que euh la maquette est prête et et je te l'envoie ce soir",
            mustContain: ["maquette", "ce soir"],
            mustNotContain: ["euh"],
            maxChangeRatio: 1.0
        ),
        Case(
            name: "traduction · texte technique fr → en",
            kind: .translation(target: "en"), source: "fr",
            text: "Le composant réutilise le jeton d'accès stocké dans le trousseau du système.",
            mustContain: [],
            mustNotContain: ["trousseau", "jeton"],
            maxChangeRatio: 1.0
        ),
    ]

    static func run() {
        Task { @MainActor in
            func log(_ message: String) {
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            guard let backend = await TextEngine.shared.resolveBackend() else {
                log("[quality] ÉCHEC : aucun moteur disponible")
                exit(1)
            }
            log("[quality] moteur : \(TextEngine.shared.label(for: backend))")
            var failures = 0
            for testCase in cases {
                let started = Date()
                let output: String
                do {
                    switch testCase.kind {
                    case .correction:
                        output = try await TextEngine.shared.correct(testCase.text, source: testCase.source, using: backend)
                    case .dictation:
                        output = try await TextEngine.shared.cleanupDictation(
                            testCase.text,
                            source: testCase.source,
                            profileFragment: LanguageProfileStore.shared.promptFragment(),
                            appName: nil,
                            using: backend
                        )
                    case .translation(let target):
                        output = try await TextEngine.shared.translate(testCase.text, from: testCase.source, to: target, using: backend)
                    }
                } catch {
                    log("[quality] ÉCHEC \(testCase.name) : erreur moteur \(error)")
                    failures += 1
                    continue
                }
                let elapsed = String(format: "%.1fs", Date().timeIntervalSince(started))

                var problems: [String] = []
                let haystack = output.lowercased()
                for fragment in testCase.mustContain where !haystack.contains(fragment.lowercased()) {
                    problems.append("manque « \(fragment) »")
                }
                for fragment in testCase.mustNotContain where haystack.contains(fragment.lowercased()) {
                    problems.append("contient encore « \(fragment) »")
                }
                if case .correction = testCase.kind {
                    let total = WordDiff.tokens(testCase.text).count
                    let changed = WordDiff.diff(original: testCase.text, corrected: output).reduce(0) {
                        if case .same = $1 { return $0 } else { return $0 + 1 }
                    }
                    let ratio = total > 0 ? Double(changed) / Double(total * 2) : 0
                    if ratio > testCase.maxChangeRatio {
                        problems.append(String(format: "trop de changements (%.0f %% > %.0f %%)", ratio * 100, testCase.maxChangeRatio * 100))
                    }
                }

                if problems.isEmpty {
                    log("[quality] OK    \(testCase.name) (\(elapsed))")
                } else {
                    failures += 1
                    log("[quality] ÉCHEC \(testCase.name) (\(elapsed)) : \(problems.joined(separator: " ; "))")
                    log("          sortie : \(output.prefix(220))")
                }
            }
            log("[quality] \(cases.count - failures)/\(cases.count) cas passés")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
