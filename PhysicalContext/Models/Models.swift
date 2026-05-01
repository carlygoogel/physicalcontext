import Foundation
import SwiftUI

// MARK: - Session

struct Session: Identifiable, Codable {
    var id: UUID = UUID()
    var appName: String
    var appBundleID: String
    var startTime: Date
    var endTime: Date?
    var notes: [Note] = []
    var changes: [Change] = []
    var deviations: [Deviation] = []
    var summary: String = ""
    var additionalNotes: String = ""

    var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }

    var isActive: Bool { endTime == nil }

    var durationString: String {
        let d = Int(duration)
        if d < 60 { return "\(d)s" }
        if d < 3600 { return "\(d / 60)m" }
        return "\(d / 3600)h \((d % 3600) / 60)m"
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: startTime)
    }
}

// MARK: - Note

struct Note: Identifiable, Codable {
    var id: UUID = UUID()
    var content: String
    var timestamp: Date = Date()
    var type: NoteType = .manual

    enum NoteType: String, Codable, CaseIterable {
        case manual = "note"
        case change = "change"
        case deviation = "deviation"
        case justification = "justification"
    }

    var typeColor: Color {
        switch type {
        case .manual: return Theme.accent
        case .change: return Theme.textSecondary
        case .deviation: return Theme.warning
        case .justification: return Theme.success
        }
    }

    var typeLabel: String {
        switch type {
        case .manual: return "NOTE"
        case .change: return "CHANGE"
        case .deviation: return "DEVIATION"
        case .justification: return "JUSTIFICATION"
        }
    }
}

// MARK: - Change

struct Change: Identifiable, Codable {
    var id: UUID = UUID()
    var description: String
    var timestamp: Date = Date()
    var file: String?
    var changeType: ChangeType = .save

    enum ChangeType: String, Codable {
        case save, componentAdd, componentRemove
        case routeChange, schematicChange, codeChange
        case coordinateMove, connectionChange
    }

    var icon: String {
        switch changeType {
        case .save: return "arrow.down.circle"
        case .componentAdd: return "plus.circle"
        case .componentRemove: return "minus.circle"
        case .routeChange: return "point.3.connected.trianglepath.dotted"
        case .schematicChange: return "list.bullet.rectangle"
        case .codeChange: return "chevron.left.forwardslash.chevron.right"
        case .coordinateMove: return "move.3d"
        case .connectionChange: return "arrow.triangle.branch"
        }
    }
}

// MARK: - Deviation

struct Deviation: Identifiable, Codable {
    var id: UUID = UUID()
    var description: String
    var severity: Severity = .moderate
    var justification: String = ""
    var confirmed: Bool = false
    var timestamp: Date = Date()

    enum Severity: String, Codable, CaseIterable {
        case minor = "Minor"
        case moderate = "Moderate"
        case major = "Major"
    }

    var severityColor: Color {
        switch severity {
        case .minor:    return Color(hex: "#3B82F6")
        case .moderate: return Color(hex: "#F59E0B")
        case .major:    return Color(hex: "#F87171")
        }
    }
}

// MARK: - CAD Application

struct CADApp: Identifiable {
    var id: String { bundleID }
    var name: String
    var bundleID: String
    var sfSymbol: String
}

let knownCADApps: [CADApp] = [
    CADApp(name: "Altium Designer", bundleID: "com.altium.AltiumDesigner", sfSymbol: "cpu"),
    CADApp(name: "KiCad", bundleID: "org.kicad.kicad", sfSymbol: "square.3.layers.3d"),
    CADApp(name: "EAGLE", bundleID: "com.autodesk.eagle", sfSymbol: "circlebadge.2"),
    CADApp(name: "Fusion 360", bundleID: "com.autodesk.mas.fusion360", sfSymbol: "rotate.3d"),
    CADApp(name: "SolidWorks", bundleID: "com.dassault-systemes.solidworks", sfSymbol: "cube"),
    CADApp(name: "OrCAD", bundleID: "com.cadence.orcad", sfSymbol: "square.grid.3x3"),
    CADApp(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", sfSymbol: "chevron.left.forwardslash.chevron.right"),
    CADApp(name: "Xcode", bundleID: "com.apple.dt.Xcode", sfSymbol: "hammer"),
]
