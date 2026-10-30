import Foundation
import OSLog

enum HAConnectionError: Error, LocalizedError {
    case invalidURL
    case invalidToken(String?)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The Home Assistant URL is not valid."
        case let .invalidToken(message): "Authentication failed\(message.map { ": \($0)" } ?? ".")"
        case .unexpectedResponse: "Unexpected response from Home Assistant."
        }
    }
}

/// Main-actor isolated WebSocket client for the Home Assistant API.
/// Handles auth, initial `get_states`, live `state_changed` updates, service calls,
/// heartbeat pings and reconnection with exponential backoff.
@MainActor
final class HAWebSocketClient {
    enum Event {
        case status(ConnectionStatus)
        case serverVersion(String?)
        case history(JSONValue?)
        case states([Entity])
        case stateChanged(entityId: String, entity: Entity?)
        case serviceError(String)
    }

    var onEvent: (@MainActor (Event) -> Void)?

    private let logger = Logger(subsystem: "dev.hebert.hamenubar", category: "websocket")
    private let session = URLSession(configuration: .default)
    private let backoff = ReconnectBackoff(base: 1, cap: 30)
    private let heartbeatInterval: Duration = .seconds(30)
    private let heartbeatTimeout: TimeInterval = 75

    private var url: URL?
    private var token: String?
    private var shouldRun = false
    private var attempt = 0
    private var nextMessageId = 1
    private var getStatesId: Int?
    private var historyRequestIds: Set<Int> = []
    private var isAuthenticated = false
    private var lastPong = Date()

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    var isConnected: Bool { isAuthenticated }

    // MARK: Public API

    func connect(url: URL, token: String) {
        stop()
        self.url = url
        self.token = token
        shouldRun = true
        attempt = 0
        open()
    }

    func stop() {
        shouldRun = false
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        token = nil
    }

    /// Re-fetches all states, or reconnects immediately if not connected.
    func refresh() {
        if isAuthenticated {
            requestStates()
        } else if url != nil, token != nil {
            shouldRun = true
            attempt = 0
            reconnectTask?.cancel()
            open()
        }
    }

    func callService(_ call: ServiceCall) {
        guard isAuthenticated else {
            onEvent?(.serviceError("Not connected to Home Assistant."))
            return
        }
        send(.callService(id: makeId(), call: call))
    }

    /// Requests recorder history for the given entities since `start`. Delivered as `.history`.
    func requestHistory(entityIds: [String], since start: Date) {
        guard isAuthenticated, !entityIds.isEmpty else { return }
        let id = makeId()
        historyRequestIds.insert(id)
        send(.historyDuringPeriod(id: id, start: start, entityIds: entityIds))
    }

    // MARK: Connection lifecycle

    private func open() {
        guard shouldRun, let url else { return }
        teardown()
        onEvent?(.status(.connecting))
        nextMessageId = 1
        let socket = session.webSocketTask(with: url)
        // get_states on large installations easily exceeds the 1 MB default.
        socket.maximumMessageSize = 64 * 1024 * 1024
        self.socket = socket
        socket.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket)
        }
    }

    private func teardown() {
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isAuthenticated = false
        getStatesId = nil
        historyRequestIds = []
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard self.socket === socket else { return }
                handle(message)
            } catch {
                guard self.socket === socket, !Task.isCancelled else { return }
                connectionLost(reason: error.localizedDescription)
                return
            }
        }
    }

    private func connectionLost(reason: String) {
        teardown()
        guard shouldRun else { return }
        let delay = backoff.delay(forAttempt: attempt)
        attempt += 1
        logger.info("Connection lost, retrying in \(delay, privacy: .public)s")
        onEvent?(.status(.error("Disconnected. Retrying in \(Int(delay))s…")))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }

    // MARK: Message handling

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .string(text): data = Data(text.utf8)
        case let .data(raw): data = raw
        @unknown default: return
        }

        let incoming: HAIncomingMessage
        do {
            incoming = try HAIncomingMessage.decode(data)
        } catch {
            logger.error("Dropping malformed frame")
            return
        }

        switch incoming {
        case .authRequired:
            guard let token else { return }
            send(.auth(accessToken: token))
        case let .authOK(version):
            isAuthenticated = true
            onEvent?(.serverVersion(version))
            attempt = 0
            lastPong = Date()
            onEvent?(.status(.connected))
            requestStates()
            send(.subscribeEvents(id: makeId(), eventType: "state_changed"))
            startHeartbeat()
        case let .authInvalid(message):
            shouldRun = false
            teardown()
            onEvent?(.status(.error(HAConnectionError.invalidToken(message).localizedDescription)))
        case let .result(id, success, result, error):
            if id == getStatesId {
                getStatesId = nil
                if success { onEvent?(.states(Entity.list(from: result))) }
            } else if historyRequestIds.remove(id) != nil {
                // History is best effort (the recorder may be disabled); failures are not surfaced.
                if success { onEvent?(.history(result)) }
            } else if !success {
                onEvent?(.serviceError(error?.message ?? "Home Assistant rejected the request."))
            }
        case let .stateChanged(_, entityId, newState):
            onEvent?(.stateChanged(entityId: entityId, entity: newState))
        case .pong:
            lastPong = Date()
        case .event, .unknown:
            break
        }
    }

    private func requestStates() {
        let id = makeId()
        getStatesId = id
        send(.getStates(id: id))
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, heartbeatInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeatInterval)
                guard !Task.isCancelled, let self else { return }
                if Date().timeIntervalSince(self.lastPong) > self.heartbeatTimeout {
                    self.connectionLost(reason: "Heartbeat timeout")
                    return
                }
                self.send(.ping(id: self.makeId()))
            }
        }
    }

    private func makeId() -> Int {
        defer { nextMessageId += 1 }
        return nextMessageId
    }

    private func send(_ message: HAOutgoingMessage) {
        guard let socket, let text = try? message.encodedString() else { return }
        Task {
            // A failed send surfaces as a receive error, which triggers reconnection.
            try? await socket.send(.string(text))
        }
    }

    // MARK: Connection test

    /// Performs a one-shot auth handshake and returns the Home Assistant version.
    nonisolated static func testConnection(url: URL, token: String) async throws -> String {
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        while true {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case let .string(text): data = Data(text.utf8)
            case let .data(raw): data = raw
            @unknown default: throw HAConnectionError.unexpectedResponse
            }
            switch try HAIncomingMessage.decode(data) {
            case .authRequired:
                try await socket.send(.string(HAOutgoingMessage.auth(accessToken: token).encodedString()))
            case let .authOK(version):
                return version ?? "unknown"
            case let .authInvalid(message):
                throw HAConnectionError.invalidToken(message)
            default:
                continue
            }
        }
    }
}
