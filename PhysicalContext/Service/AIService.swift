// AIService.swift — Physical Context
// Generates structured session summaries using Claude.
// API key is stored in UserDefaults (set via Settings) or ANTHROPIC_API_KEY env var.

import Foundation
import PDFKit

// MARK: - Output types

struct SessionAISummary: Codable {
    var whatYouDid: [String]             // 3-5 past-tense action bullets
    var keyDecisions: [String]           // design choices worth flagging
    var suggestedDeviations: [SuggestedDeviation]  // AI-detected, user must accept
    var specNotes: [String]              // alignment notes (empty if no spec)
    var generatedAt: Date = Date()
}

struct SuggestedDeviation: Codable, Identifiable {
    var id: UUID = UUID()
    var description: String
    var severity: Deviation.Severity
    var reasoning: String
    var accepted: Bool = false           // user accepts → becomes a real Deviation
}

// MARK: - Service

actor AIService {
    static let shared = AIService()
    private init() {}

    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model  = "claude-sonnet-4-6"

    // MARK: - Public

    func generateSummary(
        for session: Session,
        specContent: String? = nil
    ) async throws -> SessionAISummary {
        guard apiKey() != nil else {
            // No key yet — return empty summary so UI shows gracefully
            return SessionAISummary(
                whatYouDid: [],
                keyDecisions: [],
                suggestedDeviations: [],
                specNotes: []
            )
        }
        let prompt = buildPrompt(session: session, specContent: specContent)
        let raw    = try await callAPI(prompt: prompt)
        return try parseResponse(raw)
    }

    // MARK: - Prompt construction

    private func buildPrompt(session: Session, specContent: String?) -> String {
        var lines: [String] = []

        lines.append("""
        You are a hardware/firmware engineering assistant reviewing a CAD session log.
        Produce a concise, accurate JSON summary for an engineer's design record.

        SESSION
        App: \(session.appName)
        Duration: \(session.durationString)
        Date: \(session.formattedDate)
        """)

        // File-level changes (from FSEventWatcher — already semantic for KiCad)
        if !session.changes.isEmpty {
            lines.append("\nFILE CHANGES (\(session.changes.count) events):")
            for c in session.changes {
                lines.append("  [\(hhmm(c.timestamp))] [\(c.changeType.rawValue)] \(c.description)")
            }
        }

        // Engineer's manual notes
        let manual = session.notes.filter { $0.type == .manual }
        if !manual.isEmpty {
            lines.append("\nENGINEER NOTES:")
            manual.forEach { lines.append("  - \($0.content)") }
        }

        // Justified deviations (already captured by user)
        if !session.deviations.isEmpty {
            lines.append("\nFLAGGED DEVIATIONS (already recorded — do NOT repeat these):")
            for d in session.deviations {
                var entry = "  [\(d.severity.rawValue.uppercased())] \(d.description)"
                if !d.justification.isEmpty { entry += "\n    Justification: \(d.justification)" }
                lines.append(entry)
            }
        }

        // Spec document (truncated to avoid token overflow)
        if let spec = specContent, !spec.isEmpty {
            let excerpt = String(spec.prefix(3_500))
            lines.append("\nSPEC DOCUMENT (excerpt):\n\(excerpt)")
        }

        lines.append("""

        Respond ONLY with valid JSON. No markdown, no explanation, no preamble.
        Schema:
        {
          "whatYouDid": ["<3-5 concise action bullets, past tense, specific and technical>"],
          "keyDecisions": ["<notable design choices or trade-offs visible in the changes>"],
          "suggestedDeviations": [
            {
              "description": "<what may deviate from spec or best practice>",
              "severity": "Minor|Moderate|Major",
              "reasoning": "<why this looks like a deviation, citing specific change events>"
            }
          ],
          "specNotes": ["<spec alignment observations; empty array if no spec was provided>"]
        }

        Rules:
        - Keep each bullet under 120 characters.
        - Only include suggestedDeviations for issues NOT already in FLAGGED DEVIATIONS above.
        - If data is sparse, return fewer bullets rather than padding.
        - For suggestedDeviations, cite specific change events (e.g. filenames, component refs).
        - If there are no key decisions or suggested deviations, return empty arrays.
        """)

        return lines.joined(separator: "\n")
    }

    // MARK: - API call

    private func callAPI(prompt: String) async throws -> String {
        guard let key = apiKey() else { throw AIError.noAPIKey }

        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key,                forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model":      model,
            "max_tokens": 1_024,
            "messages":   [["role": "user", "content": prompt]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIError.httpError(http.statusCode, body)
        }

        guard
            let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = (json["content"] as? [[String: Any]])?.first,
            let text    = content["text"] as? String
        else { throw AIError.badResponse }

        return text
    }

    // MARK: - Response parsing

    private func parseResponse(_ raw: String) throws -> SessionAISummary {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences if the model added them
        if text.hasPrefix("```") {
            let lines = text.components(separatedBy: "\n")
            text = lines.dropFirst().dropLast().joined(separator: "\n")
        }

        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AIError.parseError(text) }

        let whatYouDid   = json["whatYouDid"]    as? [String] ?? []
        let keyDecisions = json["keyDecisions"]   as? [String] ?? []
        let specNotes    = json["specNotes"]      as? [String] ?? []

        var suggested: [SuggestedDeviation] = []
        if let devs = json["suggestedDeviations"] as? [[String: Any]] {
            for d in devs {
                let sev: Deviation.Severity
                switch (d["severity"] as? String)?.lowercased() {
                case "minor": sev = .minor
                case "major": sev = .major
                default:      sev = .moderate
                }
                suggested.append(SuggestedDeviation(
                    description: d["description"] as? String ?? "",
                    severity:    sev,
                    reasoning:   d["reasoning"]   as? String ?? ""
                ))
            }
        }

        return SessionAISummary(
            whatYouDid:           whatYouDid,
            keyDecisions:         keyDecisions,
            suggestedDeviations:  suggested,
            specNotes:            specNotes
        )
    }

    // MARK: - Helpers

    private func apiKey() -> String? {
        // Placeholder — returns nil until a real key is set
        let placeholder = "YOUR_ANTHROPIC_KEY_HERE"
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !env.isEmpty, env != placeholder { return env }
        let stored = UserDefaults.standard.string(forKey: "anthropicAPIKey") ?? ""
        guard !stored.isEmpty, stored != placeholder else { return nil }
        return stored
    }

    private func hhmm(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
    }
}

// MARK: - Spec file loading (call from main actor)

extension AIService {
    /// Call this from your view/manager to read the user's spec file.
    /// Supports .pdf (via PDFKit) and plaintext (.md, .txt, etc.).
    nonisolated func loadSpecFile(at path: String) -> String? {
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }

        if path.lowercased().hasSuffix(".pdf") {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
            let pageCount = min(doc.pageCount, 15)   // cap at 15 pages
            return (0..<pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
        }

        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case noAPIKey
    case httpError(Int, String)
    case badResponse
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key set. Add your Anthropic key in Settings → AI."
        case .httpError(let code, let body):
            return "API error \(code): \(body.prefix(120))"
        case .badResponse:
            return "Unexpected response format from API."
        case .parseError(let raw):
            return "Could not parse AI response: \(raw.prefix(80))…"
        }
    }
}
