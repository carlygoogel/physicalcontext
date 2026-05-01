// AI/SpiceBridge.swift — Physical Context
//
// KiCad schematic → SPICE netlist → LTSpice simulation pipeline.
// Does NOT require Altium Designer. Three escalating strategies:
//
//  1. kicad-cli (KiCad 7+) — most accurate, zero dependencies beyond KiCad
//     kicad-cli sch export netlist --format spice input.kicad_sch --output out.net
//
//  2. KiCadSExprParser — our S-expression parser, works offline, no API key
//
//  3. Claude API fallback — for complex schematics the parser can't handle
//
// LTSpice is the simulator for all three paths. Altium is NOT required.

import Foundation

extension SessionManager {

    // MARK: - Main entry point (called on every .kicad_sch save)

    func runKiCadSpiceAnalysis(schFilePath: String) {
        guard currentSession != nil else { return }

        // Throttle: one simulation per 90 s per file to avoid thrashing
        let throttleKey = "spice_last_\(schFilePath)"
        if let last = UserDefaults.standard.object(forKey: throttleKey) as? Date,
           Date().timeIntervalSince(last) < 90 { return }
        UserDefaults.standard.set(Date(), forKey: throttleKey)

        let fileName = URL(fileURLWithPath: schFilePath).lastPathComponent

        // Strategy 1: kicad-cli built-in SPICE export (KiCad 7+, most accurate)
        if let netPath = exportNetlistViaKiCadCLI(schFilePath: schFilePath) {
            addChange("⚡ Simulating \(fileName) via kicad-cli netlist export", type: .save)
            runSpiceAnalysis(ascFilePath: netPath)   // SpiceAnalyzer accepts .net too
            return
        }

        // Strategy 2: direct S-expression parser (no external tools needed)
        if let schematic = KiCadSExprParser.parse(filePath: schFilePath),
           !schematic.components.isEmpty {
            let netlist = KiCadSExprParser.generateSpiceNetlist(from: schematic)
            if let netPath = writeNetlistTemp(content: netlist, baseName: schFilePath) {
                addChange("⚡ Simulating \(schematic.summary) from \(fileName)", type: .save)
                runSpiceAnalysis(ascFilePath: netPath)
                return
            }
        }

        // Strategy 3: Claude API (handles complex ICs, subcircuits, non-trivial nets)
        let apiKey = SummaryEngine().getKey()
        guard !apiKey.isEmpty else {
            addChange("⚡ Simulation skipped — kicad-cli not found, add API key in Settings for fallback",
                      type: .save)
            return
        }
        guard let schContent = try? String(contentsOfFile: schFilePath, encoding: .utf8),
              !schContent.isEmpty else { return }

        addChange("⚡ Generating SPICE netlist via Claude (kicad-cli not found)…", type: .save)

        Task {
            do {
                let netlist = try await generateNetlistViaClaude(
                    schContent: schContent,
                    fileName:   fileName,
                    apiKey:     apiKey
                )
                guard !netlist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await MainActor.run {
                        self.addChange("⚡ Could not extract simulatable netlist from \(fileName)",
                                       type: .save)
                    }
                    return
                }
                guard let netPath = self.writeNetlistTemp(content: netlist, baseName: schFilePath) else {
                    return
                }
                await MainActor.run { self.runSpiceAnalysis(ascFilePath: netPath) }
            } catch {
                await MainActor.run {
                    self.addChange("⚡ Netlist generation failed: \(error.localizedDescription)",
                                   type: .save)
                }
            }
        }
    }

    // MARK: - Strategy 1: kicad-cli SPICE export

    /// Uses KiCad's built-in CLI tool (KiCad 7+) to export a SPICE netlist.
    /// This is the most accurate method because KiCad itself resolves the full
    /// net topology, pin mappings, and component models.
    ///
    /// Command: kicad-cli sch export netlist --format spice <sch> --output <net>
    private func exportNetlistViaKiCadCLI(schFilePath: String) -> String? {
        guard let cli = findKiCadCLI() else { return nil }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc_kicad_net", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir,
                                                  withIntermediateDirectories: true)
        let baseName = URL(fileURLWithPath: schFilePath).deletingPathExtension().lastPathComponent
        let outNet   = tmpDir.appendingPathComponent("\(baseName).net").path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = [
            "sch", "export", "netlist",
            "--format", "spice",
            schFilePath,
            "--output", outNet
        ]
        proc.standardOutput = Pipe()
        proc.standardError  = Pipe()

        do    { try proc.run() } catch { return nil }
        proc.waitUntilExit()

        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outNet) else { return nil }
        return outNet
    }

    private func findKiCadCLI() -> String? {
        let candidates = [
            // KiCad 7+ macOS app bundle (standard install)
            "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli",
            // Alternate bundle name
            "/Applications/KiCad.app/Contents/MacOS/kicad-cli",
            // Homebrew
            "/opt/homebrew/bin/kicad-cli",
            "/usr/local/bin/kicad-cli",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Strategy 3: Claude API fallback

    private func generateNetlistViaClaude(schContent: String,
                                           fileName: String,
                                           apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw SpiceBridgeError.badURL
        }

        let trimmed = schContent.count > 14_000
            ? String(schContent.prefix(14_000)) + "\n* (truncated)"
            : schContent

        // Prompt uses SPICE syntax per the published specification.
        // LTSpice, ngspice, and XYCE all accept this format.
        let prompt = """
        Convert this KiCad schematic (S-expression format) into a valid SPICE netlist \
        for simulation with LTSpice. KiCad and LTSpice are the tools in use — Altium \
        Designer is NOT installed.

        ## SPICE Netlist Format (universal, works with LTSpice/ngspice/XYCE)

        ```
        * Title line (required first line, starts with *)
        *Schematic Netlist:
        Rref  N+   N-   Value          ; e.g. R1 net_a GND 10k
        Cref  N+   N-   Value          ; e.g. C1 vcc   net_a 100nF
        Lref  N+   N-   Value          ; e.g. L1 net_a net_b 10uH
        Vref  N+   N-   DC Value       ; e.g. V1 vcc 0 DC 5
        Vref  N+   N-   SIN(Voff Vamp Freq Td Df Phase)
        Vref  N+   N-   PULSE(V0 V1 Td Tr Tf Pw Period)
        Qref  Nc   Nb   Ne   Model     ; BJT  e.g. Q1 col base emit 2N2222A
        Mref  Nd   Ng   Ns   Nb Model  ; FET
        Dref  An   Cath Model          ; Diode
        Xref  n1..nn SubcktName        ; Subcircuit

        *Selected Circuit Analyses:
        .TRAN 1n 1u          ; transient (use for circuits with C/L)
        .AC dec 100 1k 1Meg  ; AC sweep (use for amplifiers/filters)
        .OP                  ; DC operating point (use for pure resistive)

        .END                 ; REQUIRED — netlist must end here
        ```

        ## Rules
        - Output ONLY the raw netlist text, nothing else
        - Use "0" as the ground reference node
        - All node names must be consistent across all lines
        - Choose ONE simulation command that makes sense for this circuit
        - If a component has no LTSpice model, add a .subckt stub or use a generic model
        - End with .END on its own line

        ## KiCad Schematic (S-expression)
        File: \(fileName)

        \(trimmed)
        """

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 60
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model":      "claude-sonnet-4-20250514",
            "max_tokens": 3000,
            "messages":   [["role": "user", "content": prompt]]
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpiceBridgeError.apiError
        }
        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = (json["content"] as? [[String: Any]])?.first,
              let text  = block["text"] as? String else {
            throw SpiceBridgeError.parseError
        }

        // Strip accidental markdown fencing
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            let lines = result.components(separatedBy: "\n")
            result = lines
                .dropFirst()
                .prefix(while: { !$0.hasPrefix("```") })
                .joined(separator: "\n")
        }
        guard result.contains(".END") else {
            throw SpiceBridgeError.invalidNetlist("Missing .END — not a valid SPICE netlist")
        }
        return result
    }

    // MARK: - Helpers

    private func writeNetlistTemp(content: String, baseName: String) -> String? {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc_kicad_spice", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir,
                                                  withIntermediateDirectories: true)
        let name    = URL(fileURLWithPath: baseName).deletingPathExtension().lastPathComponent
        let netPath = tmpDir.appendingPathComponent("\(name)_pc.net").path
        do {
            try content.write(toFile: netPath, atomically: true, encoding: .utf8)
            return netPath
        } catch { return nil }
    }

    enum SpiceBridgeError: Error, LocalizedError {
        case badURL, apiError, parseError, invalidNetlist(String)
        var errorDescription: String? {
            switch self {
            case .badURL:                return "Invalid API URL"
            case .apiError:              return "Claude API error"
            case .parseError:            return "Failed to parse response"
            case .invalidNetlist(let m): return "Invalid netlist: \(m)"
            }
        }
    }
}
