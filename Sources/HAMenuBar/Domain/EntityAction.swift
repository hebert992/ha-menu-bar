import Foundation

/// A user intent on an entity. `resolved(for:lastHvacMode:)` turns it into the concrete command
/// that ServiceCallMapper and OptimisticUpdate map without any per-domain decisions of their own.
enum EntityAction: Equatable, Sendable {
    case toggle
    case turnOn
    case turnOff
    case activate
    case setBrightness(percent: Int)
    case openCover
    case closeCover
    case stopCover
    case setTemperature(Double)
    case setHvacMode(String)

    /// Resolves the intent against the entity's current state. Only climate power intents change:
    /// - on: restore an explicit HVAC mode (see `ClimateMemory.restoreMode`), falling back to `turnOn`
    ///   (`climate.turn_on`) only when no usable mode is known. `climate.turn_on` is avoided because
    ///   HA's default implementation picks HEAT_COOL → HEAT → COOL, which turns most ACs on in heat.
    /// - off: `turnOff` when the device supports TURN_OFF, otherwise `setHvacMode("off")`.
    func resolved(for entity: Entity, lastHvacMode: String?) -> EntityAction? {
        guard entity.kind == .climate else { return self }
        switch self {
        case .turnOn: return Self.climateOn(entity, lastHvacMode)
        case .turnOff: return Self.climateOff(entity)
        case .toggle: return entity.isOn ? Self.climateOff(entity) : Self.climateOn(entity, lastHvacMode)
        default: return self
        }
    }

    private static func climateOn(_ entity: Entity, _ lastHvacMode: String?) -> EntityAction {
        ClimateMemory.restoreMode(for: entity, lastUsed: lastHvacMode).map(EntityAction.setHvacMode) ?? .turnOn
    }

    private static func climateOff(_ entity: Entity) -> EntityAction {
        entity.supportsClimateFeature(.turnOff) ? .turnOff : .setHvacMode("off")
    }
}

/// Bits of `supported_features` on climate entities (HA `ClimateEntityFeature`).
enum ClimateFeature: Int, Sendable {
    case targetTemperature = 1
    case turnOff = 128
    case turnOn = 256
}
