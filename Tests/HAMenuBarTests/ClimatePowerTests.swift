import Testing
@testable import HAMenuBar

@Suite("Climate on/off mapping")
struct ClimatePowerTests {
    private func climate(
        _ state: String,
        features: Int = 1,
        modes: [String] = ["off", "heat", "cool", "heat_cool", "auto"]
    ) -> Entity {
        Entity(entityId: "climate.studio", state: state, attributes: [
            "supported_features": .number(Double(features)),
            "hvac_modes": .array(modes.map(JSONValue.string)),
        ])
    }

    /// Resolve the intent against the entity, then map the concrete command, as HomeStore does.
    private func call(_ action: EntityAction, _ entity: Entity, lastMode: String? = nil) -> ServiceCall? {
        action.resolved(for: entity, lastHvacMode: lastMode)
            .flatMap { ServiceCallMapper.serviceCall(for: $0, entityId: entity.entityId) }
    }

    private func setMode(_ mode: String) -> ServiceCall {
        ServiceCall(domain: "climate", service: "set_hvac_mode", entityId: "climate.studio",
                    data: ["hvac_mode": .string(mode)])
    }

    @Test func climateIsOnUnlessOffOrUnavailable() {
        #expect(climate("cool").isOn)
        #expect(climate("heat_cool").isOn)
        #expect(!climate("off").isOn)
        #expect(!climate("unavailable").isOn)
    }

    @Test func parsesFeaturesAndModes() {
        let entity = climate("off", features: 385, modes: ["off", "cool"])
        #expect(entity.supportedFeatures == 385)
        #expect(entity.hvacModes == ["off", "cool"])
        #expect(entity.supportsClimateFeature(.turnOn))
        #expect(entity.supportsClimateFeature(.turnOff))
        #expect(!climate("off", features: 1).supportsClimateFeature(.turnOn))
    }

    @Test func turnOnSetsModeEvenWhenTurnOnFeatureIsAdvertised() {
        // HA's default turn_on fakes it with HEAT_COOL → HEAT → COOL, so an AC ends up heating.
        #expect(call(.turnOn, climate("off", features: 1 | 128 | 256)) == setMode("cool"))
    }

    @Test func turnOnRestoresLastUsedMode() {
        #expect(call(.turnOn, climate("off"), lastMode: "heat") == setMode("heat"))
    }

    @Test(arguments: [
        (["off", "heat", "cool", "auto"], "cool"),
        (["off", "heat", "heat_cool", "auto"], "heat_cool"),
        (["auto", "off", "heat"], "auto"),
        (["off", "heat", "dry"], "dry"),
        (["off", "heat", "fan_only"], "fan_only"),
        (["off", "heat"], "heat"),
        (["off", "eco"], "eco"),
    ])
    func defaultRestoreMode(modes: [String], expected: String) {
        #expect(ClimateMemory.restoreMode(for: climate("off", modes: modes), lastUsed: nil) == expected)
    }

    @Test func lastUsedModeRules() {
        let entity = climate("off", modes: ["off", "heat", "cool"])
        #expect(ClimateMemory.restoreMode(for: entity, lastUsed: "heat") == "heat")
        // A mode the device no longer offers, or "off", is ignored.
        #expect(ClimateMemory.restoreMode(for: entity, lastUsed: "dry") == "cool")
        #expect(ClimateMemory.restoreMode(for: entity, lastUsed: "off") == "cool")
        // With unknown modes, the last used one is still the best guess.
        #expect(ClimateMemory.restoreMode(for: climate("off", modes: []), lastUsed: "dry") == "dry")
    }

    @Test func noUsableModeFallsBackToTurnOnService() {
        #expect(ClimateMemory.restoreMode(for: climate("off", modes: ["off"]), lastUsed: nil) == nil)
        let turnOn = ServiceCall(domain: "climate", service: "turn_on", entityId: "climate.studio")
        #expect(call(.turnOn, climate("off", modes: [])) == turnOn)
        #expect(call(.turnOn, climate("off", modes: ["off"])) == turnOn)
    }

