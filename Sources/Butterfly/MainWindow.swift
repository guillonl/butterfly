import AppKit
import SwiftUI

/// Sections de la sidebar de la fenêtre principale.
enum LibrarySection: String, CaseIterable, Identifiable {
    case all
    case corrections
    case translations
    case dictations
    case learning

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all: return "main.all"
        case .corrections: return "main.corrections"
        case .translations: return "main.translations"
        case .dictations: return "main.dictations"
        case .learning: return "main.learning"
        }
    }

    /// SF Symbols, trait cohérent (esprit Heroicons : fin, géométrique).
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .corrections: return "pencil.line"
        case .translations: return "globe"
        case .dictations: return "microphone"
        case .learning: return "sparkles"
        }
    }

    /// Vrai pour les sections qui filtrent la liste d'entrées.
    var isLibraryFilter: Bool { self != .learning }
}

/// État partagé de la fenêtre principale.
@MainActor
final class MainViewModel: ObservableObject {
    @Published var section: LibrarySection = .all
    @Published var searchText = ""
    @Published var selectedEntryID: UUID?
    /// Clic sur une correction (mot vert) : (mot nettoyé, langue source).
    /// Branché par l'AppDelegate sur la bulle de synonymes.
    var onWordTap: ((String, String) -> Void)?

    let history: HistoryStore
    let profile: LanguageProfileStore

    init(history: HistoryStore? = nil, profile: LanguageProfileStore? = nil) {
        self.history = history ?? .shared
        self.profile = profile ?? .shared
    }

    func count(for section: LibrarySection) -> Int {
        switch section {
        case .all: return history.entries.count
        case .corrections: return history.entries.filter { $0.kind == .correction }.count
        case .translations: return history.entries.filter { $0.translated != nil }.count
        case .dictations: return history.entries.filter { $0.kind == .dictation }.count
        case .learning: return profile.pendingRules.count
        }
    }

    var filteredEntries: [HistoryEntry] {
        var entries = history.entries
        switch section {
        case .all, .learning: break
        case .corrections: entries = entries.filter { $0.kind == .correction }
        case .translations: entries = entries.filter { $0.translated != nil }
        case .dictations: entries = entries.filter { $0.kind == .dictation }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = [entry.original, entry.corrected, entry.translated, entry.rawTranscript]
                .compactMap { $0 }
                .joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedEntry: HistoryEntry? {
        guard let id = selectedEntryID else { return filteredEntries.first }
        return history.entries.first { $0.id == id }
    }

    /// Groupes datés de la liste (Aujourd'hui, Hier, Cette semaine, Plus ancien).
    var groupedEntries: [(key: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var groups: [(key: String, entries: [HistoryEntry])] = []
        for entry in filteredEntries {
            let key: String
            if calendar.isDateInToday(entry.date) {
                key = L10n.t("main.today")
            } else if calendar.isDateInYesterday(entry.date) {
                key = L10n.t("main.yesterday")
            } else if let week = calendar.dateInterval(of: .weekOfYear, for: Date()), week.contains(entry.date) {
                key = L10n.t("main.thisWeek")
            } else {
                key = L10n.t("main.earlier")
            }
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].entries.append(entry)
            } else {
                groups.append((key, [entry]))
            }
        }
        return groups
    }
}

// MARK: - Contrôleur de fenêtre

/// Fenêtre principale « Studio » : titlebar fondue dans la sidebar,
/// apparence sombre assumée (design validé), app régulière tant qu'elle
/// est ouverte (Dock/⌘⇥), accessoire sinon.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let model = MainViewModel()
    /// Ouvre les Réglages existants (panneau raccourcis/mode).
    var onOpenSettings: (() -> Void)?

    func show() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = "Butterfly"
        // Direction « Studio sombre » validée : la fenêtre est sombre quelle
        // que soit l'apparence système (comme Linear).
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 920, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let root = MainView(
            model: model,
            onOpenSettings: { [weak self] in self?.onOpenSettings?() }
        )
        window.contentViewController = NSHostingController(rootView: root)
        // Piège connu : l'assignation du contentViewController réinitialise
        // la frame → réimposer la taille puis recentrer.
        window.setContentSize(NSSize(width: 1040, height: 640))
        window.center()

        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        // Redevenir une app de barre de menus discrète.
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Vue racine

struct MainView: View {
    @ObservedObject var model: MainViewModel
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, onOpenSettings: onOpenSettings)
                .frame(width: 220)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            if model.section == .learning {
                LearningView(profile: model.profile)
            } else {
                EntryListView(model: model)
                    .frame(width: 300)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                DetailView(model: model)
            }
        }
        .background(Theme.surfaceDeep)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: MainViewModel
    var onOpenSettings: () -> Void
    @State private var engineLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Espace des feux tricolores (titlebar transparente).
            Spacer().frame(height: 34)

            HStack(spacing: 9) {
                ButterflyShape()
                    .fill(Theme.textPrimary)
                    .frame(width: 22, height: 22)
                Text("Butterfly")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 18)

            VStack(spacing: 3) {
                ForEach(LibrarySection.allCases) { section in
                    SidebarRow(
                        section: section,
                        selected: model.section == section,
                        count: model.count(for: section),
                        highlightCount: section == .learning
                    ) {
                        model.section = section
                        model.selectedEntryID = nil
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            EngineCard(label: engineLabel)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)

            SettingsRow(action: onOpenSettings)
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surfaceRaised)
        .task {
            if let backend = await TextEngine.shared.resolveBackend() {
                engineLabel = TextEngine.shared.label(for: backend)
            } else {
                engineLabel = L10n.t("panel.engineMissing")
            }
        }
    }
}

private struct SidebarRow: View {
    let section: LibrarySection
    let selected: Bool
    let count: Int
    /// Vrai pour Apprentissage : le compteur signale des règles à valider.
    var highlightCount = false
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? .white : Theme.textTertiary)
                Text(L10n.t(section.titleKey))
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .white : Theme.textSecondary)
                Spacer(minLength: 0)
                if count > 0 {
                    if highlightCount, !selected {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                    } else {
                        Text("\(count)")
                            .font(.system(size: 11))
                            .foregroundStyle(selected ? .white.opacity(0.75) : Theme.textQuaternary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                selected
                    ? AnyShapeStyle(Theme.accent)
                    : AnyShapeStyle(Color.white.opacity(hovered ? 0.05 : 0)),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Encart moteur en bas de sidebar : état + rappel « tout est local ».
private struct EngineCard: View {
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(label.isEmpty ? Theme.textQuaternary : Theme.ok)
                    .frame(width: 6, height: 6)
                Text(label.isEmpty ? "…" : label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Text(L10n.t("main.engineFallback"))
                .font(.system(size: 10))
                .foregroundStyle(Theme.textQuaternary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surfaceTop, in: RoundedRectangle(cornerRadius: Theme.radiusRow))
    }
}

private struct SettingsRow: View {
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                Text(L10n.t("main.settings"))
                    .font(.system(size: 12))
            }
            .foregroundStyle(hovered ? Theme.textSecondary : Theme.textTertiary)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
