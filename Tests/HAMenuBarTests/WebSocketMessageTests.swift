import Foundation
import Testing
@testable import HAMenuBar

@Suite("WebSocket messages")
struct WebSocketMessageTests {
    private func object(_ message: HAOutgoingMessage) throws -> [String: JSONValue] {
        let data = try message.encoded()
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return try #require(value.objectValue)
    }

    // MARK: Outgoing

    @Test func encodesAuth() throws {
        let obj = try object(.auth(accessToken: "abc"))
        #expect(obj == ["type": .string("auth"), "access_token": .string("abc")])
    }

    @Test func authDescriptionNeverContainsToken() {
        let message = HAOutgoingMessage.auth(accessToken: "super-secret")
        #expect(!String(describing: message).contains("super-secret"))
        #expect(!String(reflecting: message).contains("super-secret"))
    }

    @Test func encodesGetStates() throws {
        #expect(try object(.getStates(id: 3)) == ["id": .number(3), "type": .string("get_states")])
    }

    @Test func encodesSubscribeStateChanged() throws {
        #expect(try object(.subscribeEvents(id: 4, eventType: "state_changed")) == [
            "id": .number(4), "type": .string("subscribe_events"), "event_type": .string("state_changed"),
        ])
    }

    @Test func encodesCallService() throws {
        let call = ServiceCall(domain: "light", service: "turn_on", entityId: "light.desk",
                               data: ["brightness_pct": .number(30)])
        #expect(try object(.callService(id: 7, call: call)) == [
            "id": .number(7),
            "type": .string("call_service"),
            "domain": .string("light"),
            "service": .string("turn_on"),
            "service_data": .object(["brightness_pct": .number(30)]),
            "target": .object(["entity_id": .string("light.desk")]),
        ])
    }

    @Test func encodesPing() throws {
        #expect(try object(.ping(id: 9)) == ["id": .number(9), "type": .string("ping")])
    }

    // MARK: Incoming

    private func decode(_ json: String) throws -> HAIncomingMessage {
        try HAIncomingMessage.decode(Data(json.utf8))
    }

    @Test func decodesAuthHandshake() throws {
        #expect(try decode(#"{"type":"auth_required","ha_version":"2026.10.1"}"#) == .authRequired)
        #expect(try decode(#"{"type":"auth_ok","ha_version":"2026.10.1"}"#) == .authOK(haVersion: "2026.10.1"))
        #expect(try decode(#"{"type":"auth_invalid","message":"Invalid password"}"#) == .authInvalid(message: "Invalid password"))
    }

    @Test func decodesGetStatesResult() throws {
        let message = try decode("""
        {"id": 1, "type": "result", "success": true, "result": [
          {"entity_id": "light.a", "state": "on", "attributes": {"friendly_name": "A", "brightness": 255}},
          {"entity_id": "sensor.b", "state": "3", "attributes": {"unit_of_measurement": "W"}},
          {"bogus": true}
        ]}
        """)
        guard case let .result(id, success, result, errorMessage) = message else {
            Issue.record("Expected result, got \(message)")
            return
        }
        #expect(id == 1)
        #expect(success)
        #expect(errorMessage == nil)
        let entities = Entity.list(from: result)
        #expect(entities.map(\.entityId) == ["light.a", "sensor.b"])
        #expect(entities.first?.brightnessPercent == 100)
    }

    @Test func decodesErrorResult() throws {
        let message = try decode("""
        {"id": 5, "type": "result", "success": false,
         "error": {"code": "service_not_found", "message": "Service not found."}}
        """)
        #expect(message == .result(id: 5, success: false, result: nil, errorMessage: "Service not found."))
    }

    @Test func decodesStateChangedEvent() throws {
        let message = try decode("""
        {"id": 2, "type": "event", "event": {
          "event_type": "state_changed",
          "data": {
            "entity_id": "switch.plug",
            "old_state": {"entity_id": "switch.plug", "state": "off", "attributes": {}},
            "new_state": {"entity_id": "switch.plug", "state": "on", "attributes": {"friendly_name": "Plug"}}
          },
          "origin": "LOCAL", "time_fired": "2026-10-30T10:00:00+00:00"
        }}
        """)
        guard case let .stateChanged(entityId, newState) = message else {
            Issue.record("Expected stateChanged, got \(message)")
            return
        }
        #expect(entityId == "switch.plug")
        #expect(newState?.isOn == true)
        #expect(newState?.friendlyName == "Plug")
    }

    @Test func decodesEntityRemovedEvent() throws {
        let message = try decode("""
        {"id": 2, "type": "event", "event": {"event_type": "state_changed",
          "data": {"entity_id": "switch.gone", "old_state": {"entity_id": "switch.gone", "state": "on"}, "new_state": null}}}
        """)
        #expect(message == .stateChanged(entityId: "switch.gone", newState: nil))
    }

    @Test func decodesPongAndUnknown() throws {
        #expect(try decode(#"{"id": 12, "type": "pong"}"#) == .pong)
        #expect(try decode(#"{"type": "something_new"}"#) == .unknown)
        // Events other than state_changed are not used.
        #expect(try decode(#"{"id": 2, "type": "event", "event": {"event_type": "call_service"}}"#) == .unknown)
    }

    @Test func decodesWebSocketStringAndDataFrames() throws {
        let json = #"{"type":"auth_ok","ha_version":"1"}"#
        #expect(try HAIncomingMessage.decode(URLSessionWebSocketTask.Message.string(json)) == .authOK(haVersion: "1"))
        #expect(try HAIncomingMessage.decode(URLSessionWebSocketTask.Message.data(Data(json.utf8))) == .authOK(haVersion: "1"))
    }

    @Test func rejectsMalformedFrames() {
        #expect(throws: (any Error).self) { try decode("not json") }
        #expect(throws: (any Error).self) { try decode(#"{"no_type": 1}"#) }
    }
}

@Suite("Endpoint and backoff")
struct EndpointTests {
    @Test(arguments: [
        ("http://homeassistant.local:8123", "ws://homeassistant.local:8123/api/websocket"),
        ("http://homeassistant.local:8123/", "ws://homeassistant.local:8123/api/websocket"),
        ("https://ha.example.com", "wss://ha.example.com/api/websocket"),
        ("  192.168.1.10:8123  ", "ws://192.168.1.10:8123/api/websocket"),
        ("https://example.com/ha/", "wss://example.com/ha/api/websocket"),
    ])
    func derivesWebSocketURL(base: String, expected: String) {
        #expect(HAEndpoint.webSocketURL(from: base)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://host", "http://"])
    func rejectsInvalidBaseURL(base: String) {
        #expect(HAEndpoint.webSocketURL(from: base) == nil)
    }

    @Test func backoffDoublesAndCaps() {
        let backoff = ReconnectBackoff(base: 1, cap: 30)
        #expect(backoff.delay(forAttempt: 0) == 1)
        #expect(backoff.delay(forAttempt: 1) == 2)
        #expect(backoff.delay(forAttempt: 4) == 16)
        #expect(backoff.delay(forAttempt: 5) == 30)
        #expect(backoff.delay(forAttempt: 100) == 30)
    }
}
