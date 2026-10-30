import Foundation

/// A Home Assistant entity state, as returned by `get_states` or a `state_changed` event.
struct Entity: Identifiable, Hashable, Sendable {
    let entityId: String
    var state: String
    var attributes: [String: JSONValue]

    var id: String { entityId }
    var domain: EntityDomain? { EntityDomain(entityId: entityId) }

    init(entityId: String, state: String, attributes: [String: JSONValue]) {
        self.entityId = entityId
        self.state = state
        self.attributes = attributes
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
        return objectId.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
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

    /// The HVAC mode to restore when powering on: the last mode the user ran, if the device still
    /// offers it (or its modes are unknown); otherwise cool, heat_cool, auto, dry, fan_only, heat,
    /// then the first non-off mode. Nil means only `climate.turn_on` is left.
    func restoreHvacMode(lastUsed: String?) -> String? {
        let modes = hvacModes
        if let lastUsed, lastUsed != "off", modes.isEmpty || modes.contains(lastUsed) {
            return lastUsed
        }
        for preferred in ["cool", "heat_cool", "auto", "dry", "fan_only", "heat"] where modes.contains(preferred) {
            return preferred
        }
        return modes.first { $0 != "off" }
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
    var isPowerSensor: Bool {
        guard domain == .sensor else { return false }
        return deviceClass == "power" || unit == "W" || unit == "kW"
    }

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
            return state.replacingOccurrences(of: "_", with: " ").capitalized
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

extension Entity: Decodable {
    init(from decoder: any Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let entity = Entity(json: json) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Missing entity_id or state"))
        }
        self = entity
    }
}
