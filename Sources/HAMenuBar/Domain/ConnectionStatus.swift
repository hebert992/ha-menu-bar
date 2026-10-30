import Foundation

/// Severity of a status, mapped to a dot color by the UI.
enum StatusIndicator: Equatable, Sendable {
    case ok, pending, failure, inactive
}

enum ConnectionStatus: Equatable, Sendable {
    case notConfigured
    case connecting
    case connected(haVersion: String?)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var indicator: StatusIndicator {
        switch self {
        case .connected: .ok
        case .connecting: .pending
        case .error: .failure
        case .notConfigured: .inactive
        }
    }

    var label: String {
        switch self {
        case let .connected(haVersion): haVersion.map { "Connected · Home Assistant \($0)" } ?? "Connected"
        case .connecting: "Connecting…"
        case let .error(message): "Error: \(message)"
        case .notConfigured: "Not configured"
        }
    }
}
