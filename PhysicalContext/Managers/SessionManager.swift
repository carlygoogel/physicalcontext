// Session/SessionManager.swift — Physical Context

import Foundation
import AppKit
import Combine

final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published var currentSession: Session?
    @Published var allSessions:    [Session] = []
    @Published var isPanelVisible: Bool      = false

    private var globalKeyMonitor: NSObjectProtocol?
    private var titlePollTimer:   Timer?
    private var lastWindowTitle:  String = ""
    private var watchedDirs:      Set<String> = []
    private let fsWatcher = FSEventWatcher()

    private init() {
        allSessions = StorageManager.shared.loadSessions()
        DispatchQueue.main.async { [weak self] in
            self?.setupKeyMonitor()
            self?.setupFSWatcher()
        }
    }

    // MARK: - Session Lifecycle

    func startSession(for app: CADApp) {
        guard currentSession == nil else { return }
        currentSession = Session(appName: app.name,
                                 appBundleID: app.bundleID,
                                 startTime: Date())
        isPanelVisible = true
        discoverAndWatch(for: app)
        startTitlePolling()
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.showSessionPanel()
        }
    }

    @discardableResult
    func endSession() -> Session? {
        guard var session = currentSession else { return nil }
        session.endTime = Date()
        currentSession  = nil
        allSessions.insert(session, at: 0)
        StorageManager.shared.saveSessions(allSessions)
        isPanelVisible = false
        stopTitlePolling()
        watchedDirs = []
        fsWatcher.stopWatching()
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.hideSessionPanel()
            (NSApp.delegate as? AppDelegate)?.showSessionSummary(session: session)
        }
        return session
    }

    // MARK: - Notes & Changes

    func addNote(_ content: String, type: Note.NoteType = .manual) {
        guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        currentSession?.notes.append(Note(content: content, type: type))
        autoSave()
    }

    func addChange(_ description: String, file: String? = nil,
                   type: Change.ChangeType = .save) {
        let c = Change(description: description, file: file, changeType: type)
        currentSession?.changes.append(c)
        autoSave()
    }

    func addDeviation(_ description: String, severity: Deviation.Severity = .moderate) {
        currentSession?.deviations.append(
            Deviation(description: description, severity: severity))
        addNote("⚠️ Deviation: \(description)", type: .deviation)
    }

    func updateArchivedSession(_ session: Session) {
        guard let i = allSessions.firstIndex(where: { $0.id == session.id }) else { return }
        allSessions[i] = session
        StorageManager.shared.saveSessions(allSessions)
    }

    func deleteSession(_ session: Session) {
        allSessions.removeAll { $0.id == session.id }
        StorageManager.shared.saveSessions(allSessions)
    }

    func togglePanel() {
        isPanelVisible.toggle()
        DispatchQueue.main.async {
            if self.isPanelVisible {
                (NSApp.delegate as? AppDelegate)?.showSessionPanel()
            } else {
                (NSApp.delegate as? AppDelegate)?.hideSessionPanel()
            }
        }
    }

    // MARK: - FSEvents

    private func setupFSWatcher() {
        fsWatcher.onFileChanged = { [weak self] event in
            guard self?.currentSession != nil else { return }
            let changeType: Change.ChangeType
            switch event.changeType {
            case .save:             changeType = .save
            case .componentAdded:   changeType = .componentAdd
            case .componentRemoved: changeType = .componentRemove
            case .netChanged:       changeType = .connectionChange
            case .traceAdded:       changeType = .routeChange
            case .schematicChanged: changeType = .schematicChange
            case .codeChanged:      changeType = .codeChange
            case .unknown:          changeType = .save
            }
            self?.addChange(event.description, file: event.fileName, type: changeType)
        }
    }

    // ✅ Watch directory silently — no timeline noise from "Watching: X"
    private func watchDir(_ dir: String) {
        let expanded = (dir as NSString).expandingTildeInPath
        guard !watchedDirs.contains(expanded),
              FileManager.default.fileExists(atPath: expanded) else { return }
        watchedDirs.insert(expanded)
        fsWatcher.watch(directories: [expanded])
        // No addChange("Watching: ...") — this cluttered the timeline
    }

    // MARK: - Project Directory Discovery

    private func discoverAndWatch(for app: CADApp) {
        var dirs: [String] = []

        switch app.bundleID {
        case _ where app.bundleID.contains("kicad"):
            dirs += kicadRecentProjects()
        case _ where app.bundleID.contains("altium"):
            dirs += altiumRecentProjects()
        default: break
        }

        if let runningApp = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == app.bundleID }) {
            let title = axWindowTitle(for: runningApp)
            if let dir = dirFromTitle(title) { dirs.append(dir) }
            dirs += recentDocDirs(for: runningApp)
        }

        for url in NSDocumentController.shared.recentDocumentURLs {
            if isDesignExt(url.pathExtension.lowercased()) {
                dirs.append(url.deletingLastPathComponent().path)
            }
        }

        Array(Set(dirs))
            .filter { FileManager.default.fileExists(atPath: $0) }
            .forEach { watchDir($0) }
    }

    // MARK: - KiCad Recent Projects

    private func kicadRecentProjects() -> [String] {
        let fm   = FileManager.default
        var dirs = [String]()
        let bases = ["~/Library/Preferences/kicad",
                     "~/Library/Application Support/kicad"]
            .map { ($0 as NSString).expandingTildeInPath }

        for base in bases {
            guard fm.fileExists(atPath: base) else { continue }
            let contents = (try? fm.contentsOfDirectory(atPath: base)) ?? []
            let candidates = ["kicad.json"] + contents.map { "\($0)/kicad.json" }
            for rel in candidates {
                let path = "\(base)/\(rel)"
                guard let data = fm.contents(atPath: path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                for key in ["system", "pcbnew", "eeschema", "kicad"] {
                    if let section = json[key] as? [String: Any],
                       let history = section["file_history"] as? [String] {
                        dirs += history.map {
                            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
                                .deletingLastPathComponent().path
                        }
                    }
                }
            }
        }
        let scanDirs = ["~/Documents","~/Desktop","~/Projects","~/kicad"]
            .map { ($0 as NSString).expandingTildeInPath }
        for base in scanDirs where fm.fileExists(atPath: base) {
            let enum_ = fm.enumerator(at: URL(fileURLWithPath: base),
                                      includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants])
            if let e = enum_ {
                for case let url as URL in e {
                    if url.pathExtension.lowercased() == "kicad_pro" {
                        dirs.append(url.deletingLastPathComponent().path)
                    }
                    let depth = url.pathComponents.count
                        - URL(fileURLWithPath: base).pathComponents.count
                    if depth > 4 { e.skipDescendants() }
                }
            }
        }
        return dirs
    }

    private func altiumRecentProjects() -> [String] {
        let base = ("~/Library/Preferences/Altium" as NSString).expandingTildeInPath
        var dirs = [String]()
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: base) else { return dirs }
        for file in contents where file.hasSuffix(".ini") || file.hasSuffix(".xml") {
            if let text = try? String(contentsOfFile: "\(base)/\(file)", encoding: .utf8) {
                for line in text.components(separatedBy: "\n") {
                    let parts = line.components(separatedBy: "=")
                    if parts.count == 2 {
                        let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if val.hasPrefix("/"),
                           isDesignExt(URL(fileURLWithPath: val).pathExtension.lowercased()) {
                            dirs.append(URL(fileURLWithPath: val).deletingLastPathComponent().path)
                        }
                    }
                }
            }
        }
        return dirs
    }

    // MARK: - Helpers

    private func recentDocDirs(for app: NSRunningApplication) -> [String] {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var windows: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString,
                                            &windows) == .success,
              let list = windows as? [AXUIElement] else { return [] }
        var dirs = [String]()
        for win in list.prefix(8) {
            var titleObj: AnyObject?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString,
                                             &titleObj) == .success,
               let title = titleObj as? String,
               let dir = dirFromTitle(title) { dirs.append(dir) }
        }
        return dirs
    }

    private func axWindowTitle(for app: NSRunningApplication) -> String {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var windows: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString,
                                            &windows) == .success,
              let list = windows as? [AXUIElement],
              let first = list.first else { return "" }
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(first, kAXTitleAttribute as CFString,
                                            &title) == .success,
              let t = title as? String else { return "" }
        return t
    }

    private func dirFromTitle(_ title: String) -> String? {
        let fm = FileManager.default
        if let start = title.firstIndex(of: "["),
           let end   = title.firstIndex(of: "]"), start < end {
            let inner = String(title[title.index(after: start)..<end])
            let url   = URL(fileURLWithPath: inner)
            let dir   = url.hasDirectoryPath ? url.path : url.deletingLastPathComponent().path
            if fm.fileExists(atPath: dir) { return dir }
        }
        for part in title.components(separatedBy: CharacterSet(charactersIn: "—|-")) {
            let cleaned = part.trimmingCharacters(in: .whitespaces)
            if cleaned.hasPrefix("/") {
                let url = URL(fileURLWithPath: cleaned)
                let dir = url.hasDirectoryPath ? url.path : url.deletingLastPathComponent().path
                if fm.fileExists(atPath: dir) { return dir }
            }
        }
        return nil
    }

    private func isDesignExt(_ ext: String) -> Bool {
        ["kicad_pcb","kicad_sch","kicad_pro",
         "pcbdoc","schdoc","prjpcb",
         "sldprt","sldasm","slddrw"].contains(ext)
    }

    // MARK: - Title Polling

    private func startTitlePolling() {
        titlePollTimer?.invalidate()
        titlePollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollActiveWindow()
        }
    }

    private func stopTitlePolling() {
        titlePollTimer?.invalidate(); titlePollTimer = nil
        lastWindowTitle = ""
    }

    private func pollActiveWindow() {
        guard let session = currentSession,
              let front   = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == session.appBundleID else { return }
        let title = axWindowTitle(for: front)
        guard !title.isEmpty else { return }
        if let dir = dirFromTitle(title) { watchDir(dir) }
        if title != lastWindowTitle && !lastWindowTitle.isEmpty {
            let newFile  = extractFileName(from: title)
            let prevFile = extractFileName(from: lastWindowTitle)
            if !newFile.isEmpty && newFile != prevFile {
                addChange("Opened \(newFile)", file: newFile, type: .schematicChange)
            }
        }
        lastWindowTitle = title
    }

    private func extractFileName(from title: String) -> String {
        let exts: Set<String> = ["kicad_pcb","kicad_sch","kicad_pro",
                                  "pcbdoc","schdoc","prjpcb",
                                  "sldprt","sldasm","slddrw",
                                  "swift","c","cpp","h","py","rs","go","ts"]
        for part in title.components(separatedBy: CharacterSet(charactersIn: " —-|/\\")) {
            let t = part.trimmingCharacters(in: .whitespaces)
            if exts.contains(URL(fileURLWithPath: t).pathExtension.lowercased()) { return t }
        }
        for part in title.components(separatedBy: CharacterSet(charactersIn: " —-|/\\")) {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.contains(".") && !t.contains(" ") && t.count < 80 { return t }
        }
        return ""
    }

    // MARK: - Global Key Monitor

    private func setupKeyMonitor() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if event.modifierFlags.contains(.command) && event.keyCode == 1 {
                guard self.currentSession != nil else { return }
                DispatchQueue.main.async {
                    let file   = self.extractFileName(from: self.lastWindowTitle)
                    let desc   = file.isEmpty ? "⌘S save" : "⌘S save: \(file)"
                    let cutoff = Date().addingTimeInterval(-3)
                    let recent = self.currentSession?.changes
                        .filter { $0.changeType == .save && $0.timestamp > cutoff }
                    // Dedupe — FSEvents likely caught this already
                    if recent?.isEmpty == true {
                        self.addChange(desc, file: file.isEmpty ? nil : file, type: .save)
                    }
                }
            }
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 45 {
                DispatchQueue.main.async {
                    self.isPanelVisible = true
                    (NSApp.delegate as? AppDelegate)?.showSessionPanel()
                }
            }
        } as? NSObjectProtocol
    }

    private func autoSave() {
        var snap = allSessions
        if let c = currentSession { snap.insert(c, at: 0) }
        StorageManager.shared.saveSessions(snap)
    }
}
