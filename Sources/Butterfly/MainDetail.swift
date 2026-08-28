import AppKit
import AVFoundation
import NaturalLanguage
import SwiftUI

/// Panneau de détail : correction (diff), dictée (lecteur + transcriptions),
/// ou état vide.
struct DetailView: View {
    @ObservedObject var model: MainViewModel

    var body: some View {
        Group {
            if let entry = model.selectedEntry {
                switch entry.kind {
                case .correction:
                    CorrectionDetail(model: model, entry: entry)
                case .dictation:
                    DictationDetail(model: model, entry: entry)
                }
            } else {
                VStack {
                    Spacer()
                    Text(L10n.t("main.empty.detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textQuaternary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surfaceDeep)
    }
}

// MARK: - En-tête commun

/// Formatter partagé de l'en-tête (hors du type générique : les stored
/// statics y sont interdits).
private let detailDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.locale = Locale(identifier: L10n.isFrench ? "fr_FR" : "en_US")
    return formatter
}()

private struct DetailHeader<Actions: View>: View {
    let entry: HistoryEntry
    @ViewBuilder var actions: Actions

    private var meta: String {
        var parts = [detailDateFormatter.string(from: entry.date)]
        if let trigger = entry.trigger {
            var label = L10n.t("main.detail.\(trigger)")
            switch trigger {
            case "capture": label += " \(ShortcutStore.shortcut(for: .capture).display)"
            case "selection": label += " \(ShortcutStore.shortcut(for: .selection).display)"
            default: break
            }
            parts.append(label)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textQuaternary)
                Spacer()
                actions
            }
            .padding(.horizontal, 20)
            .padding(.top, 44)
            .padding(.bottom, 12)
            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.horizontal, 20)
        }
    }
}

// MARK: - Détail correction

private struct CorrectionDetail: View {
    @ObservedObject var model: MainViewModel
    let entry: HistoryEntry

    @State private var isRegenerating = false
    @State private var isRetranslating = false
    @State private var engineError: String?

    private let languages = ["en", "fr", "es", "de", "it", "pt"]

    private var corrected: String { entry.corrected ?? entry.original }

    private var faultCount: Int {
        guard let corrected = entry.corrected else { return 0 }
        return WordDiff.faultCount(original: entry.original, corrected: corrected)
    }

    /// Langue du texte source (pour la bulle de synonymes et le moteur) :
    /// détectée sur le texte ENTIER, jamais sur un mot isolé (piège 10b).
    private var sourceLanguage: String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(entry.original)
        return recognizer.dominantLanguage?.rawValue ?? "fr"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(entry: entry) {
                StudioPillButton(
                    title: L10n.t("main.regenerate"),
                    systemImage: "arrow.clockwise"
                ) { regenerate() }
                    .disabled(isRegenerating)
                    .opacity(isRegenerating ? 0.5 : 1)
                CopyPillButton(text: corrected)
                DeleteButton { model.history.remove(entry.id) }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // CORRECTION : diff mot à mot
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            StudioSectionLabel(text: L10n.t("panel.correction"))
                            if entry.corrected != nil {
                                if faultCount == 0 {
                                    StudioBadge(
                                        text: L10n.t("panel.noChange"),
                                        color: Theme.fix,
                                        background: Theme.ok.opacity(0.12)
                                    )
                                } else {
                                    StudioBadge(
                                        text: L10n.plural("main.faults", faultCount),
                                        color: Theme.faultSoft,
                                        background: Theme.fault.opacity(0.14)
                                    )
                                }
                            }
                        }
                        DiffText(
                            original: entry.original,
                            corrected: corrected,
                            isBusy: isRegenerating
                        ) { word in
                            model.onWordTap?(word, sourceLanguage)
                        }
                        if faultCount > 0 {
                            DiffLegend()
                        }
                    }