    @Test func setHvacModeMapsOnlyForClimate() {
        #expect(call(.setHvacMode("dry"), climate("cool")) == setMode("dry"))
        #expect(ServiceCallMapper.serviceCall(for: .setHvacMode("cool"), entityId: "light.a") == nil)
    }

    @Test func activeHvacModeIgnoresOffAndUnavailable() {
        #expect(climate("cool").activeHvacMode == "cool")
        #expect(climate("off").activeHvacMode == nil)
        #expect(climate("unavailable").activeHvacMode == nil)
        #expect(Entity(entityId: "switch.a", state: "on", attributes: [:]).activeHvacMode == nil)
    }

    @Test func turnOffUsesTurnOffServiceWhenSupported() {
        // TURN_OFF = 128 in ClimateEntityFeature.
        #expect(call(.turnOff, climate("cool", features: 1 | 128)) == ServiceCall(
            domain: "climate", service: "turn_off", entityId: "climate.studio"
        ))
    }

    @Test func turnOffFallsBackToHvacModeOff() {
        #expect(call(.turnOff, climate("cool", features: 1 | 256)) == ServiceCall(
            domain: "climate", service: "set_hvac_mode", entityId: "climate.studio",
            data: ["hvac_mode": .string("off")]
        ))
    }

    @Test func toggleDependsOnCurrentState() {
        #expect(call(.toggle, climate("cool", features: 128))?.service == "turn_off")
        #expect(call(.toggle, climate("off", features: 256)) == setMode("cool"))
    }

    @Test func resolvesClimatePowerIntentsToConcreteCommands() {
        #expect(EntityAction.turnOn.resolved(for: climate("off"), lastHvacMode: "heat") == .setHvacMode("heat"))
        #expect(EntityAction.turnOn.resolved(for: climate("off", modes: []), lastHvacMode: nil) == .turnOn)
        #expect(EntityAction.toggle.resolved(for: climate("cool", features: 128), lastHvacMode: nil) == .turnOff)
        #expect(EntityAction.toggle.resolved(for: climate("cool", features: 1), lastHvacMode: nil) == .setHvacMode("off"))
        #expect(EntityAction.setTemperature(20).resolved(for: climate("cool"), lastHvacMode: nil) == .setTemperature(20))
    }

    @Test func resolveLeavesOtherDomainsUntouched() {
        let light = Entity(entityId: "light.desk", state: "on", attributes: [:])
        #expect(EntityAction.toggle.resolved(for: light, lastHvacMode: "cool") == .toggle)
        #expect(EntityAction.turnOn.resolved(for: light, lastHvacMode: nil) == .turnOn)
    }

    @Test func entityOverloadDelegatesForOtherDomains() {
        let light = Entity(entityId: "light.desk", state: "on", attributes: [:])
        #expect(call(.toggle, light) == ServiceCall(domain: "light", service: "toggle", entityId: "light.desk"))
        #expect(call(.setTemperature(22), climate("cool"))?.data["temperature"] == .number(22))
    }
}

@Suite("Optimistic updates")
struct OptimisticUpdateTests {
    private func predict(_ action: EntityAction, _ entity: Entity, lastMode: String? = nil) -> Entity? {
        action.resolved(for: entity, lastHvacMode: lastMode).flatMap { OptimisticUpdate.apply($0, to: entity) }
    }

    @Test func climateTurnOnUsesPreferredMode() {
        let entity = Entity(entityId: "climate.a", state: "off", attributes: [
            "hvac_modes": .array([.string("off"), .string("heat"), .string("cool")]),
        ])
        #expect(predict(.turnOn, entity)?.state == "cool")
        #expect(predict(.toggle, entity)?.state == "cool")
        #expect(predict(.turnOn, entity, lastMode: "heat")?.state == "heat")
        #expect(predict(.setHvacMode("dry"), entity)?.state == "dry")
    }

    @Test func climateTurnOnFallbackHasNoPrediction() {
        let entity = Entity(entityId: "climate.a", state: "off", attributes: [:])
        #expect(predict(.turnOn, entity) == nil)
    }

