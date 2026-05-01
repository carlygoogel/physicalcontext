// AI/SummaryEngine.swift — Physical Context

import Foundation

final class SummaryEngine {

    // MARK: - Public

    func summarize(session: Session, completion: @escaping (String) -> Void) {
        let key = getKey()
        guard !key.isEmpty else {
            DispatchQueue.main.async { completion(self.buildFallback(session: session)) }
            return
        }
        Task {
            let result = await callClaude(session: session, apiKey: key)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Structured data extraction

    /// All components added this session, extracted from Change descriptions
    private func addedComponents(from session: Session) -> [String] {
        session.changes
            .filter { $0.changeType == .componentAdd }
            .flatMap { change -> [String] in
                // Description is like "Added: R10 (10k), C4 (100nF)"
                guard let range = change.description.range(of: "Added: ") else { return [] }
                return change.description[range.upperBound...]
                    .components(separatedBy: ", ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
    }

    private func removedComponents(from session: Session) -> [String] {
        session.changes
            .filter { $0.changeType == .componentRemove }
            .flatMap { change -> [String] in
                guard let range = change.description.range(of: "Removed: ") else { return [] }
                return change.description[range.upperBound...]
                    .components(separatedBy: ", ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
    }

    private func movedComponents(from session: Session) -> [String] {
        session.changes
            .filter { $0.description.hasPrefix("Moved:") }
            .map { $0.description }
    }

    private func spiceStatus(from session: Session) -> String {
        let results = session.spiceResults
        guard !results.isEmpty else { return "No simulation run this session." }

        var lines = [String]()
        for r in results {
            let file = r.file ?? "schematic"
            let sim  = r.simulator ?? "LTSpice"
            let time = r.elapsedS.map { String(format: " in %.1fs", $0) } ?? ""
            if r.violations.isEmpty {
                lines.append("✅ \(sim) verified \(file)\(time) — circuit nominal, no DRC violations.")
            } else {
                lines.append("⚡ \(sim) found \(r.violations.count) issue(s) in \(file)\(time):")
                for v in r.violations {
                    let val = v.value.map { " (measured \(String(format: "%.4g", $0)))" } ?? ""
                    lines.append("   • [\(v.severity.uppercased())] \(v.message)\(val)")
                }
            }
            if !r.measurements.isEmpty {
                let meas = r.measurements.prefix(4)
                    .map { "\($0.key): \(String(format: "%.4g", $0.value))" }
                    .joined(separator: ", ")
                lines.append("   Measurements: \(meas)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Prompt

    private func buildPrompt(session: Session) -> String {
        let df  = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let dur = Int(session.duration / 60)

        let added   = addedComponents(from: session)
        let removed = removedComponents(from: session)
        let moved   = movedComponents(from: session)

        let componentSection: String
        if added.isEmpty && removed.isEmpty && moved.isEmpty {
            componentSection = "No component changes detected."
        } else {
            var parts = [String]()
            if !added.isEmpty   { parts.append("Added:\n" + added.map   { "  + \($0)" }.joined(separator: "\n")) }
            if !removed.isEmpty { parts.append("Removed:\n" + removed.map { "  − \($0)" }.joined(separator: "\n")) }
            if !moved.isEmpty   { parts.append("Moved:\n" + moved.map   { "  ↔ \($0)" }.joined(separator: "\n")) }
            componentSection = parts.joined(separator: "\n")
        }

        let notesText = session.notes.filter { $0.type == .manual }.isEmpty ? "None." :
            session.notes.filter { $0.type == .manual }
                .map { "  • \($0.content)" }.joined(separator: "\n")

        let devsText = session.deviations.isEmpty ? "None flagged by engineer." :
            session.deviations
                .map { "  • [\($0.severity.rawValue.uppercased())] \($0.description)" }
                .joined(separator: "\n")

        let files = Array(Set(session.changes.compactMap(\.file))).sorted()
        let filesText = files.isEmpty ? "None recorded." :
            files.map { "  • \($0)" }.joined(separator: "\n")

        return """
        You are a hardware engineering documentation assistant summarising a KiCad/EDA work session.

        Write a structured plain-text summary with these sections:
        1. "What was done:" — 3–6 bullet points of engineering work
        2. "Components changed:" — bullet list of adds, removes, and moves
        3. "Simulation:" — whether LTSpice verified the circuit, any violations
        4. "Deviations:" — confirmed issues or "None detected."

        Be specific and technical. Use the component names and values provided.

        ## Session
        App: \(session.appName)
        Date: \(df.string(from: session.startTime))
        Duration: \(dur) min, \(session.changes.count) saves

        ## Files Modified
        \(filesText)

        ## Component Changes
        \(componentSection)

        ## Engineer Notes
        \(notesText)

        ## Engineer-Flagged Deviations
        \(devsText)

        ## LTSpice Simulation Results
        \(spiceStatus(from: session))

        Output plain text only — no JSON, no markdown, no preamble.
        """
    }

    // MARK: - API call

    private func callClaude(session: Session, apiKey: String) async -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return buildFallback(session: session)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model":      "claude-sonnet-4-20250514",
            "max_tokens": 1024,
            "messages":   [["role": "user", "content": buildPrompt(session: session)]]
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = (json["content"] as? [[String: Any]])?.first,
              let text  = block["text"] as? String
        else { return buildFallback(session: session) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Fallback (no API key)

    private func buildFallback(session: Session) -> String {
        let dur     = Int(session.duration / 60)
        let added   = addedComponents(from: session)
        let removed = removedComponents(from: session)
        let moved   = movedComponents(from: session)
        let files   = Array(Set(session.changes.compactMap(\.file))).sorted()

        var lines = ["What was done:"]
        lines.append("• \(session.appName) session, \(dur) min, \(session.changes.count) saves")
        if !files.isEmpty {
            lines.append("• Files: \(files.prefix(5).joined(separator: ", "))")
        }
        for note in session.notes.filter({ $0.type == .manual }).prefix(4) {
            lines.append("• \(note.content)")
        }

        lines.append("")
        lines.append("Components changed:")
        if added.isEmpty && removed.isEmpty && moved.isEmpty {
            lines.append("• No structural changes detected")
        } else {
            added.forEach   { lines.append("+ \($0)") }
            removed.forEach { lines.append("− \($0)") }
            moved.forEach   { lines.append("↔ \($0)") }
        }

        lines.append("")
        lines.append("Simulation:")
        lines.append(spiceStatus(from: session)
            .components(separatedBy: "\n")
            .map { $0.hasPrefix(" ") ? $0 : "• \($0)" }
            .joined(separator: "\n"))

        lines.append("")
        lines.append("Deviations:")
        let spiceViols = session.spiceResults.flatMap(\.violations)
        if spiceViols.isEmpty && session.deviations.isEmpty {
            lines.append("• None detected.")
        } else {
            spiceViols.forEach { lines.append("• [SIM/\($0.severity.uppercased())] \($0.message)") }
            session.deviations.forEach { lines.append("• [\($0.severity.rawValue.uppercased())] \($0.description)") }
        }

        lines.append("\nAdd your Anthropic API key in Settings for AI-generated summaries.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Keychain

    func getKey() -> String {
        Keychain.read("pc_api_key")
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
            ?? ""
    }
    func setKey(_ k: String) { Keychain.save("pc_api_key", value: k) }
    func clearKey()           { Keychain.delete("pc_api_key") }
}

// MARK: - Keychain

enum Keychain {
    static func save(_ key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                 kSecAttrAccount as String: key, kSecValueData as String: data]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                 kSecAttrAccount as String: key,
                                 kSecReturnData as String: true,
                                 kSecMatchLimit as String: kSecMatchLimitOne]
        var r: AnyObject?
        SecItemCopyMatching(q as CFDictionary, &r)
        return (r as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                 kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
