import Foundation

/// Home Assistant domains this app knows how to display and control.
enum EntityDomain: String, CaseIterable, Sendable {
    case scene
    case script
    case button
    case inputButton = "input_button"
    case light
    case `switch`
    case inputBoolean = "input_boolean"
    case fan
    case automation
    case cover
    case climate
    case sensor
    case binarySensor = "binary_sensor"

    /// Detects the domain from an entity id such as `light.kitchen`.
    init?(entityId: String) {
        guard let dot = entityId.firstIndex(of: "."), dot != entityId.startIndex,
              entityId.index(after: dot) != entityId.endIndex
        else { return nil }
        self.init(rawValue: String(entityId[..<dot]))
    }

    var section: PanelSection { baseKind.section }

    /// The presentation kind before attributes are known (a sensor may still turn out to be a power sensor).
    var baseKind: EntityKind {
        switch self {
        case .scene, .script, .button, .inputButton: .action
        case .light: .light
        case .switch, .inputBoolean, .fan, .automation: .toggle
        case .cover: .cover
        case .climate: .climate
        case .sensor, .binarySensor: .sensor
        }
    }

    var isToggleable: Bool { baseKind.isToggleable }

    var displayName: String {
        switch self {
        case .scene: "Scenes"
        case .script: "Scripts"
        case .button: "Buttons"
        case .inputButton: "Input Buttons"
        case .light: "Lights"
        case .switch: "Switches"
        case .inputBoolean: "Input Booleans"
        case .fan: "Fans"
        case .automation: "Automations"
        case .cover: "Covers"
        case .climate: "Climate"
        case .sensor: "Sensors"
        case .binarySensor: "Binary Sensors"
        }
    }
}

/// How an entity is rendered and controlled. Computed once per entity (see `Entity.kind`).
enum EntityKind: Equatable, Sendable {
    case action, light, toggle, cover, climate, powerSensor, sensor

    init?(domain: EntityDomain?, attributes: [String: JSONValue]) {
        guard let domain else { return nil }
        if domain == .sensor, Self.looksLikePower(attributes) {
            self = .powerSensor
        } else {
            self = domain.baseKind
        }
    }

    /// Supports on/off/toggle services.
    var isToggleable: Bool { self == .light || self == .toggle }

    var section: PanelSection {
        switch self {
        case .action: .actions
        case .light: .lights
        case .toggle: .toggles
        case .cover: .covers
        case .climate: .climate
        case .powerSensor, .sensor: .sensors
        }
    }

    private static func looksLikePower(_ attributes: [String: JSONValue]) -> Bool {
        let unit = attributes["unit_of_measurement"]?.stringValue
        return attributes["device_class"]?.stringValue == "power" || unit == "W" || unit == "kW"
    }
}

extension String {
    /// `coffee_maker` → `Coffee Maker`: underscores become spaces and each word is capitalized.
    var humanized: String {
        split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// Visual sections of the panel. Several domains can share a section.
enum PanelSection: String, CaseIterable, Sendable {
    case actions, lights, toggles, covers, climate, sensors

    var title: String {
        switch self {
        case .actions: "Scenes & Scripts"
        case .lights: "Lights"
        case .toggles: "Switches"
        case .covers: "Covers"
        case .climate: "Climate"
        case .sensors: "Sensors"
        }
    }
}
