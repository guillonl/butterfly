import AppKit
import SwiftUI

/// Touche de dictée (maintenir pour parler). Modificateurs seuls,
/// identifiés par keyCode dans les flagsChanged : plus fiables qu'une
/// combinaison classique pour du push-to-talk.
enum DictationKey: String, CaseIterable, Identifiable {
    case fn
    case rightCommand
    case rightOption
    case leftControl

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        case .leftControl: return 59
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .rightCommand: return .command
        case .rightOption: return .option
        case .leftControl: return .control
        }
    }

    var label: String { L10n.t("settings.dictation.key.\(rawValue)") }

    /// Symbole court pour le HUD et les keycaps.
    var symbol: String {
        switch self {
        case .fn: return "fn"
        case .rightCommand: return "⌘"
        case .rightOption: return "⌥"
        case .leftControl: return "⌃"
        }
    }
}

/// Réglages de la dictée, persistés (UserDefaults, domaine de l'app).
enum DictationSettings {
    private static let cleanupKey = "dictationCleanup"
    private static let localeKey = "dictationLocale"
    private static let shortcutKey = "dictationShortcut"

    /// Touche à maintenir pour dicter (défaut : fn).
    static var shortcut: DictationKey {
        get { DictationKey(rawValue: UserDefaults.standard.string(forKey: shortcutKey) ?? "fn") ?? .fn }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: shortcutKey) }
    }

    /// Passe LLM de nettoyage à la volée (défaut : activée).
    static var cleanupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: cleanupKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: cleanupKey) }
    }

    /// "auto" (langue système), "fr" ou "en".
    static var localeChoice: String {
        get { UserDefaults.standard.string(forKey: localeKey) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: localeKey) }
    }

    /// Locales de la session de dictée. « Automatique » lance un duel
    /// fr + en : les deux transcrivent, la meilleure hypothèse gagne
    /// (détection de la langue PARLÉE, pas de la langue du Mac).
    static var effectiveLocales: [Locale] {
        switch localeChoice {
        case "fr": return [Locale(identifier: "fr_FR")]
        case "en": return [Locale(identifier: "en_US")]
        default:
            // La langue du système d'abord (hypothèse affichée en direct).
            return L10n.isFrench
                ? [Locale(identifier: "fr_FR"), Locale(identifier: "en_US")]
                : [Locale(identifier: "en_US"), Locale(identifier: "fr_FR")]
        }
    }
}

/// Catégories des Réglages intégrés.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case dictation
    case engine
    case about

    var id: String { rawValue }

    var titleKey: String { "settings.cat.\(rawValue)" }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .dictation: return "microphone"
        case .engine: return "cpu"
        case .about: return "info.circle"
        }
    }
}

/// Vue Réglages de la fenêtre principale : colonne de catégories +
/// panneau de rangées (titre, description, contrôle à droite).
struct SettingsHomeView: View {
    @ObservedObject var model: MainViewModel
    @State private var category: SettingsCategory = .general

