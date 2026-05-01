// Detection/FSEventWatcher.swift — Physical Context

import Foundation
import CoreServices

// MARK: - Change event

struct FileChangeEvent {
    let path:        String
    let fileName:    String
    let changeType:  ChangeKind
    let description: String
    let timestamp:   Date

    enum ChangeKind {
        case save, componentAdded, componentRemoved, netChanged
        case traceAdded, schematicChanged, codeChanged, unknown
    }
}

// MARK: - Watcher

final class FSEventWatcher {

    var onFileChanged: ((FileChangeEvent) -> Void)?

    private var stream:        FSEventStreamRef?
    private var watchedDirs:   Set<String> = []
    private var snapshots:     [String: FileSnapshot] = [:]
    private var lastEventTime: [String: Date] = [:]

    private let queue = DispatchQueue(label: "com.physicalcontext.fsevents", qos: .utility)

    // MARK: - Public

    func watch(directories: [String]) {
        let fresh = Set(directories).subtracting(watchedDirs)
        guard !fresh.isEmpty else { return }
        watchedDirs.formUnion(fresh)
        restartStream()
    }

    func stopWatching() {
        tearDownStream()
        watchedDirs   = []
        snapshots     = [:]
        lastEventTime = [:]
    }

    // MARK: - Stream lifecycle

    private func restartStream() {
        tearDownStream()
        guard !watchedDirs.isEmpty else { return }

        let pathsArray = Array(watchedDirs) as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |  // CFArray paths, safe to bridge
            kFSEventStreamCreateFlagFileEvents |  // file-level events
            kFSEventStreamCreateFlagNoDefer
        )

