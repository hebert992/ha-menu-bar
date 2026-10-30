import Foundation

/// A user intent on an entity.
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
}

/// A Home Assistant `call_service` request.
struct ServiceCall: Equatable, Sendable {
    var domain: String
    var service: String
    var entityId: String
    var data: [String: JSONValue] = [:]
}

/// Bits of `supported_features` on climate entities (HA `ClimateEntityFeature`).
enum ClimateFeature: Int, Sendable {
    case targetTemperature = 1
    case turnOff = 128
    case turnOn = 256
}

/// Pure mapping from (action, entity) to the HA service to call.
enum ServiceCallMapper {
    /// Entity-aware mapping. Climate power actions depend on the entity's
    /// `supported_features`, `hvac_modes` and the last mode used; everything else maps by entity id.
    static func serviceCall(for action: EntityAction, entity: Entity, lastHvacMode: String? = nil) -> ServiceCall? {
        guard entity.domain == .climate else {
            return serviceCall(for: action, entityId: entity.entityId)
        }
        switch action {
        case .turnOn: return climateTurnOn(entity, lastHvacMode: lastHvacMode)
        case .turnOff: return climateTurnOff(entity)
        case .toggle:
            return entity.isOn ? climateTurnOff(entity) : climateTurnOn(entity, lastHvacMode: lastHvacMode)
        default: return serviceCall(for: action, entityId: entity.entityId)
        }
    }

    /// Always restores an explicit mode. `climate.turn_on` is avoided because HA's default
    /// implementation picks HEAT_COOL → HEAT → COOL, which turns most ACs on in heat mode.
    private static func climateTurnOn(_ entity: Entity, lastHvacMode: String?) -> ServiceCall {
        if let mode = entity.restoreHvacMode(lastUsed: lastHvacMode) {
            return ServiceCall(domain: "climate", service: "set_hvac_mode", entityId: entity.entityId,
                               data: ["hvac_mode": .string(mode)])
        }
        return ServiceCall(domain: "climate", service: "turn_on", entityId: entity.entityId)
    }

    private static func climateTurnOff(_ entity: Entity) -> ServiceCall {
        if entity.supportsClimateFeature(.turnOff) {
            return ServiceCall(domain: "climate", service: "turn_off", entityId: entity.entityId)
        }
        return ServiceCall(domain: "climate", service: "set_hvac_mode", entityId: entity.entityId,
                           data: ["hvac_mode": .string("off")])
    }

    static func serviceCall(for action: EntityAction, entityId: String) -> ServiceCall? {
        guard let domain = EntityDomain(entityId: entityId) else { return nil }
        func make(_ service: String, _ data: [String: JSONValue] = [:]) -> ServiceCall {
            ServiceCall(domain: domain.rawValue, service: service, entityId: entityId, data: data)
        }

        switch action {
        case .toggle:
            return domain.isToggleable ? make("toggle") : nil
        case .turnOn:
            return domain.isToggleable ? make("turn_on") : nil
        case .turnOff:
            return domain.isToggleable ? make("turn_off") : nil
        case .activate:
            switch domain {
            case .scene, .script: return make("turn_on")
            case .button, .inputButton: return make("press")
            default: return nil
            }
        case let .setBrightness(percent):
            guard domain == .light else { return nil }
            let clamped = min(max(percent, 0), 100)
            return clamped == 0 ? make("turn_off") : make("turn_on", ["brightness_pct": .number(Double(clamped))])
        case .openCover:
            return domain == .cover ? make("open_cover") : nil
        case .closeCover:
            return domain == .cover ? make("close_cover") : nil
        case .stopCover:
            return domain == .cover ? make("stop_cover") : nil
        case let .setTemperature(value):
            return domain == .climate ? make("set_temperature", ["temperature": .number(value)]) : nil
        case let .setHvacMode(mode):
            return domain == .climate ? make("set_hvac_mode", ["hvac_mode": .string(mode)]) : nil
        }
    }
}
