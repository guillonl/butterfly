import Foundation

/// Règle de vocabulaire apprise des retouches : « entendu → écrit ».
struct VocabRule: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        /// Motif répété détecté, en attente de validation par l'utilisateur.
        case proposed
        /// Validée : injectée dans les prompts de correction des dictées.
        case learned
    }

    let id: UUID
    var heard: String
    var written: String
    var status: Status
    /// Nombre de retouches identiques observées.
    var timesObserved: Int
    /// Nombre d'applications automatiques depuis la validation.
    var timesApplied: Int
    /// Apps où la retouche a été vue (« Mail », « Slack »…).
    var apps: [String]
    var date: Date

    init(
        id: UUID = UUID(),
        heard: String,
        written: String,
        status: Status = .proposed,
        timesObserved: Int = 1,
        timesApplied: Int = 0,
        apps: [String] = [],
        date: Date = Date()
    ) {
        self.id = id
        self.heard = heard
        self.written = written
        self.status = status
        self.timesObserved = timesObserved
        self.timesApplied = timesApplied
        self.apps = apps
        self.date = date
    }
}

/// Règle de style déduite des retouches (hésitations, tutoiement…),
/// activable/désactivable. `promptFragment` est la consigne injectée
/// dans les instructions du moteur quand la règle est active.
struct StyleRule: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var promptFragment: String
    var enabled: Bool

    init(id: UUID = UUID(), label: String, promptFragment: String, enabled: Bool = true) {
        self.id = id
        self.label = label
        self.promptFragment = promptFragment
        self.enabled = enabled
    }
}

/// Profil de langage : ce que Butterfly a appris de l'utilisateur.
/// Persisté dans UserDefaults, strictement local (même posture que
/// l'historique). La boucle d'observation post-insertion alimentera
/// `observeRetouche(...)` ; la fenêtre principale gère la validation.
@MainActor
final class LanguageProfileStore: ObservableObject {
    static let shared = LanguageProfileStore()

    @Published private(set) var vocab: [VocabRule] = []
    @Published private(set) var style: [StyleRule] = []
    @Published var loopEnabled: Bool {
        didSet { UserDefaults.standard.set(loopEnabled, forKey: Self.loopKey) }
    }

    private static let vocabKey = "profile.vocab"
    private static let styleKey = "profile.style"
    private static let loopKey = "profile.loopEnabled"
    /// Retouches identiques requises avant de proposer une règle.
    static let proposalThreshold = 3

    init() {
        loopEnabled = UserDefaults.standard.object(forKey: Self.loopKey) as? Bool ?? true
        load()
        if style.isEmpty {
            style = Self.defaultStyleRules()
            saveStyle()
        }
    }

    /// Règles de style par défaut : le comportement actuel du moteur,
    /// rendu visible et désactivable.
    static func defaultStyleRules() -> [StyleRule] {
        [
            StyleRule(
                label: L10n.t("learning.style.fillers"),
                promptFragment: "Supprime les hésitations à l'oral (euh, hum, bah) et les faux départs."
            ),
            StyleRule(
                label: L10n.t("learning.style.jargon"),
                promptFragment: "Conserve tels quels les anglicismes de métier (sprint, mockup, onboarding, design system)."
            ),
        ]
    }

    // MARK: - Boucle d'observation (appelée par le watcher post-insertion)

    /// Enregistre une retouche « heard → written » observée dans `app`.
    /// Au bout de `proposalThreshold` observations identiques, la règle
    /// passe (ou reste) en `proposed`, à valider dans la fenêtre.
    func observeRetouche(heard: String, written: String, app: String?) {
        let heardKey = heard.lowercased()
        if let index = vocab.firstIndex(where: { $0.heard.lowercased() == heardKey && $0.written == written }) {
            vocab[index].timesObserved += 1
            vocab[index].date = Date()
            if let app, !vocab[index].apps.contains(app) {
                vocab[index].apps.append(app)
            }
        } else {
            vocab.insert(
                VocabRule(heard: heard, written: written, apps: app.map { [$0] } ?? []),
                at: 0
            )
        }
        saveVocab()
    }

    /// Règles prêtes à être proposées (≥ seuil, pas encore validées).
    var pendingRules: [VocabRule] {
        vocab.filter { $0.status == .proposed && $0.timesObserved >= Self.proposalThreshold }
    }

    // MARK: - Actions de la fenêtre principale

    func validate(_ id: UUID) {
        guard let index = vocab.firstIndex(where: { $0.id == id }) else { return }
        vocab[index].status = .learned
        saveVocab()
    }

    func remove(_ id: UUID) {
        vocab.removeAll { $0.id == id }
        saveVocab()
    }

    func addManualRule(heard: String, written: String) {
        vocab.insert(
            VocabRule(heard: heard, written: written, status: .learned, timesObserved: 0),
            at: 0
        )
        saveVocab()
    }

    func recordApplication(_ id: UUID) {
        guard let index = vocab.firstIndex(where: { $0.id == id }) else { return }
        vocab[index].timesApplied += 1
        saveVocab()
    }

    func toggleStyle(_ id: UUID) {
        guard let index = style.firstIndex(where: { $0.id == id }) else { return }
        style[index].enabled.toggle()
        saveStyle()
    }

    // MARK: - Injection dans les prompts (dictée et correction)

    /// Fragment d'instructions à ajouter aux prompts du moteur : vocabulaire
    /// validé + règles de style actives. Vide si la boucle est coupée.
    func promptFragment() -> String {
        guard loopEnabled else { return "" }
        var lines: [String] = []
        let learned = vocab.filter { $0.status == .learned }
        if !learned.isEmpty {
            let pairs = learned.map { "« \($0.heard) » s'écrit « \($0.written) »" }
            lines.append("Vocabulaire de l'utilisateur : " + pairs.joined(separator: " ; ") + ".")
        }
        lines.append(contentsOf: style.filter(\.enabled).map(\.promptFragment))
        return lines.joined(separator: "\n")
    }

    /// Nombre total de retouches observées (pied de page de la vue).
    var totalObservations: Int {
        vocab.reduce(0) { $0 + $1.timesObserved }
    }

    // MARK: - Persistance

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.vocabKey),
           let decoded = try? JSONDecoder().decode([VocabRule].self, from: data) {
            vocab = decoded
        }
        if let data = defaults.data(forKey: Self.styleKey),
           let decoded = try? JSONDecoder().decode([StyleRule].self, from: data) {
            style = decoded
        }
    }

    private func saveVocab() {
        guard !demoMode else { return }
        guard let data = try? JSONEncoder().encode(vocab) else { return }
        UserDefaults.standard.set(data, forKey: Self.vocabKey)
    }

    private func saveStyle() {
        guard !demoMode else { return }
        guard let data = try? JSONEncoder().encode(style) else { return }
        UserDefaults.standard.set(data, forKey: Self.styleKey)
    }

    /// Fixtures pour `--demo-main` (jamais persistées : on remplace en mémoire
    /// sans toucher UserDefaults grâce au flag).
    func loadDemoFixtures() {
        demoMode = true
        vocab = [
            VocabRule(heard: "bécé", written: "BYC", status: .proposed, timesObserved: 3, apps: ["Mail", "Slack"]),
            VocabRule(heard: "wisper flow", written: "Wispr Flow", status: .proposed, timesObserved: 2, apps: ["Notes"]),
            VocabRule(heard: "energir", written: "Énergir", status: .learned, timesObserved: 4, timesApplied: 11),
            VocabRule(heard: "design système", written: "design system", status: .learned, timesObserved: 3, timesApplied: 6),
        ]
    }

    private var demoMode = false
}
