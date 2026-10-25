import SwiftUI

// MARK: - Drive direction

/// Maps 1:1 onto what motor_node turns into ESP32 letters: F / B / L / R / S.
/// motor_node only uses the SIGN of linear.x and angular.z, and linear wins over angular.
enum DriveDirection: String {
    case forward, back, left, right

    /// geometry_msgs/msg/Twist as rosbridge JSON.
    var twist: [String: Any] {
        switch self {
        case .forward: return Twist.make(linear: 0.2, angular: 0)
        case .back:    return Twist.make(linear: -0.15, angular: 0)
        case .left:    return Twist.make(linear: 0, angular: 0.5)
        case .right:   return Twist.make(linear: 0, angular: -0.5)
        }
    }

    var symbol: String {
        switch self {
        case .forward: return "arrow.up"
        case .back:    return "arrow.down"
        case .left:    return "arrow.turn.up.left"
        case .right:   return "arrow.turn.up.right"
        }
    }
}

enum Twist {
    static let zero: [String: Any] = make(linear: 0, angular: 0)

    static func make(linear: Double, angular: Double) -> [String: Any] {
        [
            "linear": ["x": linear, "y": 0.0, "z": 0.0],
            "angular": ["x": 0.0, "y": 0.0, "z": angular],
        ]
    }
}

// MARK: - Mode

enum RoverMode: String, CaseIterable, Identifiable {
    case manual = "Manual"
    case autonomous = "Autonomous"
    var id: String { rawValue }
}

// MARK: - Navigation status

/// Parsed form of /navigation/status, e.g. "PATH CLEAR | 1.20 m" or "DEPTH LOST - STOP | inf m".
struct NavStatus: Equatable {
    enum Level { case clear, caution, working, stopped, manual, unknown }

    let text: String
    let distance: Double?
    let receivedAt: Date

    static let none = NavStatus(text: "NO STATUS", distance: nil, receivedAt: .distantPast)

    init(text: String, distance: Double?, receivedAt: Date = Date()) {
        self.text = text
        self.distance = distance
        self.receivedAt = receivedAt
    }

    init(raw: String) {
        let parts = raw.components(separatedBy: "|")
        text = parts.first?.trimmingCharacters(in: .whitespaces) ?? raw
        if parts.count > 1 {
            let d = parts[1].replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces)
            distance = Double(d)   // "inf" parses to +infinity
        } else {
            distance = nil
        }
        receivedAt = Date()
    }

    var level: Level {
        let t = text.uppercased()
        if t == "MANUAL" { return .manual }
        if t.contains("STOP") || t.contains("BLOCKED") || t.contains("TOO CLOSE") || t.contains("DEPTH LOST") || t.contains("PERSON") { return .stopped }
        if t.contains("SCANNING") || t.contains("AVOIDING") || t.contains("REVERSING") || t.contains("MEASURING") || t.contains("RETURNING") || t.contains("EVALUATING") || t.contains("PREPARING") { return .working }
        if t.contains("CAUTION") { return .caution }
        if t.contains("PATH CLEAR") { return .clear }
        return .unknown
    }

    var color: Color {
        switch level {
        case .clear:   return .green
        case .caution: return .yellow
        case .working: return .orange
        case .stopped: return .red
        case .manual:  return .blue
        case .unknown: return .gray
        }
    }

    var distanceText: String {
        guard let distance else { return "" }
        if distance.isInfinite || distance.isNaN { return "— m" }
        return String(format: "%.2f m", distance)
    }

    /// Status is stale if obstacle_avoidance has not published for a while (it runs at 20 Hz).
    var isStale: Bool { Date().timeIntervalSince(receivedAt) > 2.0 }
}

// MARK: - YOLO detections

/// One element of the JSON array on /yolo/detections:
/// {"class":"person","confidence":0.82,"x":..,"y":..,"w":..,"h":..}
struct Detection: Decodable, Identifiable, Equatable {
    let cls: String
    let confidence: Double
    let x: Double
    let y: Double
    let w: Double
    let h: Double

    var id: String { "\(cls)-\(x)-\(y)-\(w)-\(h)" }

    enum CodingKeys: String, CodingKey {
        case cls = "class", confidence, x, y, w, h
    }

    var isPerson: Bool { cls.lowercased() == "person" }

    static func parse(_ raw: String) -> [Detection] {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([Detection].self, from: data) else { return [] }
        return list
    }
}

// MARK: - Saved rover

struct SavedRover: Codable, Identifiable, Equatable {
    var host: String
    var port: Int = 9090
    var videoPort: Int = 5000
    var id: String { "\(host):\(port)" }

    var videoURL: URL? { URL(string: "http://\(host):\(videoPort)/stream") }
}
