import Foundation

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
        switch self {
        case let .auth(token):
            return .object(["type": .string("auth"), "access_token": .string(token)])
        case let .getStates(id):
            return .object(["id": .number(Double(id)), "type": .string("get_states")])
        case let .subscribeEvents(id, eventType):
            return .object([
                "id": .number(Double(id)),
                "type": .string("subscribe_events"),
                "event_type": .string(eventType),
            ])
        case let .callService(id, call):
            return .object([
                "id": .number(Double(id)),
                "type": .string("call_service"),
                "domain": .string(call.domain),
                "service": .string(call.service),
                "service_data": .object(call.data),
                "target": .object(["entity_id": .string(call.entityId)]),
            ])
        case let .ping(id):
            return .object(["id": .number(Double(id)), "type": .string("ping")])
        case let .historyDuringPeriod(id, start, entityIds):
            return .object([
                "id": .number(Double(id)),
                "type": .string("history/history_during_period"),
                "start_time": .string(start.ISO8601Format()),
                "entity_ids": .array(entityIds.map(JSONValue.string)),
                "minimal_response": .bool(true),
                "no_attributes": .bool(true),
                "significant_changes_only": .bool(false),
            ])
        }
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(json)
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

struct HAErrorPayload: Equatable, Sendable {
    var code: String?
    var message: String?
}

enum HAProtocolError: Error, Equatable {
    case malformedFrame
}

/// Messages received from the HA WebSocket API.
enum HAIncomingMessage: Equatable, Sendable {
    case authRequired(haVersion: String?)
    case authOK(haVersion: String?)
    case authInvalid(message: String?)
    case result(id: Int, success: Bool, result: JSONValue?, error: HAErrorPayload?)
    case stateChanged(subscriptionId: Int, entityId: String, newState: Entity?)
    case event(subscriptionId: Int, eventType: String?)
    case pong(id: Int)
    case unknown(type: String)

    static func decode(_ data: Data) throws -> HAIncomingMessage {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let type = json["type"]?.stringValue else { throw HAProtocolError.malformedFrame }
        let id = json["id"]?.intValue ?? 0

        switch type {
        case "auth_required":
            return .authRequired(haVersion: json["ha_version"]?.stringValue)
        case "auth_ok":
            return .authOK(haVersion: json["ha_version"]?.stringValue)
        case "auth_invalid":
            return .authInvalid(message: json["message"]?.stringValue)
        case "result":
            let result = json["result"].flatMap { $0.isNull ? nil : $0 }
            let error = json["error"]?.objectValue.map {
                HAErrorPayload(code: $0["code"]?.stringValue, message: $0["message"]?.stringValue)
            }
            return .result(id: id, success: json["success"]?.boolValue ?? false, result: result, error: error)
        case "event":
            let event = json["event"]
            let eventType = event?["event_type"]?.stringValue
            if eventType == "state_changed", let data = event?["data"],
               let entityId = data["entity_id"]?.stringValue {
                let newState = data["new_state"].flatMap(Entity.init(json:))
                return .stateChanged(subscriptionId: id, entityId: entityId, newState: newState)
            }
            return .event(subscriptionId: id, eventType: eventType)
        case "pong":
            return .pong(id: id)
        default:
            return .unknown(type: type)
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
