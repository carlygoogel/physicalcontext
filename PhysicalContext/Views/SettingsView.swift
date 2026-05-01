import SwiftUI

struct SettingsView: View {
    @ObservedObject private var sessionManager = SessionManager.shared

    @AppStorage("autoStartSession") private var autoStart       = true
    @AppStorage("trackSaves")       private var trackSaves      = true
    @AppStorage("devThreshold")     private var devThreshold    = "moderate"
    @AppStorage("specFilePath")     private var specFilePath    = ""

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Form {
                Section {
                    Toggle("Auto-start session when CAD app opens", isOn: $autoStart)
                    Toggle("Track ⌘S save events",                  isOn: $trackSaves)
                } header: {
                    Text("General").font(Theme.mono(10, .semibold)).foregroundColor(Theme.textTertiary)
                }

                Section {
                    Picker("Flag deviations at", selection: $devThreshold) {
                        Text("Minor").tag("minor")
                        Text("Moderate").tag("moderate")
                        Text("Major only").tag("major")
                    }
                    HStack {
                        TextField("Path to spec (.pdf, .md)", text: $specFilePath)
                            .font(Theme.sans(12)).textFieldStyle(.plain)
                        Button("Browse") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.pdf, .plainText]
                            if panel.runModal() == .OK, let url = panel.url {
                                specFilePath = url.path
                            }
                        }.buttonStyle(GhostButtonStyle())
                    }
                } header: {
                    Text("Deviation Tracking")
                        .font(Theme.mono(10, .semibold)).foregroundColor(Theme.textTertiary)
                }

                Section {
                    HStack {
                        Text("\(sessionManager.allSessions.count) sessions stored")
                            .font(Theme.sans(12)).foregroundColor(Theme.textSecondary)
                        Spacer()
                        Button("Clear All") {
                            sessionManager.allSessions = []
                            StorageManager.shared.saveSessions([])
                        }.buttonStyle(DangerButtonStyle())
                    }
                } header: {
                    Text("Data").font(Theme.mono(10, .semibold)).foregroundColor(Theme.textTertiary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 440, height: 380)
    }
}
