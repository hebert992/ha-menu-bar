import Foundation

/// A Home Assistant `call_service` request.
struct ServiceCall: Equatable, Sendable {
    var domain: String
    var service: String
    var entityId: String
    var data: [String: JSONValue] = [:]
}

/// Pure map from a resolved command (see `EntityAction.resolved`) to the HA service to call.
enum ServiceCallMapper {
    static func serviceCall(for action: EntityAction, entityId: String) -> ServiceCall? {
        guard let domain = EntityDomain(entityId: entityId) else { return nil }
        func make(_ service: String, _ data: [String: JSONValue] = [:]) -> ServiceCall {
            ServiceCall(domain: domain.rawValue, service: service, entityId: entityId, data: data)
        }
        let hasPower = domain.isToggleable || domain == .climate

        switch action {
        case .toggle:
            return domain.isToggleable ? make("toggle") : nil
        case .turnOn:
            return hasPower ? make("turn_on") : nil
        case .turnOff:
            return hasPower ? make("turn_off") : nil
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
