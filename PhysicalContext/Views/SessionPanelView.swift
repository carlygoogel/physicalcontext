import SwiftUI

struct SessionPanelView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    let onWidthChange: (CGFloat) -> Void

    let collapsedW: CGFloat = 52
    let expandedW:  CGFloat = 300

    @State private var expanded      = false
    @State private var newNoteText   = ""
    @State private var showNoteField = false
    @State private var elapsed: TimeInterval = 0
    @FocusState private var noteFocused: Bool

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .trailing) {
            // ✅ Solid opaque background covers the VFX grey bleed completely
            if expanded {
                Color(red: 0.06, green: 0.07, blue: 0.09)
                    .ignoresSafeArea()
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    )
            }

            HStack(spacing: 0) {
                if expanded {
                    expandedContent
                        .frame(width: expandedW - collapsedW)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                sideTab
                    .frame(width: collapsedW)
            }
        }
        .frame(width: expanded ? expandedW : collapsedW, height: 520)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: expanded)
        .onChange(of: expanded) { _, isExpanded in
            onWidthChange(isExpanded ? expandedW : collapsedW)
        }
        .onReceive(clock) { _ in
            elapsed = sessionManager.currentSession
                .map { -$0.startTime.timeIntervalSinceNow } ?? elapsed
        }
        .onAppear {
            elapsed = sessionManager.currentSession
                .map { -$0.startTime.timeIntervalSinceNow } ?? 0
        }
    }

    // MARK: - Side Tab (always visible)

    private var sideTab: some View {
        Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            expanded.toggle()
        }} label: {
            VStack(spacing: 10) {
                Spacer()

                // Live indicator
                if sessionManager.currentSession != nil {
                    Circle()
                        .fill(Color(hex: "#4CC38A"))
                        .frame(width: 7, height: 7)
                        .shadow(color: Color(hex: "#4CC38A").opacity(0.7), radius: 4)
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 7, height: 7)
                }

                // Rotated label
                Text(sessionManager.currentSession != nil ? "SESSION" : "CONTEXT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.4))
                    .tracking(1.5)
                    .rotationEffect(.degrees(-90))
                    .fixedSize()
                    .frame(width: 20, height: 60)

                // Change count badge
                if let session = sessionManager.currentSession,
                   !session.changes.isEmpty {
                    Text("\(session.changes.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 20, height: 20)
                        .background(Color(hex: "#5B8DEF").opacity(0.85))
                        .clipShape(Circle())
                }

                // Arrow
                Image(systemName: expanded ? "chevron.right" : "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.3))

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .frame(width: collapsedW)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.06, green: 0.07, blue: 0.09).opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 16, x: -4)
        )
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(spacing: 0) {
            expandedHeader
            Divider().background(Color.white.opacity(0.07))

            if let session = sessionManager.currentSession {
                // Stats row
                statsRow(session)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                Divider().background(Color.white.opacity(0.05))

                // Live timeline
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        if session.changes.isEmpty && session.notes.isEmpty {
                            emptyTimeline
                        } else {
                            ForEach(buildTimeline(session)) { item in
                                timelineRow(item)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }

                Divider().background(Color.white.opacity(0.07))
                inputBar

            } else {
                noSession
            }
        }
    }

    private var expandedHeader: some View {
        HStack(spacing: 8) {
            if let session = sessionManager.currentSession {
                Circle()
                    .fill(Color(hex: "#4CC38A"))
                    .frame(width: 6, height: 6)
                    .shadow(color: Color(hex: "#4CC38A").opacity(0.6), radius: 3)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(sessionManager.currentSession?.appName ?? "Physical Context")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.9))
                if sessionManager.currentSession != nil {
                    Text(formatElapsed(elapsed))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.35))
                }
            }

            Spacer()

            if sessionManager.currentSession != nil {
                Button("End") {
                    DispatchQueue.main.async { SessionManager.shared.endSession() }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: "#F87171"))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color(hex: "#F87171").opacity(0.12))
                .cornerRadius(6)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - Stats

    private func statsRow(_ session: Session) -> some View {
        HStack(spacing: 6) {
            statChip("\(session.changes.count)", "saves",
                     icon: "arrow.down.circle", color: Color(hex: "#5B8DEF"))
            statChip("\(session.notes.count)", "notes",
                     icon: "text.alignleft", color: Color.white.opacity(0.4))
            if session.deviations.count > 0 {
                statChip("\(session.deviations.count)", "flags",
                         icon: "exclamationmark.triangle.fill",
                         color: Color(hex: "#F59E0B"))
            }
            Spacer()
        }
    }

    private func statChip(_ value: String, _ label: String,
                           icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9)).foregroundColor(color)
            Text(value).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
            Text(label).font(.system(size: 9)).foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Color.white.opacity(0.05)).cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    // MARK: - Timeline

    private func buildTimeline(_ session: Session) -> [TLItem] {
        var items: [TLItem] = []
        for n in session.notes {
            items.append(TLItem(id: n.id, ts: n.timestamp,
                                text: n.content,
                                color: n.typeColor, icon: "text.alignleft"))
        }
        for c in session.changes {
            items.append(TLItem(id: c.id, ts: c.timestamp,
                                text: c.description,
                                color: Color.white.opacity(0.3), icon: c.icon))
        }
        return items.sorted { $0.ts > $1.ts }
    }

    private func timelineRow(_ item: TLItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(item.color).frame(width: 5, height: 5).padding(.top, 6)
                Rectangle().fill(Color.white.opacity(0.06))
                    .frame(width: 1).frame(maxHeight: .infinity)
            }.frame(width: 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.ts, style: .time)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.25))
            }
            .padding(.bottom, 12)
            Spacer()
        }
    }

    private var emptyTimeline: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 40)
            Image(systemName: "waveform")
                .font(.system(size: 20)).foregroundColor(Color.white.opacity(0.15))
            Text("Waiting for changes…")
                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.25))
                .multilineTextAlignment(.center)
            Text("File saves and window changes\nappear here automatically.")
                .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.15))
                .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }

    private var noSession: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "hexagon")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Color.white.opacity(0.12))
            Text("No active session")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.white.opacity(0.3))
            Text("Open a CAD app to begin.")
                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.18))
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            if showNoteField {
                VStack(spacing: 8) {
                    TextEditor(text: $newNoteText)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.8))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 52, maxHeight: 80)
                        .focused($noteFocused)
                    HStack {
                        Button("Cancel") { newNoteText = ""; showNoteField = false }
                            .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
                            .buttonStyle(.plain)
                        Spacer()
                        Button("Add") {
                            SessionManager.shared.addNote(newNoteText)
                            newNoteText = ""; showNoteField = false
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Color(hex: "#5B8DEF").opacity(0.85))
                        .cornerRadius(6)
                        .buttonStyle(.plain)
                        .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.04))
                .overlay(Rectangle().frame(height: 0.5)
                    .foregroundColor(Color.white.opacity(0.07)), alignment: .top)
            } else {
                HStack(spacing: 8) {
                    Button {
                        showNoteField = true; noteFocused = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            Text("Add Note").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(Color.white.opacity(0.5))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Color.white.opacity(0.05)).cornerRadius(7)
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                    }.buttonStyle(.plain)

                    Button {
                        DispatchQueue.main.async {
                            SessionManager.shared.addDeviation("Manual flag")
                        }
                    } label: {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#F59E0B"))
                            .frame(width: 34, height: 34)
                            .background(Color(hex: "#F59E0B").opacity(0.1))
                            .cornerRadius(7)
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .stroke(Color(hex: "#F59E0B").opacity(0.25), lineWidth: 0.5))
                    }.buttonStyle(.plain).help("Flag spec deviation")
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
            }
        }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return s < 3600
            ? String(format: "%d:%02d", s / 60, s % 60)
            : String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

private struct TLItem: Identifiable {
    let id: UUID; let ts: Date; let text: String
    let color: Color; let icon: String
}
