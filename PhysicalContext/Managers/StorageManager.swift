import Foundation

final class StorageManager {
    static let shared = StorageManager()

    private var fileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PhysicalContext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    func loadSessions() -> [Session] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let sessions = try? JSONDecoder().decode([Session].self, from: data)
        else { return [] }
        return sessions
    }

    func saveSessions(_ sessions: [Session]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
