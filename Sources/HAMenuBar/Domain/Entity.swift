import Foundation

/// A Home Assistant entity state, as returned by `get_states` or a `state_changed` event.
struct Entity: Identifiable, Hashable, Sendable {
    let entityId: String
    /// Parsed once from `entityId`; nil for domains this app does not support.
    let domain: EntityDomain?
    var state: String
    var attributes: [String: JSONValue] {
        didSet { kind = EntityKind(domain: domain, attributes: attributes) }
    }
    /// How the entity is presented; derived from domain and attributes, kept in sync on change.
    private(set) var kind: EntityKind?

    var id: String { entityId }

    init(entityId: String, state: String, attributes: [String: JSONValue]) {
        self.entityId = entityId
        self.domain = EntityDomain(entityId: entityId)
        self.state = state
        self.attributes = attributes
        self.kind = EntityKind(domain: domain, attributes: attributes)
    }

    /// Builds an entity from a raw HA state object. Returns nil when required fields are missing.
    init?(json: JSONValue) {
        guard let object = json.objectValue,
              let entityId = object["entity_id"]?.stringValue,
              let state = object["state"]?.stringValue
        else { return nil }
        self.init(entityId: entityId, state: state, attributes: object["attributes"]?.objectValue ?? [:])
    }

    /// Parses a `get_states` result array, skipping malformed items.
    static func list(from json: JSONValue?) -> [Entity] {
        json?.arrayValue?.compactMap(Entity.init(json:)) ?? []
    }

    // MARK: Common attributes

    var friendlyName: String {
        if let name = attributes["friendly_name"]?.stringValue, !name.isEmpty { return name }
        let objectId = entityId.split(separator: ".", maxSplits: 1).last.map(String.init) ?? entityId
        return objectId.humanized
    }

    var unit: String? { attributes["unit_of_measurement"]?.stringValue }
    var deviceClass: String? { attributes["device_class"]?.stringValue }
    /// For climate, any HVAC mode other than `off` counts as on.
    var isOn: Bool {
        if domain == .climate { return state != "off" && !isUnavailable }
        return state == "on"
    }
    var isUnavailable: Bool { state == "unavailable" || state == "unknown" }

    // MARK: Lights

    /// Raw brightness (0–255), nil when off or unsupported.
    var brightness: Int? { attributes["brightness"]?.intValue }

    var brightnessPercent: Int? {
        guard let brightness else { return nil }
        return Int((Double(brightness) / 255 * 100).rounded())
    }

    var supportsBrightness: Bool {
        if let modes = attributes["supported_color_modes"]?.arrayValue?.compactMap(\.stringValue), !modes.isEmpty {
            return modes.contains { $0 != "onoff" && $0 != "unknown" }
        }
        return brightness != nil
    }

    // MARK: Climate

    var currentTemperature: Double? { attributes["current_temperature"]?.doubleValue }
    var targetTemperature: Double? { attributes["temperature"]?.doubleValue }
    var minTemperature: Double? { attributes["min_temp"]?.doubleValue }
    var maxTemperature: Double? { attributes["max_temp"]?.doubleValue }
    var hvacMode: String { state }
    var hvacAction: String? { attributes["hvac_action"]?.stringValue }
    var supportedFeatures: Int { attributes["supported_features"]?.intValue ?? 0 }
    var hvacModes: [String] { attributes["hvac_modes"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    func supportsClimateFeature(_ feature: ClimateFeature) -> Bool {
        supportedFeatures & feature.rawValue != 0
    }

    /// The current mode when the device is running (not off, unavailable or unknown).
    var activeHvacMode: String? {
        guard domain == .climate, isOn else { return nil }
        return state
    }

    /// Returns a new target temperature, rounded to 0.5 and clamped to the device's bounds.
    func adjustedTargetTemperature(by delta: Double, from base: Double? = nil) -> Double? {
        guard let start = base ?? targetTemperature else { return nil }
        var value = ((start + delta) * 2).rounded() / 2
        if let minTemperature { value = max(value, minTemperature) }
        if let maxTemperature { value = min(value, maxTemperature) }
        return value
    }

    // MARK: Sensors

    var numericState: Double? { Double(state).flatMap { $0.isFinite ? $0 : nil } }

    /// Sensors that get the live power sparkline.
    var isPowerSensor: Bool { kind == .powerSensor }

    // MARK: Covers

    var coverPosition: Int? { attributes["current_position"]?.intValue }

    // MARK: Display

    var displayState: String {
        if state == "unavailable" { return "Unavailable" }
        if state == "unknown" { return "Unknown" }
        switch domain {
        case .sensor:
            return unit.map { "\(state) \($0)" } ?? state
        case .binarySensor:
            return Self.binarySensorLabel(on: isOn, deviceClass: deviceClass)
        default:
            return state.humanized
        }
    }

    private static func binarySensorLabel(on: Bool, deviceClass: String?) -> String {
        switch deviceClass {
        case "door", "window", "garage_door", "opening": on ? "Open" : "Closed"
        case "motion", "occupancy", "presence": on ? "Detected" : "Clear"
        case "moisture": on ? "Wet" : "Dry"
        case "smoke", "gas", "carbon_monoxide", "problem", "safety": on ? "Alert" : "OK"
        case "lock": on ? "Unlocked" : "Locked"
        case "connectivity": on ? "Connected" : "Disconnected"
        case "battery": on ? "Low" : "Normal"
        case "plug", "power": on ? "Plugged in" : "Unplugged"
        default: on ? "On" : "Off"
        }
    }
}
