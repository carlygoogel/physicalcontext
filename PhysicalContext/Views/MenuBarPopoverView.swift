import SwiftUI

struct MenuBarPopoverView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @State private var showAllSessions = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "cpu")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.accent)
                    Text("Physical Context")
                        .font(Theme.sans(13, .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    if let session = sessionManager.currentSession {
                        PulseDot(color: Theme.success)
                        Text("Active")
                            .font(Theme.mono(10))
                            .foregroundColor(Theme.success)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().background(Theme.border)

                // Active session card
                if let session = sessionManager.currentSession {
                    activeSessionCard(session)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                } else {
                    noSessionCard
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }

                // Recent sessions
                if !sessionManager.allSessions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("RECENT")
                                .font(Theme.mono(9, .semibold))
                                .foregroundColor(Theme.textTertiary)
                                .tracking(1.2)
                            Spacer()
                            Button("View all") {
                                (NSApp.delegate as? AppDelegate)?.showAllSessions()
                            }
                            .font(Theme.sans(11))
                            .foregroundColor(Theme.accent)
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                        .padding(.bottom, 8)

                        ForEach(sessionManager.allSessions.prefix(4)) { session in
                            SessionRowCompact(session: session)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 4)
                        }
                    }
                }

                Spacer()

                Divider().background(Theme.border)

                // Footer
                HStack {
                    Button {
                        (NSApp.delegate as? AppDelegate)?.showAllSessions()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                                .font(.system(size: 11))
                            Text("All Sessions")
                                .font(Theme.sans(11))
                        }
                        .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 320, height: 480)
    }

    // MARK: - Active session card

    private func activeSessionCard(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.appName)
                        .font(Theme.sans(13, .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Started \(session.startTime, style: .relative) ago")
                        .font(Theme.sans(10))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Button("End") {
                    sessionManager.endSession()
                }
                .buttonStyle(DangerButtonStyle())
            }

            HStack(spacing: 8) {
                miniStat(icon: "arrow.down.circle", value: "\(session.changes.count)", label: "saves")
                miniStat(icon: "text.alignleft", value: "\(session.notes.count)", label: "notes")
                if session.deviations.count > 0 {
                    miniStat(icon: "exclamationmark.triangle", value: "\(session.deviations.count)", label: "deviations", color: Theme.warning)
                }
            }

            Button {
                sessionManager.togglePanel()
            } label: {
                HStack {
                    Image(systemName: sessionManager.isPanelVisible ? "sidebar.right" : "sidebar.right")
                        .font(.system(size: 11))
                    Text(sessionManager.isPanelVisible ? "Hide Panel" : "Show Panel")
                        .font(Theme.sans(12, .medium))
                }
                .foregroundColor(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Theme.accentDim)
                .cornerRadius(7)
            }
            .buttonStyle(.plain)
        }
        .surfaceCard(14)
    }

    private var noSessionCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(Theme.textTertiary)
            Text("No active session")
                .font(Theme.sans(13, .medium))
                .foregroundColor(Theme.textSecondary)
            Text("Open KiCad, Altium, Fusion 360, or VS Code to start tracking.")
                .font(Theme.sans(11))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .surfaceCard(16)
    }

    private func miniStat(icon: String, value: String, label: String, color: Color = Theme.textSecondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(color)
            Text(value)
                .font(Theme.mono(10, .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(label)
                .font(Theme.sans(10))
                .foregroundColor(Theme.textSecondary)
        }
    }
}

// MARK: - Compact session row for popover

struct SessionRowCompact: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: sfSymbol(for: session.appBundleID))
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(Theme.surface)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(session.appName)
                    .font(Theme.sans(11, .medium))
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 4) {
                    Text(session.startTime, style: .date)
                    Text("·")
                    Text(session.durationString)
                }
                .font(Theme.mono(9))
                .foregroundColor(Theme.textTertiary)
            }

            Spacer()

            HStack(spacing: 6) {
                if !session.deviations.isEmpty {
                    TagView(label: "\(session.deviations.count)", color: Theme.warning)
                }
                Text("\(session.changes.count) saves")
                    .font(Theme.mono(9))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(10)
        .background(Theme.surface)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
    }

    private func sfSymbol(for bundleID: String) -> String {
        knownCADApps.first { $0.bundleID == bundleID }?.sfSymbol ?? "app"
    }
}
