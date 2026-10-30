import Foundation

/// Severity of a status, mapped to a dot color by the UI.
enum StatusIndicator: Equatable, Sendable {
    case ok, pending, failure, inactive
}

enum ConnectionStatus: Equatable, Sendable {
    case notConfigured
    case connecting
    case connected
    case error(String)

    var indicator: StatusIndicator {
        switch self {
        case .connected: .ok
        case .connecting: .pending
        case .error: .failure
        case .notConfigured: .inactive
        }
    }

    func label(haVersion: String?) -> String {
        switch self {
        case .connected: haVersion.map { "Connected · Home Assistant \($0)" } ?? "Connected"
        case .connecting: "Connecting…"
        case let .error(message): "Error: \(message)"
        case .notConfigured: "Not configured"
        }
    }
}