    var body: some View {
        HStack(spacing: 0) {
            // Catégories : sidebar pleine (remplace celle de la bibliothèque)
            VStack(alignment: .leading, spacing: 3) {
                Spacer().frame(height: 34)
                BackToLibraryButton {
                    model.section = model.sectionBeforeSettings
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)
                Text(L10n.t("main.settings").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textQuaternary)
                    .padding(.horizontal, 12)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                ForEach(SettingsCategory.allCases) { item in
                    CategoryRow(category: item, selected: category == item) {
                        category = item
                    }
                }
                Spacer()
                Text("Butterfly \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textQuaternary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 8)
            .frame(width: 220, alignment: .leading)
            .background(Theme.surfaceRaised)

            Rectangle().fill(Theme.hairline).frame(width: 1)

            // Panneau
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t(category.titleKey))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 28)
                    .padding(.top, 48)
                    .padding(.bottom, 18)
                ScrollView {
                    VStack(spacing: 16) {
                        switch category {
                        case .general: GeneralSettings(model: model)
                        case .dictation: DictationSettingsView()
                        case .engine: EngineSettings()
                        case .about: AboutSettings()
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surfaceDeep)
        }
    }
}

/// Retour vers la bibliothèque : chevron + marque, en tête de la sidebar.
private struct BackToLibraryButton: View {
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovered ? Theme.textPrimary : Theme.textTertiary)
                ButterflyShape()
                    .fill(Theme.textPrimary)
                    .frame(width: 18, height: 18)
                Text("Butterfly")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(Color.white.opacity(hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct CategoryRow: View {
    let category: SettingsCategory
    let selected: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: category.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                Text(L10n.t(category.titleKey))
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                Color.white.opacity(selected ? 0.08 : (hovered ? 0.04 : 0)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Rangée de réglage

/// Rangée : titre + description à gauche, contrôle à droite.
private struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// Groupe de rangées dans une carte bevel, séparées par des hairlines.
private struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        StudioCard(padding: 0) {
            VStack(spacing: 0) { content }
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            .padding(.leading, 16)
    }
}

// MARK: - Général (raccourcis + actions)

private struct GeneralSettings: View {
    @ObservedObject var model: MainViewModel
    @State private var shortcuts: [HotKeyAction: Shortcut] = [
        .capture: ShortcutStore.shortcut(for: .capture),
        .selection: ShortcutStore.shortcut(for: .selection),
    ]
    @State private var recording: HotKeyAction?
    @State private var errorMessage: String?
    @State private var keyMonitor: Any?
    @State private var mode: ProcessingMode = .current

    var body: some View {
        SettingsGroup {
            SettingRow(
                title: L10n.t("settings.capture"),
                subtitle: L10n.t("settings.captureHint")
            ) {
                recorderButton(for: .capture)
            }
            SettingsDivider()
            SettingRow(
                title: L10n.t("settings.selection"),
                subtitle: L10n.t("settings.selectionHint")
            ) {
                recorderButton(for: .selection)
            }
            SettingsDivider()
            SettingRow(
                title: L10n.t("settings.mode"),
                subtitle: L10n.t("settings.modeHint")
            ) {
                Picker("", selection: $mode) {
                    ForEach(ProcessingMode.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .onChange(of: mode) { _, newValue in
                    ProcessingMode.save(newValue)
                }
            }
        }
        if let errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
        }
        Text(L10n.t("settings.note"))
            .font(.system(size: 10))
            .foregroundStyle(Theme.textQuaternary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { installMonitor() }
            .onDisappear {
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                keyMonitor = nil
            }
    }

    private func recorderButton(for action: HotKeyAction) -> some View {
        Button {
            errorMessage = nil
            recording = recording == action ? nil : action
        } label: {
            Text(recording == action ? L10n.t("settings.recording") : (shortcuts[action]?.display ?? "?"))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(recording == action ? Theme.accentSoft : Theme.textPrimary)
                .frame(minWidth: 90)
                .padding(.vertical, 5)
                .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .strokeBorder(recording == action ? Theme.accent.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// Même mécanique que le panneau Réglages historique : monitor local,
    /// Échap annule, modificateur requis, conflits détectés.
    private func installMonitor() {
        guard keyMonitor == nil else { return }
        if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[settings] monitor installé\n".utf8))
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] != nil {
                FileHandle.standardError.write(Data("[settings] keyDown code=\(event.keyCode) recording=\(String(describing: recording))\n".utf8))
            }
            guard let action = recording else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53, modifiers.isEmpty {
                recording = nil
                errorMessage = nil
                return nil
            }
            let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifierFlags: modifiers.rawValue)
            guard candidate.isValid else {
                errorMessage = L10n.t("settings.needModifier")
                return nil
            }
            let otherAction: HotKeyAction = action == .capture ? .selection : .capture
            if candidate == shortcuts[otherAction] {
                errorMessage = L10n.t("settings.taken")
                return nil
            }
            if model.onShortcutChange?(action, candidate) == true {
                shortcuts[action] = candidate
                recording = nil
                errorMessage = nil
            } else {
                errorMessage = L10n.t("settings.taken")
            }
            return nil
        }
    }
}

// MARK: - Dictée

private struct DictationSettingsView: View {
    @State private var cleanup = DictationSettings.cleanupEnabled
    @State private var localeChoice = DictationSettings.localeChoice
    @State private var shortcut = DictationSettings.shortcut

    var body: some View {
        SettingsGroup {
            SettingRow(
                title: L10n.t("settings.dictation.shortcut"),
                subtitle: L10n.t("settings.dictation.shortcutHint", shortcut.symbol)
            ) {
                Picker("", selection: Binding(
                    get: { shortcut },
                    set: { value in
                        shortcut = value
                        DictationSettings.shortcut = value
                    }
                )) {
                    ForEach(DictationKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            SettingsDivider()
            SettingRow(
                title: L10n.t("settings.dictation.cleanup"),
                subtitle: L10n.t("settings.dictation.cleanupHint")
            ) {
                StudioToggle(isOn: Binding(
                    get: { cleanup },
                    set: { value in
                        cleanup = value
                        DictationSettings.cleanupEnabled = value
                    }
                ))
            }
            SettingsDivider()
            SettingRow(
                title: L10n.t("settings.dictation.language"),
                subtitle: L10n.t("settings.dictation.languageHint")
            ) {
                Picker("", selection: Binding(
                    get: { localeChoice },
                    set: { value in
                        localeChoice = value
                        DictationSettings.localeChoice = value
                    }
                )) {
                    Text(L10n.t("settings.dictation.language.auto")).tag("auto")
                    Text(L10n.languageName("fr")).tag("fr")
                    Text(L10n.languageName("en")).tag("en")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
    }
}

// MARK: - Moteur

private struct EngineSettings: View {
    @State private var preference = TextEngine.shared.preference
    @State private var statusLabel = ""

    var body: some View {
        SettingsGroup {
            SettingRow(
                title: L10n.t("settings.engine.preference"),
                subtitle: L10n.t("settings.engine.preferenceHint")
            ) {
                Picker("", selection: Binding(
                    get: { preference },
                    set: { value in
                        preference = value
                        TextEngine.shared.preference = value
                        refreshStatus()
                    }
                )) {
                    Text(L10n.t("menu.engine.auto")).tag(EnginePreference.auto)
                    Text("Apple Intelligence").tag(EnginePreference.apple)
                    Text("Qwen3 4B (Ollama)").tag(EnginePreference.ollama)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            SettingsDivider()
            SettingRow(
                title: L10n.t("settings.engine.status"),
                subtitle: L10n.t("main.engineFallback")
            ) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusLabel.isEmpty ? Theme.textQuaternary : Theme.ok)
                        .frame(width: 6, height: 6)
                    Text(statusLabel.isEmpty ? "…" : statusLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .task { refreshStatus() }
    }

    private func refreshStatus() {
        statusLabel = ""
        Task { @MainActor in
            if let backend = await TextEngine.shared.resolveBackend() {
                statusLabel = TextEngine.shared.label(for: backend)
            } else {
                statusLabel = L10n.t("panel.engineMissing")
            }
        }
    }
}

// MARK: - À propos

private struct AboutSettings: View {
    var body: some View {
        SettingsGroup {
            SettingRow(
                title: "Butterfly",
                subtitle: L10n.t("settings.about.tagline")
            ) {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            SettingsDivider()
            SettingRow(title: "GitHub", subtitle: "github.com/guillonl/butterfly") {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/guillonl/butterfly")!)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Theme.controlFill, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
