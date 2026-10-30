import Foundation
import OSLog

enum HAConnectionError: Error, LocalizedError {
    case invalidToken(String?)

    var errorDescription: String? {
        switch self {
        case let .invalidToken(message): "Authentication failed\(message.map { ": \($0)" } ?? ".")"
        }
    }
}

/// Result of asking the client to call a service.
enum ServiceCallOutcome: Equatable, Sendable {
    /// Sent; the outcome arrives later as `.serviceResult` with this id.
    case sent(id: Int)
    /// Not authenticated, nothing was sent.
    case notConnected
}

/// Main-actor isolated WebSocket client for the Home Assistant API.
/// Handles auth, initial `get_states`, live `state_changed` updates, service calls,
/// heartbeat pings and reconnection with exponential backoff.
@MainActor
final class HAWebSocketClient {
    enum Event {
        case status(ConnectionStatus)
        case states([Entity])
        case stateChanged(entityId: String, entity: Entity?)
        /// Sent once per history request, also on failure (with empty samples).
        case history(requested: [String], samples: [String: [PowerSample]])
        case serviceResult(id: Int, errorMessage: String?)
    }

    var onEvent: (@MainActor (Event) -> Void)?

    private let logger = Logger(subsystem: "dev.hebert.hamenubar", category: "websocket")
    private let session = URLSession(configuration: .default)
    private let backoff = ReconnectBackoff(base: 1, cap: 30)
    private let clock = ContinuousClock()
    private let heartbeatInterval: Duration = .seconds(30)
    private let heartbeatTimeout: Duration = .seconds(75)

    private var url: URL?
    private var token: String?
    private var shouldRun = false
    private var attempt = 0
    private var nextMessageId = 1
    private var getStatesId: Int?
    private var historyRequests: [Int: [String]] = [:]
    private var pendingServiceCalls: Set<Int> = []
    private var isAuthenticated = false
    private var lastPong: ContinuousClock.Instant

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    init() {
        lastPong = clock.now
    }

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

    func callService(_ call: ServiceCall) -> ServiceCallOutcome {
        guard isAuthenticated else { return .notConnected }
        let id = makeId()
        pendingServiceCalls.insert(id)
        send(.callService(id: id, call: call))
        return .sent(id: id)
    }

    /// Requests recorder history for the given entities since `start`. Delivered as `.history`.
    func requestHistory(entityIds: [String], since start: Date) {
        guard isAuthenticated, !entityIds.isEmpty else { return }
        let id = makeId()
        historyRequests[id] = entityIds
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

    /// Closes the socket and forgets in-flight requests; their results can no longer arrive.
    private func teardown() {
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isAuthenticated = false
        getStatesId = nil
        historyRequests = [:]
        pendingServiceCalls = []
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard self.socket === socket else { return }
                handle(message)
            } catch {
                guard self.socket === socket, !Task.isCancelled else { return }
                connectionLost()
                return
            }
        }
    }

    private func connectionLost() {
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
        let incoming: HAIncomingMessage
        do {
            incoming = try HAIncomingMessage.decode(message)
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
            attempt = 0
            lastPong = clock.now
            onEvent?(.status(.connected(haVersion: version)))
            requestStates()
            send(.subscribeEvents(id: makeId(), eventType: "state_changed"))
            startHeartbeat()
        case let .authInvalid(message):
            shouldRun = false
            teardown()
            onEvent?(.status(.error(HAConnectionError.invalidToken(message).localizedDescription)))
        case let .result(id, success, result, errorMessage):
            handleResult(id: id, success: success, result: result, errorMessage: errorMessage)
        case let .stateChanged(entityId, newState):
            onEvent?(.stateChanged(entityId: entityId, entity: newState))
        case .pong:
            lastPong = clock.now
        case .unknown:
            break
        }
    }

    private func handleResult(id: Int, success: Bool, result: JSONValue?, errorMessage: String?) {
        if id == getStatesId {
            getStatesId = nil
            if success { onEvent?(.states(Entity.list(from: result))) }
        } else if let requested = historyRequests.removeValue(forKey: id) {
            // History is best effort (the recorder may be disabled); failures are not surfaced.
            let samples = success ? HAHistoryDecoder.samples(from: result) : [:]
            onEvent?(.history(requested: requested, samples: samples))
        } else if pendingServiceCalls.remove(id) != nil {
            let message = success ? nil : (errorMessage ?? "Home Assistant rejected the request.")
            onEvent?(.serviceResult(id: id, errorMessage: message))
        }
    }

    private func requestStates() {
        let id = makeId()
        getStatesId = id
        send(.getStates(id: id))
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, clock, heartbeatInterval, heartbeatTimeout] in
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeatInterval, clock: clock)
                guard !Task.isCancelled, let self else { return }
                if self.lastPong.duration(to: clock.now) > heartbeatTimeout {
                    self.connectionLost()
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
            switch try HAIncomingMessage.decode(try await socket.receive()) {
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
