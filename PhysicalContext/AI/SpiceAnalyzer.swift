// AI/SpiceAnalyzer.swift — Physical Context
//
// Calls run_spice.py via Process() and parses the JSON result.
// Accepts .asc (LTSpice schematic), .net, .cir, .sp (SPICE netlists).
// No Altium Designer required.

import Foundation

// MARK: - Result models

// Per-node waveform extremes from the .raw file
struct RawTrace: Codable {
    let max: Double
    let min: Double
    let avg: Double
}

struct SpiceAnalysisResult: Codable {
    var status:         String
    var file:           String?
    var simulator:      String?
    var elapsedS:       Double?
    var summary:        String
    var violations:     [SpiceViolation]
    var measurements:   [String: Double]    // .MEAS scalar results
    var rawTraces:      [String: RawTrace]  // per-node max/min/avg waveform data
    var warnings:       [String]
    var componentInfo:  [String: String]?   // sim_type, node_count, etc.

    enum CodingKeys: String, CodingKey {
        case status, file, simulator, summary, violations, measurements, warnings
        case elapsedS       = "elapsed_s"
        case rawTraces      = "raw_traces"
        case componentInfo  = "component_info"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status       = try c.decode(String.self,             forKey: .status)
        file         = try c.decodeIfPresent(String.self,    forKey: .file)
        simulator    = try c.decodeIfPresent(String.self,    forKey: .simulator)
        elapsedS     = try c.decodeIfPresent(Double.self,    forKey: .elapsedS)
        summary      = try c.decode(String.self,             forKey: .summary)
        violations   = (try? c.decode([SpiceViolation].self, forKey: .violations)) ?? []
        warnings     = (try? c.decode([String].self,         forKey: .warnings))   ?? []
        rawTraces    = (try? c.decode([String: RawTrace].self, forKey: .rawTraces)) ?? [:]
        componentInfo = try? c.decode([String: String].self, forKey: .componentInfo)

        var meas = [String: Double]()
        if let raw = try? c.decode([String: AnyCodable].self, forKey: .measurements) {
            for (k, v) in raw { if let d = v.doubleValue { meas[k] = d } }
        }
        measurements = meas
    }

    init(status: String, file: String? = nil, simulator: String? = nil,
         elapsedS: Double? = nil, summary: String,
         violations: [SpiceViolation], measurements: [String: Double],
         rawTraces: [String: RawTrace] = [:], warnings: [String],
         componentInfo: [String: String]? = nil) {
        self.status = status; self.file = file; self.simulator = simulator
        self.elapsedS = elapsedS; self.summary = summary
        self.violations = violations; self.measurements = measurements
        self.rawTraces = rawTraces; self.warnings = warnings
        self.componentInfo = componentInfo
    }
}

struct SpiceViolation: Codable, Identifiable {
    var id:        UUID    = UUID()
    var type:      String
    var node:      String?
    var value:     Double?
    var limit:     Double?
    var severity:  String
    var message:   String

    enum CodingKeys: String, CodingKey {
        case type, node, value, limit, severity, message
    }
}

// Flexible JSON value for mixed-type measurement map
private struct AnyCodable: Codable {
    let doubleValue: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self)  { doubleValue = d; return }
        if let s = try? c.decode(String.self)  { doubleValue = Double(s); return }
        if let i = try? c.decode(Int.self)     { doubleValue = Double(i); return }
        doubleValue = nil
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(doubleValue)
    }
}

// MARK: - SpiceAnalyzer

final class SpiceAnalyzer {
    static let shared = SpiceAnalyzer()
    private init() {}

    // MARK: - Public

    /// Analyse a saved .asc, .net, .cir, or .sp file.
    /// Completion called on the main thread.
    func analyze(ascFilePath: String,
                 completion: @escaping (SpiceAnalysisResult?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = self?.runSimulation(inputPath: ascFilePath)
            DispatchQueue.main.async { completion(result) }
        }
    }

    struct SetupStatus {
        let pythonPath:  String?
        let simPath:     String?
        let simName:     String?   // "LTSpice" | "ngspice" | nil
        let pyLTSpice:   Bool
        let kicadCLI:    String?   // path or nil

        var isReady: Bool { pythonPath != nil && simPath != nil && pyLTSpice }

        var description: String {
            var lines = [String]()
            if let p = pythonPath  { lines.append("✅ Python: \(p)") }
            else                    { lines.append("❌ Python 3 not found — brew install python") }
            if let s = simPath     { lines.append("✅ \(simName ?? "Simulator"): \(s)") }
            else                    { lines.append("❌ LTSpice not found — install from analog.com (or: brew install ngspice)") }
            lines.append(pyLTSpice ? "✅ PyLTSpice installed" : "❌ PyLTSpice missing — pip install PyLTSpice")
            if let k = kicadCLI    { lines.append("✅ kicad-cli: \(k) (SPICE export enabled)") }
            else                    { lines.append("ℹ️  kicad-cli not found — using S-expression parser or Claude fallback") }
            return lines.joined(separator: "\n")
        }
    }

