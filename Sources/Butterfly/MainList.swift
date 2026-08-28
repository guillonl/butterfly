import AppKit
import SwiftUI

/// Colonne centrale : recherche + entrées groupées par date.
struct EntryListView: View {
    @ObservedObject var model: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.searchText)
                .padding(.horizontal, 14)
                .padding(.top, 44)
                .padding(.bottom, 10)

            if model.filteredEntries.isEmpty {
                EmptyListState(section: model.section)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.groupedEntries, id: \.key) { group in
                            Text(group.key)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textQuaternary)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            ForEach(group.entries) { entry in
                                EntryRow(
                                    entry: entry,
                                    selected: entry.id == model.selectedEntry?.id
                                ) {
                                    model.selectedEntryID = entry.id
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }

            Spacer(minLength: 0)
            ShortcutHintCard()
                .padding(12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surfaceBase)
    }
}

/// Champ de recherche discret (fond controlFill, radius 8).
private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textQuaternary)
            TextField(L10n.t("main.search"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textQuaternary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .strokeBorder(focused ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1)
        )
    }
}

/// Une entrée de la liste : première ligne + badge d'état + méta.
private struct EntryRow: View {
    let entry: HistoryEntry
    let selected: Bool
    var action: () -> Void

    @State private var hovered = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private var title: String {
        (entry.corrected ?? entry.original)
            .replacingOccurrences(of: "\n", with: " ")
    }

    private var faultCount: Int {
        guard let corrected = entry.corrected else { return 0 }
        return WordDiff.faultCount(original: entry.original, corrected: corrected)
    }

    private var meta: String {
        var parts: [String] = [Self.timeFormatter.string(from: entry.date)]
        switch entry.kind {
        case .dictation:
            if let duration = entry.duration {
                parts.append(L10n.t("main.trigger.dictation") + ", " + Self.format(duration: duration))
            } else {
                parts.append(L10n.t("main.trigger.dictation"))
            }
            if let app = entry.sourceApp {
                parts.append(L10n.t("main.insertedIn").lowercased() + " " + app)
            }
        case .correction:
            if let trigger = entry.trigger {
                parts.append(L10n.t("main.trigger.\(trigger)"))
            }
            if entry.translated != nil {
                parts.append(L10n.languageName(entry.targetLanguage))
            }
        }
        return parts.joined(separator: " · ")
    }

    static func format(duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    badge
                }
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Theme.textTertiary : Theme.textQuaternary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusRow)
                    .fill(selected ? Theme.selectionFill : Color.white.opacity(hovered ? 0.04 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusRow)
                    .strokeBorder(selected ? Theme.selectionStroke : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusRow))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var badge: some View {
        switch entry.kind {
        case .dictation:
            if let duration = entry.duration {
                Text(Self.format(duration: duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(selected ? Theme.accentSoft : Theme.textQuaternary)
            }
        case .correction:
            if entry.corrected != nil {
                if faultCount == 0 {
                    StudioBadge(
                        text: L10n.t("main.clean"),
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
    }
}

/// Rappel des raccourcis en pied de liste (bordure pointillée, comme la maquette).
private struct ShortcutHintCard: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "pencil.line")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accentSoft)
            HStack(spacing: 4) {
                StudioKeycap(text: ShortcutStore.shortcut(for: .capture).display)
                Text(L10n.t("main.trigger.capture"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textQuaternary)
                StudioKeycap(text: ShortcutStore.shortcut(for: .selection).display)
                Text(L10n.t("main.trigger.selection"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusRow)
                .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}

/// État vide de la liste, selon la section.
private struct EmptyListState: View {
    let section: LibrarySection

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            ButterflyShape()
                .fill(Color.white.opacity(0.10))
                .frame(width: 44, height: 44)
            Text(L10n.t("main.empty.title"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textQuaternary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private var hint: String {
        switch section {
        case .dictations:
            return L10n.t("main.empty.dictations")
        default:
            return L10n.t(
                "main.empty.corrections",
                ShortcutStore.shortcut(for: .capture).display,
                ShortcutStore.shortcut(for: .selection).display
            )
        }
    }
}
