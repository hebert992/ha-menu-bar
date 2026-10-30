import Foundation

// MARK: - Coders

/// Shared coders; creating JSONDecoder/JSONEncoder per frame is measurable on the state_changed hot path.
enum HAJSON {
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()
}

// MARK: - Outgoing

/// Messages the client sends over the HA WebSocket API.
enum HAOutgoingMessage: Equatable, Sendable {
    case auth(accessToken: String)
    case getStates(id: Int)
    case subscribeEvents(id: Int, eventType: String)
    case callService(id: Int, call: ServiceCall)
    case ping(id: Int)
    case historyDuringPeriod(id: Int, start: Date, entityIds: [String])

    var json: JSONValue {
        var object = body
        if let id { object["id"] = .number(Double(id)) }
        return .object(object)
    }

    private var id: Int? {
        switch self {
        case .auth: nil
        case let .getStates(id), let .subscribeEvents(id, _), let .callService(id, _), let .ping(id),
             let .historyDuringPeriod(id, _, _): id
        }
    }

    /// The message without its `id`, which is merged in once by `json`.
    private var body: [String: JSONValue] {
        switch self {
        case let .auth(token):
            ["type": .string("auth"), "access_token": .string(token)]
        case .getStates:
            ["type": .string("get_states")]
        case let .subscribeEvents(_, eventType):
            ["type": .string("subscribe_events"), "event_type": .string(eventType)]
        case let .callService(_, call):
            [
                "type": .string("call_service"),
                "domain": .string(call.domain),
                "service": .string(call.service),
                "service_data": .object(call.data),
                "target": .object(["entity_id": .string(call.entityId)]),
            ]
        case .ping:
            ["type": .string("ping")]
        case let .historyDuringPeriod(_, start, entityIds):
            [
                "type": .string("history/history_during_period"),
                "start_time": .string(start.ISO8601Format()),
                "entity_ids": .array(entityIds.map(JSONValue.string)),
                "minimal_response": .bool(true),
                "no_attributes": .bool(true),
                "significant_changes_only": .bool(false),
            ]
        }
    }

    func encoded() throws -> Data {
        try HAJSON.encoder.encode(json)
    }

    func encodedString() throws -> String {
        String(decoding: try encoded(), as: UTF8.self)
    }
}

/// Never let the access token leak through string interpolation, logs or debugger output.
extension HAOutgoingMessage: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        switch self {
        case .auth: "auth(<redacted>)"
        case let .getStates(id): "getStates(\(id))"
        case let .subscribeEvents(id, type): "subscribeEvents(\(id), \(type))"
        case let .callService(id, call): "callService(\(id), \(call.domain).\(call.service) \(call.entityId))"
        case let .ping(id): "ping(\(id))"
        case let .historyDuringPeriod(id, _, ids): "historyDuringPeriod(\(id), \(ids.count) entities)"
        }
    }

    var debugDescription: String { description }
}

// MARK: - Incoming

enum HAProtocolError: Error, Equatable {
    case malformedFrame
}

/// Messages received from the HA WebSocket API. Only the fields the app uses are kept.
enum HAIncomingMessage: Equatable, Sendable {
    case authRequired
    case authOK(haVersion: String?)
    case authInvalid(message: String?)
    case result(id: Int, success: Bool, result: JSONValue?, errorMessage: String?)
    case stateChanged(entityId: String, newState: Entity?)
    case pong
    case unknown

    static func decode(_ message: URLSessionWebSocketTask.Message) throws -> HAIncomingMessage {
        switch message {
        case let .string(text): try decode(Data(text.utf8))
        case let .data(data): try decode(data)
        @unknown default: throw HAProtocolError.malformedFrame
        }
    }

    static func decode(_ data: Data) throws -> HAIncomingMessage {
        let json = try HAJSON.decoder.decode(JSONValue.self, from: data)
        guard let type = json["type"]?.stringValue else { throw HAProtocolError.malformedFrame }

        switch type {
        case "auth_required":
            return .authRequired
        case "auth_ok":
            return .authOK(haVersion: json["ha_version"]?.stringValue)
        case "auth_invalid":
            return .authInvalid(message: json["message"]?.stringValue)
        case "result":
            return .result(
                id: json["id"]?.intValue ?? 0,
                success: json["success"]?.boolValue ?? false,
                result: json["result"].flatMap { $0.isNull ? nil : $0 },
                errorMessage: json["error"]?["message"]?.stringValue
            )
        case "event":
            guard let event = json["event"], event["event_type"]?.stringValue == "state_changed",
                  let data = event["data"], let entityId = data["entity_id"]?.stringValue
            else { return .unknown }
            return .stateChanged(entityId: entityId, newState: data["new_state"].flatMap(Entity.init(json:)))
        case "pong":
            return .pong
        default:
            return .unknown
        }
    }
}

/// Decodes `history/history_during_period` results into typed samples.
enum HAHistoryDecoder {
    /// Parses `{entity_id: [state, ...]}`. Accepts the compressed format (`s`, `lu`, `lc`) and the
    /// full format (`state`, `last_updated`). Non-numeric states (unavailable, unknown, ...) are dropped.
    /// Samples are sorted by date.
    static func samples(from result: JSONValue?) -> [String: [PowerSample]] {
        guard let object = result?.objectValue else { return [:] }
        var history: [String: [PowerSample]] = [:]
        for (entityId, states) in object {
            let samples = (states.arrayValue ?? []).compactMap(sample(from:))
            history[entityId] = samples.sorted { $0.date < $1.date }
        }
        return history
    }

    private static func sample(from state: JSONValue) -> PowerSample? {
        guard let raw = state["s"]?.stringValue ?? state["state"]?.stringValue,
              let value = Double(raw), value.isFinite,
              let date = timestamp(state["lu"]) ?? timestamp(state["lc"])
                ?? timestamp(state["last_updated"]) ?? timestamp(state["last_changed"])
        else { return nil }
        return PowerSample(date: date, value: value)
    }

    private static func timestamp(_ value: JSONValue?) -> Date? {
        switch value {
        case let .number(seconds)?:
            return Date(timeIntervalSince1970: seconds)
        case let .string(text)?:
            if let date = try? Date(text, strategy: .iso8601) { return date }
            return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
        default:
            return nil
        }
    }
}

// MARK: - Endpoint & backoff

enum HAEndpoint {
    /// Normalizes user input like `192.168.1.10:8123/` into `http://192.168.1.10:8123`.
    static func baseURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty
        else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.url
    }

    /// Derives `ws(s)://host[:port][/path]/api/websocket` from the HA base URL.
    static func webSocketURL(from raw: String) -> URL? {
        guard let base = baseURL(from: raw),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.path = components.path + "/api/websocket"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct ReconnectBackoff: Sendable {
    var base: Double = 1
    var cap: Double = 30

    func delay(forAttempt attempt: Int) -> Double {
        guard attempt < 32 else { return cap }
        return min(cap, base * pow(2, Double(max(attempt, 0))))
    }
}
