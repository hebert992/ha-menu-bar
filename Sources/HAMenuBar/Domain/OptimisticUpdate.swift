import Foundation

/// Predicts an entity's next state right after a resolved command, so the UI reacts before HA
/// confirms. The real `state_changed` event overwrites the prediction.
enum OptimisticUpdate {
    /// Returns the predicted entity, or nil when the command has no predictable state change.
    static func apply(_ action: EntityAction, to entity: Entity) -> Entity? {
        guard !entity.isUnavailable, let kind = entity.kind else { return nil }
        var updated = entity
        switch action {
        case .toggle where kind.isToggleable:
            updated.state = entity.isOn ? "off" : "on"
        // `turn_on` on climate leaves the resulting mode to HA, so there is nothing to predict.
        case .turnOn where kind.isToggleable:
            updated.state = "on"
        case .turnOff where kind.isToggleable || kind == .climate:
            updated.state = "off"
        case let .setBrightness(percent) where kind == .light:
            updated.state = percent > 0 ? "on" : "off"
            updated.attributes["brightness"] = percent > 0 ? .number((Double(percent) * 2.55).rounded()) : .null
        case let .setHvacMode(mode) where kind == .climate:
            updated.state = mode
        case let .setTemperature(value) where kind == .climate:
            updated.attributes["temperature"] = .number(value)
        default:
            return nil
        }
        return updated
    }
}