                    // TEXTE FINAL : bloc copiable tel quel
                    if entry.corrected != nil, faultCount > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            StudioSectionLabel(text: L10n.t("main.finalText"))
                            Text(corrected)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radiusRow))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.radiusRow)
                                        .strokeBorder(Theme.cardStroke, lineWidth: 1)
                                )
                        }
                    }

                    // TRADUCTION
                    if let translated = entry.translated {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                StudioSectionLabel(text: L10n.t("panel.translation"))
                                languageMenu
                                if isRetranslating {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                            Text(translated)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .opacity(isRetranslating ? 0.5 : 1)
                        }
                    }

                    if let engineError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Text(engineError)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .padding(20)
            }

            Spacer(minLength: 0)
            DetailFooter(
                left: footerLeft,
                right: L10n.plural("main.words", WordDiff.tokens(corrected).count)
                    + " · " + L10n.languageName(sourceLanguage).lowercased()
            )
        }
    }

    /// Métriques réelles de l'entrée (mesurées au traitement) ; rien d'inventé.
    private var footerLeft: String {
        if let time = entry.processingTime, let engine = entry.engine {
            let seconds = String(format: L10n.isFrench ? "%.1f s" : "%.1fs", time)
                .replacingOccurrences(of: ".", with: L10n.isFrench ? "," : ".")
            return L10n.t("main.correctedIn", seconds, engine)
        }
        return entry.engine ?? ""
    }

    private var languageMenu: some View {
        Menu {
            ForEach(languages, id: \.self) { code in
                Button {
                    retranslate(to: code)
                } label: {
                    if code == entry.targetLanguage {
                        Label(L10n.languageName(code), systemImage: "checkmark")
                    } else {
                        Text(L10n.languageName(code))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(L10n.languageName(entry.targetLanguage))
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Theme.controlFill, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func regenerate() {
        guard let previous = entry.corrected else { return }
        isRegenerating = true
        engineError = nil
        let entryID = entry.id
        let original = entry.original
        let source = sourceLanguage
        let target = entry.targetLanguage
        let hadTranslation = entry.translated != nil
        Task { @MainActor in
            defer { isRegenerating = false }
            guard let backend = await TextEngine.shared.resolveBackend() else {
                engineError = L10n.t("panel.engineMissing")
                return
            }
            do {
                let corrected = try await TextEngine.shared.regenerate(
                    original, source: source, previous: previous, using: backend
                )
                model.history.updateCorrection(id: entryID, corrected: corrected)
                if hadTranslation {
                    let translated = try await TextEngine.shared.translate(
                        corrected, from: source, to: target, using: backend
                    )
                    model.history.updateTranslation(id: entryID, translated: translated, language: target)
                }
            } catch {
                engineError = L10n.t("panel.error")
            }
        }
    }

    private func retranslate(to code: String) {
        guard code != entry.targetLanguage || entry.translated == nil else { return }
        isRetranslating = true
        engineError = nil
        let entryID = entry.id
        let source = sourceLanguage
        let text = corrected
        Task { @MainActor in
            defer { isRetranslating = false }
            guard let backend = await TextEngine.shared.resolveBackend() else {
                engineError = L10n.t("panel.engineMissing")
                return
            }
            do {
                let translated = try await TextEngine.shared.translate(
                    text, from: source, to: code, using: backend
                )
                model.history.updateTranslation(id: entryID, translated: translated, language: code)
            } catch {
                engineError = L10n.t("panel.error")
            }
        }
    }
}

/// Rendu du diff : fautes barrées, corrections en vert cliquables.
private struct DiffText: View {
    let original: String
    let corrected: String
    var isBusy = false
    var onFixTap: (String) -> Void

    @State private var hoveredIndex: Int?

    var body: some View {
        let segments = WordDiff.diff(original: original, corrected: corrected)
        FlowLayout(horizontalSpacing: 5, verticalSpacing: 7) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .same(let word):
                    Text(word)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                case .removed(let word):
                    Text(word)
                        .font(.system(size: 15))
                        .strikethrough(true, color: Theme.fault)
                        .foregroundStyle(Theme.textQuaternary)
                case .added(let word):
                    Text(word)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.fix)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Theme.ok.opacity(hoveredIndex == index ? 0.20 : 0.10),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .onHover { inside in
                            hoveredIndex = inside ? index : (hoveredIndex == index ? nil : hoveredIndex)
                        }
                        .onTapGesture {
                            let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
                            guard !cleaned.isEmpty else { return }
                            onFixTap(cleaned)
                        }
                }
            }
        }
        .opacity(isBusy ? 0.5 : 1)
        .animation(.easeOut(duration: 0.2), value: isBusy)
    }
}

/// Légende sous le diff (trait rouge / bloc vert).
private struct DiffLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.fault)
                    .frame(width: 14, height: 2)
                Text(L10n.t("main.legend.fault"))
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.ok.opacity(0.25))
                    .frame(width: 14, height: 8)
                Text(L10n.t("main.legend.fix"))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textTertiary)
    }
}

// MARK: - Détail dictée