    @Test func climateTurnOff() {
        let entity = Entity(entityId: "climate.a", state: "cool", attributes: [:])
        #expect(predict(.turnOff, entity)?.state == "off")
        #expect(predict(.toggle, entity)?.state == "off")
    }

    @Test func toggleAndBrightness() {
        let light = Entity(entityId: "light.a", state: "off", attributes: [:])
        #expect(OptimisticUpdate.apply(.toggle, to: light)?.state == "on")
        let dimmed = OptimisticUpdate.apply(.setBrightness(percent: 50), to: light)
        #expect(dimmed?.state == "on")
        #expect(dimmed?.brightnessPercent == 50)
    }

    @Test func unavailableAndNonStatefulActionsAreIgnored() {
        let gone = Entity(entityId: "switch.a", state: "unavailable", attributes: [:])
        #expect(OptimisticUpdate.apply(.toggle, to: gone) == nil)
        let scene = Entity(entityId: "scene.a", state: "scening", attributes: [:])
        #expect(OptimisticUpdate.apply(.activate, to: scene) == nil)
    }
}

@Suite("Connection status presentation")
struct ConnectionStatusTests {
    @Test func labels() {
        #expect(ConnectionStatus.connected(haVersion: "2026.10.1").label == "Connected · Home Assistant 2026.10.1")
        #expect(ConnectionStatus.connected(haVersion: nil).label == "Connected")
        #expect(ConnectionStatus.connecting.label == "Connecting…")
        #expect(ConnectionStatus.error("Boom").label == "Error: Boom")
        #expect(ConnectionStatus.notConfigured.label == "Not configured")
        #expect(ConnectionStatus.connected(haVersion: nil).isConnected)
        #expect(!ConnectionStatus.connecting.isConnected)
    }

    @Test func indicators() {
        #expect(ConnectionStatus.connected(haVersion: "1").indicator == .ok)
        #expect(ConnectionStatus.connecting.indicator == .pending)
        #expect(ConnectionStatus.error("x").indicator == .failure)
        #expect(ConnectionStatus.notConfigured.indicator == .inactive)
    }
}

@Suite("HVAC mode presentation")
struct HVACModePresentationTests {
    @Test(arguments: [
        ("cool", "Cool", "snowflake", HVACModeStyle.cooling),
        ("heat", "Heat", "flame.fill", .heating),
        ("dry", "Dry", "drop.fill", .drying),
        ("fan_only", "Fan only", "fan.fill", .fan),
        ("auto", "Auto", "arrow.triangle.2.circlepath", .auto),
        ("heat_cool", "Heat/Cool", "arrow.triangle.2.circlepath", .auto),
        ("off", "Off", "power", .off),
    ])
    func knownModes(mode: String, label: String, symbol: String, style: HVACModeStyle) {
        let info = HVACModeInfo(mode)
        #expect(info.label == label)
        #expect(info.symbolName == symbol)
        #expect(info.style == style)
    }

    @Test func unknownModeIsReadable() {
        let info = HVACModeInfo("eco_boost")
        #expect(info.label == "Eco Boost")
        #expect(info.style == .other)
    }
}

@Suite("Climate memory")
struct ClimateMemoryTests {
    private func climate(_ id: String, _ state: String) -> Entity {
        Entity(entityId: id, state: state, attributes: [:])
    }

    @Test func recordsRunningModeAndReportsChanges() {
        var memory = ClimateMemory()
        let first = memory.record(climate("climate.a", "cool"))
        let repeated = memory.record(climate("climate.a", "cool"))
        let changed = memory.record(climate("climate.a", "dry"))
        #expect(first)
        #expect(!repeated)
        #expect(changed)
        #expect(memory.lastMode(for: "climate.a") == "dry")
    }

    @Test func ignoresOffUnavailableAndOtherDomains() {
        var memory = ClimateMemory(lastModes: ["climate.a": "cool"])
        let changes = [
            memory.record(climate("climate.a", "off")),
            memory.record(climate("climate.a", "unavailable")),
            memory.record(Entity(entityId: "switch.a", state: "on", attributes: [:])),
        ]
        #expect(changes == [false, false, false])
        #expect(memory.lastModes == ["climate.a": "cool"])
    }
}
