import Foundation

/// Remembers the last HVAC mode each climate entity ran in, so power-on can restore it.
/// Rules: only running modes are recorded (never `off`, unavailable or unknown).
struct ClimateMemory: Equatable, Sendable {
    private(set) var lastModes: [String: String]

    init(lastModes: [String: String] = [:]) {
        self.lastModes = lastModes
    }

    func lastMode(for entityId: String) -> String? { lastModes[entityId] }

    /// Records the entity's running mode. Returns true when the stored value changed.
    @discardableResult
    mutating func record(_ entity: Entity) -> Bool {
        guard let mode = entity.activeHvacMode, lastModes[entity.entityId] != mode else { return false }
        lastModes[entity.entityId] = mode
        return true
    }

    /// The mode to restore when powering on: the last mode used, if the device still offers it
    /// (or its modes are unknown); otherwise cool, heat_cool, auto, dry, fan_only, heat, then the
    /// first non-off mode. Nil means only `climate.turn_on` is left.
    static func restoreMode(for entity: Entity, lastUsed: String?) -> String? {
        let modes = entity.hvacModes
        if let lastUsed, lastUsed != "off", modes.isEmpty || modes.contains(lastUsed) {
            return lastUsed
        }
        for preferred in ["cool", "heat_cool", "auto", "dry", "fan_only", "heat"] where modes.contains(preferred) {
            return preferred
        }
        return modes.first { $0 != "off" }
    }
}
