// Detection/AppMonitor.swift — Physical Context

import AppKit

final class AppMonitor {
    static let shared = AppMonitor()
    private init() {}

    private var observers:    [Any] = []
    // Apps the user pressed "Later" on — cleared only when the app quits
    private var dismissedIDs: Set<String> = []
    // Apps currently running that we've already prompted for this launch
    private var promptedIDs:  Set<String> = []

    func startMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter

        observers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.handleActivated(app)
        })

        observers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.handleTerminated(app)
        })
    }

    func stopMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
        observers = []
    }

    private func handleActivated(_ app: NSRunningApplication) {
        guard let id  = app.bundleIdentifier,
              let cad = knownCADApps.first(where: { $0.bundleID == id })
        else { return }

        // Already in a session — nothing to do
        guard SessionManager.shared.currentSession == nil else { return }

        // Already prompted this app during its current run (dismissed or accepted)
        guard !promptedIDs.contains(id) else { return }

        // User said "Later" for this app in a previous activation this run
        guard !dismissedIDs.contains(id) else { return }

        // Mark as prompted so re-focusing windows doesn't re-trigger
        promptedIDs.insert(id)

        StartSessionWindowController.shared.show(app: cad) { [weak self] confirmed in
            if confirmed {
                SessionManager.shared.startSession(for: cad)
            } else {
                // User dismissed — block re-prompting until app quits and relaunches
                self?.dismissedIDs.insert(id)
            }
        }
    }

    private func handleTerminated(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier,
              knownCADApps.contains(where: { $0.bundleID == id })
        else { return }

        // Clear both sets so next launch prompts fresh
        dismissedIDs.remove(id)
        promptedIDs.remove(id)

        StartSessionWindowController.shared.dismiss()

        if SessionManager.shared.currentSession != nil {
            SessionManager.shared.endSession()
        }
    }
}
