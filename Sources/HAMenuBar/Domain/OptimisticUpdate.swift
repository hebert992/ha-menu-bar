import Foundation

/// Predicts an entity's next state right after an action, so the UI reacts before HA confirms.
/// The real `state_changed` event overwrites the prediction.
enum OptimisticUpdate {
    /// Returns the predicted entity, or nil when the action has no predictable state change.
    static func apply(_ action: EntityAction, to entity: Entity, lastHvacMode: String? = nil) -> Entity? {
        guard !entity.isUnavailable, let domain = entity.domain else { return nil }
        var updated = entity

        if domain == .climate {
            let powerOn: Bool? = switch action {
            case .turnOn: true
            case .turnOff: false
            case .toggle: !entity.isOn
            default: nil
            }
            switch action {
            case .turnOn, .turnOff, .toggle:
                if powerOn == true {
                    guard let onMode = entity.restoreHvacMode(lastUsed: lastHvacMode) else { return nil }
                    updated.state = onMode
                } else {
                    updated.state = "off"
                }
            case let .setHvacMode(mode): updated.state = mode
            case let .setTemperature(value): updated.attributes["temperature"] = .number(value)
            default: return nil
            }
            return updated
        }

        switch action {
        case .toggle where domain.isToggleable:
            updated.state = entity.isOn ? "off" : "on"
        case .turnOn where domain.isToggleable:
            updated.state = "on"
        case .turnOff where domain.isToggleable:
            updated.state = "off"
        case let .setBrightness(percent) where domain == .light:
            updated.state = percent > 0 ? "on" : "off"
            updated.attributes["brightness"] = percent > 0 ? .number((Double(percent) * 2.55).rounded()) : .null
        default:
            return nil
        }
        return updated
    }
}
