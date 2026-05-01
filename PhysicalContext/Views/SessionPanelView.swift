import SwiftUI
import AppKit

// MARK: - WindowKeyMaker
// Makes the floating NSPanel accept key events when the user taps into a
// text field. Without this, .nonactivatingPanel silently discards keystrokes.
private struct WindowKeyMaker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            v.window?.makeKey()
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            v.window?.makeKey()
        }
    }
}

// MARK: - Input Mode

private enum InputMode: Equatable { case none, note, deviation }

// MARK: - SessionPanelView

struct SessionPanelView: View {
    @ObservedObject private var sessionManager = SessionManager.shared
    let onWidthChange: (CGFloat) -> Void

    let collapsedW: CGFloat = 52
    let expandedW:  CGFloat = 320

    @State private var expanded       = false
    @State private var inputMode      = InputMode.none
    @State private var noteText       = ""
    @State private var devText        = ""
    @State private var devJustText    = ""
    @State private var devSeverity    = Deviation.Severity.moderate
    @State private var elapsed: TimeInterval = 0

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Panel background — solid dark, no VFX bleed
    private let bg = Color(red: 0.06, green: 0.07, blue: 0.10)

    var body: some View {
        ZStack(alignment: .trailing) {
            if expanded {
                bg.ignoresSafeArea()
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            HStack(spacing: 0) {
                if expanded {
                    expandedPanel
                        .frame(width: expandedW - collapsedW)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                sideTab.frame(width: collapsedW)
            }
        }
        // ✅ Height matches AppDelegate.panelHeight (640) exactly.
        // Using maxHeight:.infinity lets the view fill the window without
        // clipping the timer at top or buttons at bottom.
        .frame(width: expanded ? expandedW : collapsedW)
        .frame(maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: expanded)
        .onChange(of: expanded) { _, v in
            onWidthChange(v ? expandedW : collapsedW)
            if !v { inputMode = .none }
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

    // MARK: - Side Tab

    private var sideTab: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { expanded.toggle() }
        } label: {
            VStack(spacing: 10) {
                Spacer()
                Circle()
                    .fill(sessionManager.currentSession != nil
                          ? Color(hex: "#4CC38A") : Color.white.opacity(0.15))
                    .frame(width: 7, height: 7)
                    .shadow(color: sessionManager.currentSession != nil
                            ? Color(hex: "#4CC38A").opacity(0.6) : .clear, radius: 4)

                Text(sessionManager.currentSession != nil ? "SESSION" : "CONTEXT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.35))
                    .tracking(1.5)
                    .rotationEffect(.degrees(-90))
                    .fixedSize()
                    .frame(width: 20, height: 60)

                if let s = sessionManager.currentSession, !s.changes.isEmpty {
                    Text("\(s.changes.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 20, height: 20)
                        .background(Color(hex: "#5B8DEF").opacity(0.85))
                        .clipShape(Circle())
                }
                if let s = sessionManager.currentSession, !s.deviations.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#F59E0B"))
                }
                Image(systemName: expanded ? "chevron.right" : "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.25))
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .frame(width: collapsedW)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(bg.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 16, x: -4)
        )
    }

    // MARK: - Expanded Panel

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider().background(Color.white.opacity(0.08))

            if let session = sessionManager.currentSession {
                statsBar(session)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Divider().background(Color.white.opacity(0.05))

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        let items = buildTimeline(session)
                        if items.isEmpty {
                            emptyState
                        } else {
                            ForEach(items) { item in tlRow(item) }
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
                }

                Divider().background(Color.white.opacity(0.08))
                bottomInput
            } else {
                noSessionState
            }
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            if sessionManager.currentSession != nil {
                Circle().fill(Color(hex: "#4CC38A")).frame(width: 6, height: 6)
                    .shadow(color: Color(hex: "#4CC38A").opacity(0.5), radius: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(sessionManager.currentSession?.appName ?? "Physical Context")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                if sessionManager.currentSession != nil {
                    Text(formatElapsed(elapsed))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.3))
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
                .cornerRadius(6).buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - Stats

    private func statsBar(_ session: Session) -> some View {
        HStack(spacing: 6) {
            miniChip("\(session.changes.count)", "saves",
                     icon: "arrow.down.circle", color: Color(hex: "#5B8DEF"))
            miniChip("\(session.notes.count)", "notes",
                     icon: "text.alignleft", color: Color.white.opacity(0.35))
            if session.deviations.count > 0 {
                miniChip("\(session.deviations.count)", "flags",
                         icon: "exclamationmark.triangle.fill",
                         color: Color(hex: "#F59E0B"))
            }
            Spacer()
        }
    }

    private func miniChip(_ v: String, _ l: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9)).foregroundColor(color)
            Text(v).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
            Text(l).font(.system(size: 9)).foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Color.white.opacity(0.06)).cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Color.white.opacity(0.09), lineWidth: 0.5))
    }

    // MARK: - Timeline

    private struct TLItem: Identifiable {
        let id: UUID; let ts: Date; let text: String
        let kind: Kind; let color: Color
        enum Kind: Equatable {
            case note(Note.NoteType), change, deviation(Deviation.Severity)
        }
    }

    private func buildTimeline(_ session: Session) -> [TLItem] {
        var items = [TLItem]()
        for n in session.notes {
            items.append(.init(id: n.id, ts: n.timestamp, text: n.content,
                               kind: .note(n.type), color: n.typeColor))
        }
        for c in session.changes {
            items.append(.init(id: c.id, ts: c.timestamp, text: c.description,
                               kind: .change, color: Color.white.opacity(0.22)))
        }
        for d in session.deviations {
            let text = d.description + (d.justification.isEmpty ? "" : "\n↳ \(d.justification)")
            items.append(.init(id: d.id, ts: d.timestamp, text: text,
                               kind: .deviation(d.severity), color: d.severityColor))
        }
        return items.sorted { $0.ts > $1.ts }
    }

    private func tlRow(_ item: TLItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                if case .deviation = item.kind {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 7)).foregroundColor(item.color)
                        .padding(.top, 5)
                } else {
                    Circle().fill(item.color).frame(width: 5, height: 5).padding(.top, 6)
                }
                Rectangle().fill(Color.white.opacity(0.05))
                    .frame(width: 1).frame(maxHeight: .infinity)
            }.frame(width: 12)

            VStack(alignment: .leading, spacing: 3) {
                if case .deviation(let sev) = item.kind {
                    Text(sev.rawValue.uppercased())
                        .font(.system(size: 8, weight: .bold)).foregroundColor(item.color)
                        .tracking(0.6).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(item.color.opacity(0.12)).cornerRadius(3)
                }
                Text(item.text)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.ts, style: .time)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.2))
            }.padding(.bottom, 12)
            Spacer()
        }
    }

    // MARK: - Bottom Input

    private var bottomInput: some View {
        VStack(spacing: 0) {
            switch inputMode {
            case .none:      actionBar
            case .note:      noteForm
            case .deviation: devForm
            }
        }
        .background(bg)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                inputMode = .note
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    Text("Add Note").font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Color.white.opacity(0.55))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Color.white.opacity(0.07)).cornerRadius(7)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5))
            }.buttonStyle(.plain)

            Button {
                inputMode = .deviation
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text("Flag").font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Color(hex: "#F59E0B"))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Color(hex: "#F59E0B").opacity(0.09)).cornerRadius(7)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(hex: "#F59E0B").opacity(0.28), lineWidth: 0.5))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
    }

    // MARK: - Note Form

    private var noteForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            formHeader("Add Note", icon: "text.alignleft",
                       iconColor: Color(hex: "#818CF8")) { noteText = ""; inputMode = .none }

            // ✅ Visible text area with high-contrast border
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.12, green: 0.14, blue: 0.18))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(hex: "#818CF8").opacity(0.4), lineWidth: 1))
                if noteText.isEmpty {
                    Text("Describe the decision or change…")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.25))
                        .padding(.horizontal, 10).padding(.top, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $noteText)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(minHeight: 72, maxHeight: 120)
                    // ✅ Makes the nonactivatingPanel accept keystrokes
                    .background(WindowKeyMaker())
            }

            HStack {
                Button("Cancel") { noteText = ""; inputMode = .none }
                    .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.35))
                    .buttonStyle(.plain)
                Spacer()
                Button("Save") {
                    guard !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    SessionManager.shared.addNote(noteText)
                    noteText = ""; inputMode = .none
                }
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color(hex: "#818CF8").opacity(0.85)).cornerRadius(6)
                .buttonStyle(.plain)
                .opacity(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11))
        .overlay(Rectangle().frame(height: 0.5)
            .foregroundColor(Color.white.opacity(0.09)), alignment: .top)
    }

    // MARK: - Deviation Form

    private var devForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header + severity inline
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundColor(severityColor)
                Text("Flag Deviation")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.8))
                Spacer()
                severityPicker
                Button {
                    devText = ""; devJustText = ""; devSeverity = .moderate
                    inputMode = .none
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.3))
                }.buttonStyle(.plain)
            }

            // What deviated
            fieldLabel("What deviated from spec")
            textArea(text: $devText,
                     placeholder: "e.g. PCB layout changed without schematic update",
                     borderColor: severityColor.opacity(0.5), minH: 56)

            // Justification
            fieldLabel("Justification (optional)")
            textArea(text: $devJustText,
                     placeholder: "Why was this done? What is the impact?",
                     borderColor: Color.white.opacity(0.15), minH: 44)

            HStack {
                Button("Cancel") {
                    devText = ""; devJustText = ""; devSeverity = .moderate
                    inputMode = .none
                }
                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.35))
                .buttonStyle(.plain)
                Spacer()
                Button("Save Deviation") {
                    guard !devText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    var dev = Deviation(description: devText, severity: devSeverity)
                    dev.justification = devJustText
                    dev.confirmed     = !devJustText.isEmpty
                    SessionManager.shared.currentSession?.deviations.append(dev)
                    let note = "⚠️ [\(devSeverity.rawValue)] \(devText)"
                        + (devJustText.isEmpty ? "" : " — \(devJustText)")
                    SessionManager.shared.addNote(note, type: .deviation)
                    devText = ""; devJustText = ""; devSeverity = .moderate
                    inputMode = .none
                }
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(severityColor.opacity(0.85)).cornerRadius(6)
                .buttonStyle(.plain)
                .opacity(devText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                .disabled(devText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11))
        .overlay(Rectangle().frame(height: 0.5)
            .foregroundColor(Color.white.opacity(0.09)), alignment: .top)
    }

    // MARK: - Reusable form components

    private func formHeader(_ title: String, icon: String, iconColor: Color,
                            onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(iconColor)
            Text(title).font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.8))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.3))
            }.buttonStyle(.plain)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(Color.white.opacity(0.35))
            .tracking(0.4)
    }

    private func textArea(text: Binding<String>, placeholder: String,
                          borderColor: Color, minH: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.12, green: 0.14, blue: 0.18))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 1))
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.22))
                    .padding(.horizontal, 10).padding(.top, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(minHeight: minH, maxHeight: minH + 40)
                // ✅ WindowKeyMaker on every text area
                .background(WindowKeyMaker())
        }
    }

    private var severityPicker: some View {
        HStack(spacing: 0) {
            ForEach(Deviation.Severity.allCases, id: \.self) { s in
                Button(s.rawValue) { devSeverity = s }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(devSeverity == s ? .white : Color.white.opacity(0.4))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(devSeverity == s ? severityColor(for: s).opacity(0.7) : Color.clear)
            }
        }
        .background(Color.white.opacity(0.07)).cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    }

    private var severityColor: Color { severityColor(for: devSeverity) }
    private func severityColor(for s: Deviation.Severity) -> Color {
        switch s {
        case .minor:    return Color(hex: "#3B82F6")
        case .moderate: return Color(hex: "#F59E0B")
        case .major:    return Color(hex: "#F87171")
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 32)
            Image(systemName: "waveform").font(.system(size: 20))
                .foregroundColor(Color.white.opacity(0.10))
            Text("Watching for changes…")
                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.20))
            Text("File saves appear here automatically.")
                .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.13))
                .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }

    private var noSessionState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "hexagon").font(.system(size: 26, weight: .light))
                .foregroundColor(Color.white.opacity(0.09))
            Text("No active session")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.white.opacity(0.25))
            Text("Open a CAD app to begin.").font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.15))
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return s < 3600
            ? String(format: "%d:%02d", s / 60, s % 60)
            : String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

