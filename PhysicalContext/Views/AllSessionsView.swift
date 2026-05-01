import SwiftUI

struct AllSessionsView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    @State private var selectedID: UUID?
    @State private var searchText = ""

    private var filtered: [Session] {
        guard !searchText.isEmpty else { return sessionManager.allSessions }
        let q = searchText.lowercased()
        return sessionManager.allSessions.filter {
            $0.appName.lowercased().contains(q) ||
            $0.notes.contains { $0.content.lowercased().contains(q) }
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            HSplitView {
                sidebarList.frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
                detailPane.frame(minWidth: 380)
            }
        }
        .frame(width: 720, height: 560)
    }

    // MARK: - Sidebar

    private var sidebarList: some View {
        VStack(spacing: 0) {
            listHeader
            Divider().background(Theme.border)
            if filtered.isEmpty {
                emptyList
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filtered) { session in
                            sessionRow(session)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedID = session.id }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        if selectedID == session.id { selectedID = nil }
                                        sessionManager.deleteSession(session)
                                    } label: {
                                        Label("Delete Session", systemImage: "trash")
                                    }
                                }
                        }
                    }.padding(8)
                }
            }
        }
        .background(Theme.surface)
    }

    private var listHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Sessions").font(Theme.sans(14, .semibold)).foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(sessionManager.allSessions.count)").font(Theme.mono(10))
                    .foregroundColor(Theme.textSecondary).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.surfaceHigh).cornerRadius(4)
            }
            HStack {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                TextField("Search...", text: $searchText).font(Theme.sans(12))
                    .foregroundColor(Theme.textPrimary).textFieldStyle(.plain)
            }
            .padding(.horizontal, 9).padding(.vertical, 7).background(Theme.surfaceHigh).cornerRadius(7)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 0.5))
        }.padding(12)
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock").font(.system(size: 28, weight: .light)).foregroundColor(Theme.textTertiary)
            Text("No sessions yet").font(Theme.sans(13)).foregroundColor(Theme.textSecondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionRow(_ session: Session) -> some View {
        let isSelected = selectedID == session.id
        return HStack(spacing: 10) {
            Image(systemName: sfSymbol(for: session.appBundleID))
                .font(.system(size: 12))
                .foregroundColor(isSelected ? Theme.accent : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(isSelected ? Theme.accentDim : Theme.surfaceHigh).cornerRadius(7)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.appName).font(Theme.sans(12, .medium)).foregroundColor(Theme.textPrimary)
                HStack(spacing: 4) {
                    Text(session.startTime, style: .date)
                    Text("·")
                    Text(session.durationString)
                }
                .font(Theme.mono(9)).foregroundColor(Theme.textTertiary)
            }
            Spacer()
            if !session.deviations.isEmpty { Circle().fill(Theme.warning).frame(width: 6, height: 6) }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(isSelected ? Theme.accentDim : Color.clear).cornerRadius(8)
    }

    // MARK: - Detail

    private var detailPane: some View {
        Group {
            if let id = selectedID,
               let session = sessionManager.allSessions.first(where: { $0.id == id }) {
                sessionDetail(session)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sidebar.left").font(.system(size: 32, weight: .light))
                        .foregroundColor(Theme.textTertiary)
                    Text("Select a session").font(Theme.sans(14)).foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
            }
        }
    }

    private func sessionDetail(_ session: Session) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(session.appName).font(Theme.sans(18, .semibold)).foregroundColor(Theme.textPrimary)
                        Spacer()
                        TagView(label: session.durationString, color: Theme.textSecondary)
                    }
                    Text(session.formattedDate).font(Theme.mono(11)).foregroundColor(Theme.textSecondary)
                    HStack(spacing: 8) {
                        pill("\(session.changes.count)", "saves")
                        pill("\(session.notes.count)", "notes")
                        if !session.deviations.isEmpty { pill("\(session.deviations.count)", "deviations", Theme.warning) }
                    }
                }

                if !session.notes.isEmpty {
                    sectionLabel("NOTES", icon: "text.alignleft")
                    ForEach(session.notes) { n in noteRow(n) }
                }
                if !session.changes.isEmpty {
                    sectionLabel("CHANGES", icon: "arrow.triangle.2.circlepath")
                    ForEach(session.changes) { c in changeRow(c) }
                }
                if !session.deviations.isEmpty {
                    sectionLabel("DEVIATIONS", icon: "exclamationmark.triangle", color: Theme.warning)
                    ForEach(session.deviations) { d in devRow(d) }
                }
                if !session.additionalNotes.isEmpty {
                    sectionLabel("NOTES", icon: "note.text")
                    Text(session.additionalNotes).font(Theme.sans(12)).foregroundColor(Theme.textPrimary)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).surfaceCard(0)
                }
                Spacer()
            }.padding(24)
        }.background(Theme.background)
    }

    private func sectionLabel(_ title: String, icon: String, color: Color = Theme.textTertiary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10))
            Text(title).font(Theme.mono(9, .semibold)).tracking(1.2)
        }.foregroundColor(color)
    }

    private func pill(_ v: String, _ l: String, _ c: Color = Theme.textSecondary) -> some View {
        HStack(spacing: 4) {
            Text(v).font(Theme.mono(10, .semibold)).foregroundColor(c)
            Text(l).font(Theme.sans(10)).foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.surface).cornerRadius(5)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 0.5))
    }

    private func noteRow(_ n: Note) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TagView(label: n.typeLabel, color: n.typeColor).frame(width: 84, alignment: .leading)
            Text(n.content).font(Theme.sans(12)).foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text(n.timestamp, style: .time).font(Theme.mono(9)).foregroundColor(Theme.textTertiary)
        }
        .padding(10).background(Theme.surface).cornerRadius(7)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 0.5))
    }

    private func changeRow(_ c: Change) -> some View {
        HStack(spacing: 8) {
            Image(systemName: c.icon).font(.system(size: 11)).foregroundColor(Theme.textTertiary).frame(width: 20)
            Text(c.description).font(Theme.sans(11)).foregroundColor(Theme.textPrimary)
            Spacer()
            Text(c.timestamp, style: .time).font(Theme.mono(9)).foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7).background(Theme.surface).cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 0.5))
    }

    private func devRow(_ d: Deviation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TagView(label: d.severity.rawValue.uppercased(), color: d.severityColor)
                Text(d.description).font(Theme.sans(12)).foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !d.justification.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("Justification:").font(Theme.mono(10, .semibold)).foregroundColor(Theme.textTertiary)
                    Text(d.justification).font(Theme.sans(11)).foregroundColor(Theme.textSecondary)
                }
            }
        }.surfaceCard(12)
    }

    private func sfSymbol(for bundleID: String) -> String {
        knownCADApps.first { $0.bundleID == bundleID }?.sfSymbol ?? "app"
    }
}