        var ctx = FSEventStreamContext(
            version: 0,
            info:    Unmanaged.passUnretained(self).toOpaque(),
            retain:  { info -> UnsafeRawPointer? in
                guard let info else { return nil }
                _ = Unmanaged<FSEventWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FSEventWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, rawInfo, count, rawPaths, rawFlags, _) in
                guard let rawInfo else { return }
                let watcher = Unmanaged<FSEventWatcher>.fromOpaque(rawInfo).takeUnretainedValue()
                let cfPaths = unsafeBitCast(rawPaths, to: CFArray.self)
                guard let paths = cfPaths as? [String] else { return }
                let flagBuf = UnsafeBufferPointer(start: rawFlags, count: count)
                for (path, flag) in zip(paths, flagBuf) {
                    watcher.handleEvent(path: path, flag: FSEventStreamEventFlags(flag))
                }
            },
            &ctx, pathsArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.8, flags
        ) else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func tearDownStream() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    // MARK: - Event handling

    private func handleEvent(path: String, flag: FSEventStreamEventFlags) {
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let created  = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        guard flag & (modified | created) != 0 else { return }

        let now = Date()
        // KiCad auto-saves rapidly — use a longer debounce window so we don't
        // flood the timeline with duplicate "layout change" entries.
        let debounceWindow: TimeInterval = ["kicad_pcb","kicad_sch","kicad_pro"]
            .contains(URL(fileURLWithPath: path).pathExtension.lowercased()) ? 3.5 : 1.5
        if let last = lastEventTime[path], now.timeIntervalSince(last) < debounceWindow { return }
        lastEventTime[path] = now

        let url      = URL(fileURLWithPath: path)
        let ext      = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent

        guard isTracked(ext), !isIgnored(fileName, ext: ext) else { return }
        analyzeChange(path: path, ext: ext, fileName: fileName, timestamp: now)
    }

    // MARK: - Change analysis

    private func analyzeChange(path: String, ext: String, fileName: String, timestamp: Date) {

        // ─── KiCad text files ───────────────────────────────────────────────
        // ⚠️ NEVER use git diff for .kicad_pcb / .kicad_sch.
        // These files store absolute coordinates for every pad, arc, and text
        // element inside every footprint. Moving ONE component rewrites all
        // those coordinates → git reports hundreds/thousands of line changes
        // for what is semantically just a positional update.
        // Our S-expression parser is far more accurate: it diffs component
        // references, nets, and trace counts — ignoring coordinate noise.
        switch ext {
        case "kicad_pcb":
            analyzeKiCadPCB(path: path, fileName: fileName, ts: timestamp)
            return
        case "kicad_sch":
            analyzeKiCadSch(path: path, fileName: fileName, ts: timestamp)
            return
        case "kicad_pro":
            emit(path: path, fileName: fileName,
                 description: "KiCad project settings updated", type: .save, ts: timestamp)
            return
        default:
            break
        }

        // ─── Binary EDA files (Altium, SolidWorks) ─────────────────────────
        // These are not human-readable so we can't parse them.
        // git diff --stat is the only meaningful signal here.
        let binaryExts: Set<String> = ["pcbdoc","schdoc","prjpcb","outjob",
                                        "sldprt","sldasm","slddrw"]
        if binaryExts.contains(ext) {
            if let gitDir = findGitDir(from: path),
               let summary = runGitDiff(repoDir: gitDir, file: path) {
                emit(path: path, fileName: fileName,
                     description: summary, type: .save, ts: timestamp)
            } else {
                let snap    = snapshots[path]
                let current = FileSnapshot(path: path)
                let delta   = current.size - (snap?.size ?? current.size)
                emit(path: path, fileName: fileName,
                     description: "Saved \(fileName) (\(delta >= 0 ? "+" : "")\(delta) bytes)",
                     type: .save, ts: timestamp)
                snapshots[path] = current
            }
            return
        }

        // ─── Code / text files (.py, .swift, .c, etc.) ──────────────────────
        // git diff is perfectly suited here — line counts mean something real.
        if let gitDir = findGitDir(from: path),
           let summary = runGitDiff(repoDir: gitDir, file: path) {
            emit(path: path, fileName: fileName,
                 description: summary, type: .codeChanged, ts: timestamp)
            snapshots[path] = FileSnapshot(path: path)
            return
        }

        // Fallback: size delta
        let snap    = snapshots[path]
        let current = FileSnapshot(path: path)
        let delta   = current.size - (snap?.size ?? current.size)
        emit(path: path, fileName: fileName,
             description: "Saved \(fileName) (\(delta >= 0 ? "+" : "")\(delta) bytes)",
             type: .save, ts: timestamp)
        snapshots[path] = current
    }

    // MARK: - KiCad PCB parser (.kicad_pcb S-expression)

    private func analyzeKiCadPCB(path: String, fileName: String, ts: Date) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            emit(path: path, fileName: fileName,
                 description: "Saved PCB: \(fileName)", type: .save, ts: ts); return
        }
        let current = KiCadPCBSnapshot(content: content)
        let prev    = snapshots[path]?.kicadPCB
        var parts   = [String]()

        if let prev {
            let added   = current.footprints.subtracting(prev.footprints)
            let removed = prev.footprints.subtracting(current.footprints)
            if !added.isEmpty   { parts.append("Added: \(added.prefix(3).joined(separator: ", "))") }
            if !removed.isEmpty { parts.append("Removed: \(removed.prefix(3).joined(separator: ", "))") }

            let nA = current.nets.subtracting(prev.nets)
            let nR = prev.nets.subtracting(current.nets)
            if !nA.isEmpty { parts.append("New nets: \(nA.prefix(3).joined(separator: ", "))") }
            if !nR.isEmpty { parts.append("Removed nets: \(nR.prefix(2).joined(separator: ", "))") }

            // Only report trace delta if it's a meaningful routing change (> 4 segments)
            let td = current.traceCount - prev.traceCount
            if abs(td) > 4 {
                parts.append(td > 0 ? "+\(td) trace segments" : "\(td) trace segments")
            }

            let zd = current.zoneCount - prev.zoneCount
            if zd != 0 { parts.append(zd > 0 ? "+\(zd) copper zone(s)" : "Removed \(abs(zd)) copper zone(s)") }
        }

        let desc = parts.isEmpty ? "Saved PCB: \(fileName) (position/property change)" : parts.joined(separator: " · ")
        let type: FileChangeEvent.ChangeKind = parts.isEmpty ? .save
            : (parts.contains(where: { $0.contains("Added") || $0.contains("Removed") }) ? .componentAdded : .traceAdded)

        emit(path: path, fileName: fileName, description: desc, type: type, ts: ts)
        var snap = FileSnapshot(path: path); snap.kicadPCB = current; snapshots[path] = snap
    }

    // MARK: - KiCad Schematic parser (.kicad_sch)

    private func analyzeKiCadSch(path: String, fileName: String, ts: Date) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            emit(path: path, fileName: fileName,
                 description: "Saved schematic: \(fileName)", type: .save, ts: ts); return
        }
        let current = KiCadSchSnapshot(content: content)
        let prev    = snapshots[path]?.kicadSch
        var parts   = [String]()

        if let prev {
            let added   = current.symbols.subtracting(prev.symbols)
            let removed = prev.symbols.subtracting(current.symbols)
            if !added.isEmpty   { parts.append("Added: \(added.prefix(3).joined(separator: ", "))") }
            if !removed.isEmpty { parts.append("Removed: \(removed.prefix(3).joined(separator: ", "))") }

            let wd = current.wireCount - prev.wireCount
            if abs(wd) > 1 { parts.append(wd > 0 ? "+\(wd) wire segments" : "\(wd) wire segments") }

            let newLabels = current.labels.subtracting(prev.labels)
            if !newLabels.isEmpty {
                parts.append("New labels: \(newLabels.prefix(3).joined(separator: ", "))")
            }
        }

        let desc = parts.isEmpty ? "Saved schematic: \(fileName) (layout change)" : parts.joined(separator: " · ")
        emit(path: path, fileName: fileName, description: desc, type: .schematicChanged, ts: ts)
        var snap = FileSnapshot(path: path); snap.kicadSch = current; snapshots[path] = snap
    }

    // MARK: - Git diff (binary/code only)

    private func findGitDir(from path: String) -> String? {
        var dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(".git").path) { return dir.path }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func runGitDiff(repoDir: String, file: String) -> String? {
        let proc = Process()
        proc.executableURL       = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments           = ["diff", "HEAD", "--stat", "--", file]
        proc.currentDirectoryURL = URL(fileURLWithPath: repoDir)
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !out.isEmpty else { return nil }
        let lines = out.components(separatedBy: "\n").filter { !$0.isEmpty }
        if let last = lines.last, last.contains("changed") {
            return "git: \(last.trimmingCharacters(in: .whitespaces))"
        }
        return nil
    }

    // MARK: - Helpers

    private func emit(path: String, fileName: String, description: String,
                      type: FileChangeEvent.ChangeKind, ts: Date) {
        let e = FileChangeEvent(path: path, fileName: fileName,
                                changeType: type, description: description, timestamp: ts)
        DispatchQueue.main.async { self.onFileChanged?(e) }
    }

    private func isTracked(_ ext: String) -> Bool {
        // KiCad text
        let kicad: Set<String> = ["kicad_pcb", "kicad_sch", "kicad_pro"]
        // Binary EDA
        let eda: Set<String>   = ["pcbdoc", "schdoc", "prjpcb", "outjob",
                                   "sldprt", "sldasm", "slddrw"]
        // Code/text
        let code: Set<String>  = ["c", "cpp", "h", "hpp", "py", "rs", "go",
                                   "ts", "swift", "yaml", "toml", "json"]
        return kicad.contains(ext) || eda.contains(ext) || code.contains(ext)
    }

    /// Official KiCad .gitignore patterns (github/gitignore + KiCad docs)
    /// plus standard backup/temp patterns for all tools.
    private func isIgnored(_ name: String, ext: String) -> Bool {
        // Hidden files
        if name.hasPrefix(".") { return true }

        // ── KiCad-specific ignores (from github/gitignore KiCad.gitignore) ──
        let kicadIgnoredExts: Set<String> = [
            "kicad_pcb-bak",   // PCB backup
            "kicad_sch-bak",   // Schematic backup
            "kicad_pro-bak",   // Project backup
            "kicad_prl",       // Local project settings (not design-critical)
            "net",             // Netlist export
            "dsn",             // Specctra design (autorouter export)
            "ses",             // Specctra session (autorouter result)
        ]
        if kicadIgnoredExts.contains(ext) { return true }

        // fp-info-cache, *.000, *.tmp, *~
        let ignoredNames: Set<String> = ["fp-info-cache"]
        if ignoredNames.contains(name) { return true }

        // Pattern-based ignores
        let ignoredPatterns = [
            "-bak", ".bak", ".tmp", "-autosave", "~",
            "_autosave-", "#auto_saved", "-save.pro",
            "-save.kicad_pcb", ".lck", "-backups"
        ]
        if ignoredPatterns.contains(where: { name.contains($0) }) { return true }

        // KiCad 6+ archived backups folder (*-backups/*.zip)
        if name.hasSuffix(".zip") { return true }

        // KiCad 9.0 local history directory
        if name == ".history" { return true }

        return false
    }
}

