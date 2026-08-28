import SwiftUI

/// Vue Apprentissage : la boucle d'auto-amélioration rendue visible.
/// Colonne « retouches observées » + panneau profil (vocabulaire, style).
struct LearningView: View {
    @ObservedObject var profile: LanguageProfileStore

    var body: some View {
        HStack(spacing: 0) {
            ObservedEditsColumn(profile: profile)
                .frame(width: 300)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ProfilePanel(profile: profile)
        }
    }
}

// MARK: - Colonne des retouches observées

private struct ObservedEditsColumn: View {
    @ObservedObject var profile: LanguageProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("learning.observed.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(L10n.t("learning.observed.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textQuaternary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .padding(.bottom, 10)

            if profile.vocab.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.12))
                    Text(L10n.t("learning.empty.title"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(L10n.t("learning.empty.hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textQuaternary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(profile.vocab) { rule in
                            ObservedEditRow(rule: rule)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Spacer(minLength: 0)
            Text(L10n.t("learning.observed.footer"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusRow)
                        .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .padding(12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surfaceBase)
    }
}

private struct ObservedEditRow: View {
    let rule: VocabRule

    private var meta: String {
        var parts = [L10n.t("learning.vocab.observed", rule.timesObserved)]
        if rule.status == .learned, rule.timesApplied > 0 {
            parts.append(L10n.t("learning.vocab.applied", rule.timesApplied))
        } else if !rule.apps.isEmpty {
            parts.append(rule.apps.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(rule.heard)
                    .font(.system(size: 12))
                    .strikethrough(true, color: Theme.fault.opacity(0.7))
                    .foregroundStyle(Theme.faultSoft)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textQuaternary)
                Text(rule.written)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.fix)
                Spacer(minLength: 0)
                Text(L10n.t(rule.status == .learned ? "learning.vocab.learned" : "learning.vocab.pending"))
                    .font(.system(size: 10))
                    .foregroundStyle(rule.status == .learned ? Theme.ok : Theme.accentSoft)
            }
            Text(meta)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textQuaternary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Panneau profil

private struct ProfilePanel: View {
    @ObservedObject var profile: LanguageProfileStore
    @State private var showAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.t("learning.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                HStack(spacing: 8) {
                    Text(L10n.t("learning.loop"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    StudioToggle(isOn: $profile.loopEnabled)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 44)
            .padding(.bottom, 12)
            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LoopStepsRow()

                    // Vocabulaire
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            StudioSectionLabel(text: L10n.t("learning.vocab"))
                            if !profile.vocab.isEmpty {
                                StudioBadge(text: L10n.t("learning.vocab.count", profile.vocab.count))
                            }
                            Spacer()
                            Button(L10n.t("learning.vocab.add")) { showAddSheet = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accentSoft)
                        }
                        if !profile.vocab.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(Array(profile.vocab.enumerated()), id: \.element.id) { index, rule in
                                    VocabRow(rule: rule, profile: profile)
                                    if index < profile.vocab.count - 1 {
                                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                                    }
                                }
                            }
                            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.radiusCard)
                                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
                            )
                        }
                    }

                    // Style
                    VStack(alignment: .leading, spacing: 8) {
                        StudioSectionLabel(text: L10n.t("learning.style.title"))
                        VStack(spacing: 0) {
                            ForEach(Array(profile.style.enumerated()), id: \.element.id) { index, rule in
                                HStack(spacing: 10) {
                                    Text(rule.label)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                    StudioToggle(isOn: Binding(
                                        get: { rule.enabled },
                                        set: { _ in profile.toggleStyle(rule.id) }
                                    ), size: 18)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                if index < profile.style.count - 1 {
                                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                                }
                            }
                        }
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusCard)
                                .strokeBorder(Theme.cardStroke, lineWidth: 1)
                        )
                    }
                }
                .padding(20)
            }

            Spacer(minLength: 0)
            HStack {
                Text(L10n.t("learning.footer.observations", profile.totalObservations))
                Spacer()
                Text(L10n.t("learning.footer.local"))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surfaceDeep)
        .sheet(isPresented: $showAddSheet) {
            AddRuleSheet(profile: profile)
        }
    }
}

/// La boucle en 4 temps, version compacte.
private struct LoopStepsRow: View {
    private let steps: [(title: String, hint: String, accent: Bool)] = [
        (L10n.t("learning.step1.title"), L10n.t("learning.step1.hint"), false),
        (L10n.t("learning.step2.title"), L10n.t("learning.step2.hint"), false),
        (L10n.t("learning.step3.title"), L10n.t("learning.step3.hint"), false),
        (L10n.t("learning.step4.title"), L10n.t("learning.step4.hint"), true),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(step.accent ? Theme.accentSoft : Theme.textSecondary)
                    Text(step.hint)
                        .font(.system(size: 10))
                        .foregroundStyle(step.accent ? Theme.textTertiary : Theme.textQuaternary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                .background(
                    step.accent ? Theme.accent.opacity(0.12) : Theme.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: Theme.radiusRow)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusRow)
                        .strokeBorder(step.accent ? Theme.accent.opacity(0.3) : Theme.cardStroke, lineWidth: 1)
                )
                if index < steps.count - 1 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textQuaternary)
                }
            }
        }
    }
}

private struct VocabRow: View {
    let rule: VocabRule
    let profile: LanguageProfileStore
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Text(rule.heard)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 110, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.textQuaternary)
            Text(rule.written)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if rule.status == .proposed {
                Button(L10n.t("learning.vocab.validate")) { profile.validate(rule.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Theme.accent, in: Capsule())
                Button(L10n.t("learning.vocab.ignore")) { profile.remove(rule.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                if rule.timesApplied > 0 {
                    Text(L10n.t("learning.vocab.applied", rule.timesApplied))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ok)
                }
                Button {
                    profile.remove(rule.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(hovered ? Theme.faultSoft : Theme.textQuaternary)
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Feuille d'ajout manuel d'un terme (entendu → écrit).
private struct AddRuleSheet: View {
    let profile: LanguageProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var heard = ""
    @State private var written = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("learning.vocab.add"))
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                TextField(L10n.t("learning.add.heard"), text: $heard)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(L10n.t("learning.add.written"), text: $written)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L10n.t("learning.add.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("learning.add.confirm")) {
                    profile.addManualRule(
                        heard: heard.trimmingCharacters(in: .whitespaces),
                        written: written.trimmingCharacters(in: .whitespaces)
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty
                    || written.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
