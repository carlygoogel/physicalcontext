// Detection/AppMonitor.swift — Physical Context

import AppKit

final class AppMonitor {
    static let shared = AppMonitor()
    private init() {}

    private var observers: [Any] = []

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
        guard SessionManager.shared.currentSession == nil else { return }

        StartSessionWindowController.shared.show(app: cad) { confirmed in
            guard confirmed else { return }
            SessionManager.shared.startSession(for: cad)
        }
    }

    private func handleTerminated(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier,
              knownCADApps.contains(where: { $0.bundleID == id })
        else { return }
        guard SessionManager.shared.currentSession != nil else { return }
        // Dismiss any lingering prompt first
        StartSessionWindowController.shared.dismiss()
        SessionManager.shared.endSession()
    }
}