// MARK: - KiCad PCB S-expression snapshot

struct KiCadPCBSnapshot {
    var footprints: Set<String> = []
    var nets:       Set<String> = []
    var traceCount: Int         = 0
    var zoneCount:  Int         = 0

    init(content: String) {
        let fpRe  = try? NSRegularExpression(pattern: #"\(footprint\s+"([^"]+)""#)
        let netRe = try? NSRegularExpression(pattern: #"\(net\s+\d+\s+"([^"]+)""#)
        let range = NSRange(content.startIndex..., in: content)

        fpRe?.matches(in: content, range: range).forEach {
            if let r = Range($0.range(at: 1), in: content) {
                let ref = String(content[r]).components(separatedBy: ":").last ?? ""
                if !ref.isEmpty { footprints.insert(ref) }
            }
        }
        netRe?.matches(in: content, range: range).forEach {
            if let r = Range($0.range(at: 1), in: content) {
                let n = String(content[r])
                if !n.hasPrefix("Net-(") && !n.isEmpty { nets.insert(n) }
            }
        }
        traceCount = content.components(separatedBy: "\n(segment ").count - 1
        zoneCount  = content.components(separatedBy: "\n(zone ").count - 1
    }
}

// MARK: - KiCad Schematic S-expression snapshot

struct KiCadSchSnapshot {
    var symbols:   Set<String> = []
    var wireCount: Int         = 0
    var labels:    Set<String> = []

    init(content: String) {
        let symRe   = try? NSRegularExpression(pattern: #"\(symbol\s+\(lib_id\s+"([^"]+)""#)
        let labelRe = try? NSRegularExpression(pattern: #"\(label\s+"([^"]+)""#)
        let range   = NSRange(content.startIndex..., in: content)

        symRe?.matches(in: content, range: range).forEach {
            if let r = Range($0.range(at: 1), in: content) {
                let ref = String(content[r]).components(separatedBy: ":").last ?? ""
                if !ref.isEmpty { symbols.insert(ref) }
            }
        }
        labelRe?.matches(in: content, range: range).forEach {
            if let r = Range($0.range(at: 1), in: content) { labels.insert(String(content[r])) }
        }
        wireCount = content.components(separatedBy: "\n(wire ").count - 1
    }
}

// MARK: - File snapshot

struct FileSnapshot {
    let path: String; let size: Int64; let mtime: Date
    var kicadPCB: KiCadPCBSnapshot?; var kicadSch: KiCadSchSnapshot?

    init(path: String) {
        self.path  = path
        let attrs  = try? FileManager.default.attributesOfItem(atPath: path)
        self.size  = attrs?[.size]             as? Int64 ?? 0
        self.mtime = attrs?[.modificationDate] as? Date  ?? Date()
    }
}