private struct DictationDetail: View {
    @ObservedObject var model: MainViewModel
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(entry: entry) {
                CopyPillButton(text: entry.corrected ?? entry.original, prominent: true)
                DeleteButton { model.history.remove(entry.id) }
            }

            AudioPlayerCard(entry: entry)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        StudioSectionLabel(text: L10n.t("main.transcription"))
                        Text(entry.corrected ?? entry.original)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textPrimary)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                    if let raw = entry.rawTranscript {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                StudioSectionLabel(text: L10n.t("main.rawHeard"))
                                StudioBadge(text: L10n.t("main.correctedOnFly"))
                            }
                            Text(raw)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textQuaternary)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(20)
            }

            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if let app = entry.sourceApp {
                    Text(L10n.t("main.insertedIn"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textQuaternary)
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.accentSoft.opacity(0.7))
                            .frame(width: 7, height: 7)
                        Text(app)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.controlFill, in: Capsule())
                }
                Spacer()
                Text(
                    L10n.plural("main.words", WordDiff.tokens(entry.corrected ?? entry.original).count)
                )
                .font(.system(size: 11))
                .foregroundStyle(Theme.textQuaternary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                    .padding(.horizontal, 20)
            }
        }
    }
}

/// Lecteur audio de dictée : lecture réelle si le fichier existe,
/// barres décoratives déterministes en attendant les vrais échantillons.
private struct AudioPlayerCard: View {
    let entry: HistoryEntry

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var timer: Timer?

    private var audioURL: URL? {
        guard let file = entry.audioFile else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = base?.appendingPathComponent("Butterfly/Recordings/\(file)")
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Hauteurs pseudo-aléatoires mais stables par entrée (le waveform réel
    /// arrivera avec l'enregistreur, qui stockera les échantillons).
    private var bars: [CGFloat] {
        var seed = UInt64(truncatingIfNeeded: entry.id.hashValue)
        return (0..<26).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return 6 + CGFloat(seed % 20)
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            PlayButton(enabled: audioURL != nil, isPlaying: isPlaying) { toggle() }
            HStack(spacing: 2.5) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(
                            Double(index) / Double(bars.count) <= progress && audioURL != nil
                                ? Theme.accentSoft
                                : Color.white.opacity(0.18)
                        )
                        .frame(width: 3, height: height)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(timeLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
        .onDisappear { stop() }
        .onChange(of: entry.id) { stop() }
    }

    private var timeLabel: String {
        let total = entry.duration ?? player?.duration ?? 0
        let current = (player?.currentTime).map { $0 } ?? 0
        func format(_ value: TimeInterval) -> String {
            let seconds = Int(value.rounded())
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return isPlaying || progress > 0
            ? "\(format(current)) / \(format(total))"
            : format(total)
    }

    private func toggle() {
        guard let url = audioURL else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
            timer?.invalidate()
            return
        }
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: url)
        }
        guard let player else { return }
        player.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
                if !player.isPlaying {
                    self.isPlaying = false
                    self.timer?.invalidate()
                }
            }
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        progress = 0
        timer?.invalidate()
        timer = nil
    }
}

private struct PlayButton: View {
    let enabled: Bool
    let isPlaying: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    enabled ? Theme.accent.opacity(hovered ? 0.85 : 1) : Color.white.opacity(0.10),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
    }
}

// MARK: - Communs

/// Copier avec feedback ✓ (équivalent CopyButton, en capsule Studio).
struct CopyPillButton: View {
    let text: String
    var prominent = false
    @State private var copied = false
    @State private var hovered = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeOut(duration: 0.3)) { copied = false }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.t(copied ? "main.copied" : "main.copy"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(copied ? Theme.fix : (prominent ? .white : Theme.textSecondary))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                prominent && !copied
                    ? AnyShapeStyle(Theme.accent.opacity(hovered ? 0.85 : 1))
                    : AnyShapeStyle(Color.white.opacity(hovered ? 0.11 : 0.07)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct DeleteButton: View {
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovered ? Theme.faultSoft : Theme.textTertiary)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(hovered ? 0.11 : 0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(L10n.t("main.delete"))
    }
}

/// Pied de panneau : deux métadonnées séparées par l'espace.
private struct DetailFooter: View {
    let left: String
    let right: String

    var body: some View {
        HStack {
            Text(left)
            Spacer()
            Text(right)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textQuaternary)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.horizontal, 20)
        }
    }
}
