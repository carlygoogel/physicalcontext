// Detection/FSEventWatcher.swift — Physical Context
//
// Change tracking per platform:
//   KiCad (.kicad_pcb, .kicad_sch) — S-expression text, fully parsed
//   Altium (.PcbDoc, .SchDoc)       — binary; size delta + git diff
//   SolidWorks (.sldprt etc.)       — binary; size delta + git diff
//   Code (.swift .py .rs etc.)      — git diff --stat when available

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

    private var stream:          FSEventStreamRef?
    private var watchedDirs:     Set<String> = []
    private var snapshots:       [String: FileSnapshot] = [:]
    private var lastEventTime:   [String: Date] = [:]

    private let queue = DispatchQueue(label: "com.physicalcontext.fsevents",
                                      qos: .utility)

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

        // ✅ kFSEventStreamCreateFlagUseCFTypes makes the callback receive
        //    a CFArray of CFString paths — safe to bridge to [String].
        //    kFSEventStreamCreateFlagFileEvents gives per-file (not per-dir) events.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        // ✅ Context info pointer holds an unretained reference to self.
        //    The retain/release callbacks manage ARC correctly so the
        //    C callback can safely call back into Swift.
        var ctx = FSEventStreamContext(
            version:         0,
            info:            Unmanaged.passUnretained(self).toOpaque(),
            retain:          { info -> UnsafeRawPointer? in
                guard let info else { return nil }
                _ = Unmanaged<FSEventWatcher>.fromOpaque(info).retain()
                return info
            },
            release:         { info in
                guard let info else { return }
                Unmanaged<FSEventWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            // ✅ C callback — no unsafe pointer arithmetic or bit casts.
            //    With kFSEventStreamCreateFlagUseCFTypes, `rawPaths` is a
            //    CFArray. We bridge it safely via `as! [String]`.
            { (_, rawInfo, count, rawPaths, rawFlags, _) in
                guard let rawInfo else { return }
                let watcher = Unmanaged<FSEventWatcher>.fromOpaque(rawInfo)
                    .takeUnretainedValue()

                // ✅ Safe bridge: CFArray of CFString → [String]
                let cfPaths  = unsafeBitCast(rawPaths, to: CFArray.self)
                guard let paths = cfPaths as? [String] else { return }

                let flagBuf  = UnsafeBufferPointer(start: rawFlags, count: count)

                for (path, flag) in zip(paths, flagBuf) {
                    watcher.handleEvent(
                        path: path,
                        flag: FSEventStreamEventFlags(flag)
                    )
                }
            },
            &ctx,
            pathsArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.8,   // latency seconds
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func tearDownStream() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    // MARK: - Event handling

    private func handleEvent(path: String, flag: FSEventStreamEventFlags) {
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let created  = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        guard flag & (modified | created) != 0 else { return }

        // Debounce: ignore duplicates within 1.5 s
        let now = Date()
        if let last = lastEventTime[path], now.timeIntervalSince(last) < 1.5 { return }
        lastEventTime[path] = now

        let url      = URL(fileURLWithPath: path)
        let ext      = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent

        guard isTracked(ext), !isIgnored(fileName) else { return }

        analyzeChange(path: path, ext: ext, fileName: fileName, timestamp: now)
    }

    // MARK: - Change analysis

    private func analyzeChange(path: String, ext: String,
                               fileName: String, timestamp: Date) {
        // Git diff always wins if available
        if let gitDir = findGitDir(from: path),
           let summary = runGitDiff(repoDir: gitDir, file: path) {
            emit(path: path, fileName: fileName,
                 description: summary, type: .save, ts: timestamp)
            snapshots[path] = FileSnapshot(path: path)
            return
        }

        switch ext {
        case "kicad_pcb":  analyzeKiCadPCB(path: path, fileName: fileName, ts: timestamp)
        case "kicad_sch":  analyzeKiCadSch(path: path, fileName: fileName, ts: timestamp)
        case "kicad_pro":
            emit(path: path, fileName: fileName,
                 description: "KiCad project settings updated",
                 type: .save, ts: timestamp)
        default:
            let snap    = snapshots[path]
            let current = FileSnapshot(path: path)
            let delta   = current.size - (snap?.size ?? current.size)
            let sign    = delta >= 0 ? "+" : ""
            emit(path: path, fileName: fileName,
                 description: "Saved \(fileName) (\(sign)\(delta) bytes)",
                 type: .save, ts: timestamp)
            snapshots[path] = current
        }
    }

    // MARK: - KiCad PCB parser

    private func analyzeKiCadPCB(path: String, fileName: String, ts: Date) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            emit(path: path, fileName: fileName,
                 description: "Saved PCB: \(fileName)", type: .save, ts: ts)
            return
        }

        let current = KiCadPCBSnapshot(content: content)
        let prev    = snapshots[path]?.kicadPCB
        var changes = [String]()

        if let prev {
            let added   = current.footprints.subtracting(prev.footprints)
            let removed = prev.footprints.subtracting(current.footprints)
            if !added.isEmpty   { changes.append("Added: \(added.prefix(3).joined(separator: ", "))") }
            if !removed.isEmpty { changes.append("Removed: \(removed.prefix(3).joined(separator: ", "))") }

            let nA = current.nets.subtracting(prev.nets)
            let nR = prev.nets.subtracting(current.nets)
            if !nA.isEmpty { changes.append("New nets: \(nA.prefix(3).joined(separator: ", "))") }
            if !nR.isEmpty { changes.append("Removed nets: \(nR.prefix(3).joined(separator: ", "))") }

            let td = current.traceCount - prev.traceCount
            if abs(td) > 2 {
                changes.append(td > 0 ? "+\(td) traces" : "\(td) traces")
            }
        }

        let desc = changes.isEmpty ? "Saved PCB: \(fileName)" : changes.joined(separator: " · ")
        let type: FileChangeEvent.ChangeKind = changes.isEmpty ? .save : .traceAdded
        emit(path: path, fileName: fileName, description: desc, type: type, ts: ts)

        var snap = FileSnapshot(path: path)
        snap.kicadPCB = current
        snapshots[path] = snap
    }

    // MARK: - KiCad Schematic parser

    private func analyzeKiCadSch(path: String, fileName: String, ts: Date) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            emit(path: path, fileName: fileName,
                 description: "Saved schematic: \(fileName)", type: .save, ts: ts)
            return
        }

        let current = KiCadSchSnapshot(content: content)
        let prev    = snapshots[path]?.kicadSch
        var changes = [String]()

        if let prev {
            let added   = current.symbols.subtracting(prev.symbols)
            let removed = prev.symbols.subtracting(current.symbols)
            if !added.isEmpty   { changes.append("Added: \(added.prefix(3).joined(separator: ", "))") }
            if !removed.isEmpty { changes.append("Removed: \(removed.prefix(3).joined(separator: ", "))") }

            let wd = current.wireCount - prev.wireCount
            if abs(wd) > 1 { changes.append(wd > 0 ? "+\(wd) wires" : "\(wd) wires") }

            let newLabels = current.labels.subtracting(prev.labels)
            if !newLabels.isEmpty {
                changes.append("Labels: \(newLabels.prefix(3).joined(separator: ", "))")
            }
        }

        let desc = changes.isEmpty ? "Saved schematic: \(fileName)" : changes.joined(separator: " · ")
        emit(path: path, fileName: fileName, description: desc, type: .schematicChanged, ts: ts)

        var snap = FileSnapshot(path: path)
        snap.kicadSch = current
        snapshots[path] = snap
    }

    // MARK: - Git

    private func findGitDir(from path: String) -> String? {
        var dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(".git").path) {
                return dir.path
            }
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
        proc.standardOutput = pipe
        proc.standardError  = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !out.isEmpty else { return nil }
        // Last line: "1 file changed, 4 insertions(+), 2 deletions(-)"
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
                                changeType: type, description: description,
                                timestamp: ts)
        DispatchQueue.main.async { self.onFileChanged?(e) }
    }

    private func isTracked(_ ext: String) -> Bool {
        ["kicad_pcb","kicad_sch","kicad_pro",
         "pcbdoc","schdoc","prjpcb","outjob",
         "sldprt","sldasm","slddrw",
         "c","cpp","h","hpp","py","rs","go","ts","swift",
         "yaml","json","toml"].contains(ext)
    }

    private func isIgnored(_ name: String) -> Bool {
        name.hasPrefix(".") ||
        ["-bak",".bak",".tmp","-autosave","~","#","-save"].contains { name.contains($0) }
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
            if let r = Range($0.range(at: 1), in: content) {
                labels.insert(String(content[r]))
            }
        }
        wireCount = content.components(separatedBy: "\n(wire ").count - 1
    }
}

// MARK: - File snapshot

struct FileSnapshot {
    let path:  String
    let size:  Int64
    let mtime: Date
    var kicadPCB: KiCadPCBSnapshot?
    var kicadSch: KiCadSchSnapshot?

    init(path: String) {
        self.path  = path
        let attrs  = try? FileManager.default.attributesOfItem(atPath: path)
        self.size  = attrs?[.size]             as? Int64 ?? 0
        self.mtime = attrs?[.modificationDate] as? Date  ?? Date()
    }
}