    func checkSetup(completion: @escaping (SetupStatus) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let python   = self.findPython()
            let (sim, simName) = self.findSimulator()
            let hasPyLTS = python != nil && self.pyLTSpiceInstalled(python: python!)
            let kicadCLI = self.findKiCadCLI()
            DispatchQueue.main.async {
                completion(SetupStatus(pythonPath: python, simPath: sim, simName: simName,
                                       pyLTSpice: hasPyLTS, kicadCLI: kicadCLI))
            }
        }
    }

    // MARK: - Private

    private func runSimulation(inputPath: String) -> SpiceAnalysisResult? {
        guard let python = findPython() else {
            return SpiceAnalysisResult(
                status: "setup_required",
                summary: "Python 3 not found.\nInstall: brew install python",
                violations: [], measurements: [:], warnings: [])
        }
        guard let script = scriptPath() else {
            return SpiceAnalysisResult(
                status: "error",
                summary: "run_spice.py not found in app bundle",
                violations: [], measurements: [:], warnings: [])
        }

        let (output, errOutput, _) = runProcess(executable: python,
                                                 args: [script, inputPath])

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SpiceAnalysisResult(
                status: "error",
                summary: "Simulation produced no output.\nstderr: \(errOutput)",
                violations: [], measurements: [:], warnings: [])
        }

        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SpiceAnalysisResult.self, from: data)
    }

    // MARK: - Environment

    private func findPython() -> String? {
        ["/opt/homebrew/bin/python3",   // Apple Silicon Homebrew
         "/usr/local/bin/python3",       // Intel Homebrew
         "/usr/bin/python3",             // macOS system Python
         "/opt/homebrew/bin/python3.12",
         "/opt/homebrew/bin/python3.11",
        ].first { FileManager.default.fileExists(atPath: $0) }
    }

    private func findSimulator() -> (String?, String?) {
        let ltPaths = [
            "/Applications/LTspice.app/Contents/MacOS/LTspice",
            "/Applications/LTSpiceXVII.app/Contents/MacOS/LTSpiceXVII",
        ]
        if let p = ltPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return (p, "LTSpice")
        }
        let ngPaths = ["/opt/homebrew/bin/ngspice", "/usr/local/bin/ngspice", "/usr/bin/ngspice"]
        if let p = ngPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return (p, "ngspice")
        }
        return (nil, nil)
    }

    private func findKiCadCLI() -> String? {
        ["/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli",
         "/Applications/KiCad.app/Contents/MacOS/kicad-cli",
         "/opt/homebrew/bin/kicad-cli",
         "/usr/local/bin/kicad-cli",
        ].first { FileManager.default.fileExists(atPath: $0) }
    }

    private func pyLTSpiceInstalled(python: String) -> Bool {
        let (out, _, _) = runProcess(executable: python,
                                      args: ["-c", "import PyLTSpice; print('ok')"])
        return out.contains("ok")
    }

    private func scriptPath() -> String? {
        if let p = Bundle.main.path(forResource: "run_spice", ofType: "py") { return p }
        let exe   = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .deletingLastPathComponent()
        let devP  = exe.appendingPathComponent("run_spice.py").path
        let resP  = exe.appendingPathComponent("Resources/run_spice.py").path
        return [devP, resP].first { FileManager.default.fileExists(atPath: $0) }
    }

    private func runProcess(executable: String, args: [String],
                             timeout: TimeInterval = 120) -> (String, String, Int32) {
        let proc = Process()
        let out  = Pipe(); let err = Pipe()
        proc.executableURL  = URL(fileURLWithPath: executable)
        proc.arguments      = args
        proc.standardOutput = out; proc.standardError = err
        proc.environment    = ProcessInfo.processInfo.environment
        do { try proc.run() } catch { return ("", "\(error)", -1) }
        let dead = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < dead { Thread.sleep(forTimeInterval: 0.5) }
        if proc.isRunning { proc.terminate() }
        proc.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (o, e, proc.terminationStatus)
    }
}

// MARK: - SessionManager integration

extension SessionManager {

    func runSpiceAnalysis(ascFilePath: String) {
        guard currentSession != nil else { return }
        let name = URL(fileURLWithPath: ascFilePath).lastPathComponent
        addChange("⚡ Running simulation: \(name)", file: name, type: .save)

        SpiceAnalyzer.shared.analyze(ascFilePath: ascFilePath) { [weak self] result in
            guard let self, let result else { return }
            self.handleSpiceResult(result, filePath: ascFilePath)
        }
    }

    private func handleSpiceResult(_ result: SpiceAnalysisResult, filePath: String) {
        let name = URL(fileURLWithPath: filePath).lastPathComponent
        let sim  = result.simulator ?? "simulator"

        switch result.status {
        case "setup_required":
            addChange("⚙️ \(result.summary)", type: .save)

        case "error":
            addChange("❌ Simulation error (\(name)): \(result.summary)", type: .save)

        case "ok":
            let t = result.elapsedS.map { String(format: " (%.1fs)", $0) } ?? ""
            addChange("✅ \(sim)\(t) — \(name): no violations", file: name, type: .save)

        default:
            let t = result.elapsedS.map { String(format: " (%.1fs)", $0) } ?? ""
            addChange("⚡ \(sim)\(t) — \(result.violations.count) issue(s) in \(name)",
                      file: name, type: .save)
            for v in result.violations {
                let sev: Deviation.Severity
                switch v.severity {
                case "major":    sev = .major
                case "moderate": sev = .moderate
                default:         sev = .minor
                }
                var dev = Deviation(description: v.message, severity: sev)
                dev.confirmed = false
                currentSession?.deviations.append(dev)
                let detail = v.value.map { " (measured: \(String(format: "%.4g", $0)))" } ?? ""
                addNote("⚡ [\(v.severity.uppercased())] \(v.message)\(detail)", type: .deviation)
            }
        }
        autoSave()
    }

    fileprivate func autoSave() {
        var snap = allSessions
        if let c = currentSession { snap.insert(c, at: 0) }
        StorageManager.shared.saveSessions(snap)
    }
}
