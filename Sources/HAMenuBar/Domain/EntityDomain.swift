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

    var section: PanelSection {
        switch self {
        case .scene, .script, .button, .inputButton: .actions
        case .light: .lights
        case .switch, .inputBoolean, .fan, .automation: .toggles
        case .cover: .covers
        case .climate: .climate
        case .sensor, .binarySensor: .sensors
        }
    }

    var isToggleable: Bool {
        switch self {
        case .light, .switch, .inputBoolean, .fan, .automation: true
        default: false
        }
    }

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
