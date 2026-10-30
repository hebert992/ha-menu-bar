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

    private func call(_ action: EntityAction, _ entity: Entity, lastMode: String? = nil) -> ServiceCall? {
        ServiceCallMapper.serviceCall(for: action, entity: entity, lastHvacMode: lastMode)
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
        #expect(climate("off", modes: modes).restoreHvacMode(lastUsed: nil) == expected)
    }

    @Test func lastUsedModeRules() {
        let entity = climate("off", modes: ["off", "heat", "cool"])
        #expect(entity.restoreHvacMode(lastUsed: "heat") == "heat")
        // A mode the device no longer offers, or "off", is ignored.
        #expect(entity.restoreHvacMode(lastUsed: "dry") == "cool")
        #expect(entity.restoreHvacMode(lastUsed: "off") == "cool")
        // With unknown modes, the last used one is still the best guess.
        #expect(climate("off", modes: []).restoreHvacMode(lastUsed: "dry") == "dry")
    }

    @Test func noUsableModeFallsBackToTurnOnService() {
        #expect(climate("off", modes: ["off"]).restoreHvacMode(lastUsed: nil) == nil)
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

    @Test func entityOverloadDelegatesForOtherDomains() {
        let light = Entity(entityId: "light.desk", state: "on", attributes: [:])
        #expect(call(.toggle, light) == ServiceCall(domain: "light", service: "toggle", entityId: "light.desk"))
        #expect(call(.setTemperature(22), climate("cool"))?.data["temperature"] == .number(22))
    }
}

@Suite("Optimistic updates")
struct OptimisticUpdateTests {
    @Test func climateTurnOnUsesPreferredMode() {
        let entity = Entity(entityId: "climate.a", state: "off", attributes: [
            "hvac_modes": .array([.string("off"), .string("heat"), .string("cool")]),
        ])
        #expect(OptimisticUpdate.apply(.turnOn, to: entity)?.state == "cool")
        #expect(OptimisticUpdate.apply(.toggle, to: entity)?.state == "cool")
        #expect(OptimisticUpdate.apply(.turnOn, to: entity, lastHvacMode: "heat")?.state == "heat")
        #expect(OptimisticUpdate.apply(.setHvacMode("dry"), to: entity)?.state == "dry")
    }

    @Test func climateTurnOff() {
        let entity = Entity(entityId: "climate.a", state: "cool", attributes: [:])
        #expect(OptimisticUpdate.apply(.turnOff, to: entity)?.state == "off")
        #expect(OptimisticUpdate.apply(.toggle, to: entity)?.state == "off")
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
        #expect(ConnectionStatus.connected.label(haVersion: "2026.10.1") == "Connected · Home Assistant 2026.10.1")
        #expect(ConnectionStatus.connected.label(haVersion: nil) == "Connected")
        #expect(ConnectionStatus.connecting.label(haVersion: "x") == "Connecting…")
        #expect(ConnectionStatus.error("Boom").label(haVersion: nil) == "Error: Boom")
        #expect(ConnectionStatus.notConfigured.label(haVersion: nil) == "Not configured")
    }

    @Test func indicators() {
        #expect(ConnectionStatus.connected.indicator == .ok)
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
