// Models/SpiceModels.swift — Physical Context

import Foundation

// MARK: - Extend Session with simulation results
// Uses a static store so spice results survive across the session
// without touching the Codable Session struct.

extension Session {
    static var _spiceResultsStore: [UUID: [SpiceAnalysisResult]] = [:]

    var spiceResults: [SpiceAnalysisResult] {
        get { Session._spiceResultsStore[id] ?? [] }
        set { Session._spiceResultsStore[id] = newValue }
    }

    mutating func appendSpiceResult(_ result: SpiceAnalysisResult) {
        var current = Session._spiceResultsStore[id] ?? []
        current.append(result)
        Session._spiceResultsStore[id] = current
    }
}
