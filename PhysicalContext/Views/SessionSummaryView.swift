import SwiftUI

struct SessionSummaryView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    @State var session: Session
    @State private var isSaving = false
    @State private var saved   = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                    Divider().background(Theme.border)
                    VStack(spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            whatYouDidCard
                            filesModifiedCard
                        }
                        if !session.deviations.isEmpty { deviationsSection }
                        additionalNotesSection
                        actions
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 660, height: 640)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: sfSymbol(for: session.appBundleID))
                .font(.system(size: 18, weight: .medium)).foregroundColor(Theme.accent)
                .frame(width: 42, height: 42).background(Theme.accentDim).cornerRadius(10)

            VStack(alignment: .leading, spacing: 4) {
                Text("Session Summary — \(session.appName)")
                    .font(Theme.sans(16, .semibold)).foregroundColor(Theme.textPrimary)
                HStack(spacing: 6) {
                    badge("clock",            session.durationString)
                    badge("arrow.down.circle", "\(session.changes.count) saves")
                    if !session.deviations.isEmpty {
                        badge("exclamationmark.triangle",
                              "\(session.deviations.count) deviations", Theme.warning)
                    }
                }
            }
            Spacer()
            if saved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.success)
                    Text("Saved").font(Theme.sans(12, .medium)).foregroundColor(Theme.success)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
    }

    private func badge(_ icon: String, _ value: String, _ color: Color = Theme.textSecondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(value).font(Theme.mono(10))
        }
        .foregroundColor(color).padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.surface).cornerRadius(5)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 0.5))
    }

    // MARK: - Cards

    private var whatYouDidCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("WHAT YOU DID", icon: "checkmark.circle", color: Theme.success)
            let bullets = summaryBullets()
            if bullets.isEmpty {
                Text("No changes recorded").font(Theme.sans(11)).foregroundColor(Theme.textTertiary)
            } else {
                ForEach(bullets, id: \.self) { b in
                    HStack(alignment: .top, spacing: 6) {
                        Text("—").font(Theme.mono(11)).foregroundColor(Theme.textTertiary)
                        Text(b).font(Theme.sans(12)).foregroundColor(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).surfaceCard(14)
    }

    private var filesModifiedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("FILES MODIFIED", icon: "doc", color: Theme.accent)
            let files = uniqueFiles()
            if files.isEmpty {
                Text("No files tracked").font(Theme.sans(11)).foregroundColor(Theme.textTertiary)
            } else {
                ForEach(files, id: \.self) { f in
                    Text(f).font(Theme.mono(11)).foregroundColor(Theme.textPrimary)
                }
            }
        }
        .frame(maxWidth: 220, alignment: .topLeading).surfaceCard(14)
    }

    private var deviationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("DEVIATIONS REQUIRING JUSTIFICATION",
                         icon: "exclamationmark.triangle", color: Theme.warning)
            ForEach($session.deviations) { $dev in DeviationCard(deviation: $dev) }
        }
    }

    private var additionalNotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADDITIONAL NOTES").font(Theme.mono(9, .semibold))
                .foregroundColor(Theme.textTertiary).tracking(1.2)
            TextEditor(text: $session.additionalNotes)
                .font(Theme.sans(12)).foregroundColor(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(10).background(Theme.surface).cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
                .frame(minHeight: 80)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Discard") {
                sessionManager.deleteSession(session)
                NSApp.keyWindow?.close()
            }.buttonStyle(GhostButtonStyle())

            Button {
                isSaving = true
                sessionManager.updateArchivedSession(session)
                withAnimation(.spring(response: 0.4)) { isSaving = false; saved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    NSApp.keyWindow?.close()
                }
            } label: {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().scaleEffect(0.7).frame(width: 12, height: 12) }
                    else { Image(systemName: "arrow.down.circle").font(.system(size: 12)) }
                    Text("Save Summary").font(Theme.sans(13, .medium))
                }
            }.buttonStyle(AccentButtonStyle())
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundColor(color)
            Text(title).font(Theme.mono(9, .semibold)).foregroundColor(color).tracking(1.2)
        }
    }

    private func summaryBullets() -> [String] {
        var out: [String] = []
        let saves = session.changes.filter { $0.changeType == .save }.count
        if saves > 0 { out.append("Saved \(saves) time\(saves == 1 ? "" : "s")") }
        out += session.notes.filter { $0.type == .manual }.prefix(4).map(\.content)
        if out.isEmpty { out = session.changes.prefix(4).map(\.description) }
        return out
    }

    private func uniqueFiles() -> [String] {
        Array(Set(session.changes.compactMap(\.file))).sorted()
    }

    private func sfSymbol(for bundleID: String) -> String {
        knownCADApps.first { $0.bundleID == bundleID }?.sfSymbol ?? "app"
    }
}

// MARK: - DeviationCard

struct DeviationCard: View {
    @Binding var deviation: Deviation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                TagView(label: deviation.severity.rawValue.uppercased(),
                        color: deviation.severityColor)
                Text(deviation.description).font(Theme.sans(12)).foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $deviation.confirmed) {
                Text("Confirmed — applies to my work")
                    .font(Theme.sans(11)).foregroundColor(Theme.textSecondary)
            }.toggleStyle(CheckboxToggleStyle())

            if deviation.confirmed {
                TextField("Your justification...", text: $deviation.justification, axis: .vertical)
                    .font(Theme.sans(11)).foregroundColor(Theme.textPrimary).textFieldStyle(.plain)
                    .padding(8).background(Theme.surfaceHigh).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 0.5))
                    .lineLimit(2...5)
            }
        }.surfaceCard(14)
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(configuration.isOn ? Theme.accent : Theme.surface)
                        .frame(width: 16, height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(configuration.isOn ? Theme.accent : Theme.border, lineWidth: 1))
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                configuration.label
            }
        }.buttonStyle(.plain)
    }
}
