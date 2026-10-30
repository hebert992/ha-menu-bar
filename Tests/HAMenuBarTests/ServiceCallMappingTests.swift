import Testing
@testable import HAMenuBar

@Suite("Service call mapping")
struct ServiceCallMappingTests {
    private func call(_ action: EntityAction, _ entityId: String) -> ServiceCall? {
        ServiceCallMapper.serviceCall(for: action, entityId: entityId)
    }

    @Test(arguments: [
        ("light.kitchen", "light"),
        ("switch.plug", "switch"),
        ("input_boolean.guest", "input_boolean"),
        ("fan.bedroom", "fan"),
        ("automation.morning", "automation"),
    ])
    func toggleUsesDomainToggle(entityId: String, domain: String) {
        #expect(call(.toggle, entityId) == ServiceCall(domain: domain, service: "toggle", entityId: entityId))
    }

    @Test func turnOnAndOff() {
        #expect(call(.turnOn, "switch.a") == ServiceCall(domain: "switch", service: "turn_on", entityId: "switch.a"))
        #expect(call(.turnOff, "fan.b") == ServiceCall(domain: "fan", service: "turn_off", entityId: "fan.b"))
    }

    @Test func brightnessUsesTurnOnWithPercent() {
        #expect(call(.setBrightness(percent: 42), "light.desk") == ServiceCall(
            domain: "light", service: "turn_on", entityId: "light.desk",
            data: ["brightness_pct": .number(42)]
        ))
    }

    @Test func brightnessIsClampedAndZeroTurnsOff() {
        #expect(call(.setBrightness(percent: 150), "light.desk")?.data["brightness_pct"] == .number(100))
        #expect(call(.setBrightness(percent: 0), "light.desk") == ServiceCall(
            domain: "light", service: "turn_off", entityId: "light.desk"
        ))
    }

    @Test func brightnessOnlyForLights() {
        #expect(call(.setBrightness(percent: 50), "switch.a") == nil)
    }

    @Test func activateMapsPerDomain() {
        #expect(call(.activate, "scene.movie") == ServiceCall(domain: "scene", service: "turn_on", entityId: "scene.movie"))
        #expect(call(.activate, "script.night") == ServiceCall(domain: "script", service: "turn_on", entityId: "script.night"))
        #expect(call(.activate, "button.reboot") == ServiceCall(domain: "button", service: "press", entityId: "button.reboot"))
        #expect(call(.activate, "input_button.bell") == ServiceCall(domain: "input_button", service: "press", entityId: "input_button.bell"))
        #expect(call(.activate, "light.x") == nil)
    }

    @Test func coverActions() {
        #expect(call(.openCover, "cover.garage") == ServiceCall(domain: "cover", service: "open_cover", entityId: "cover.garage"))
        #expect(call(.closeCover, "cover.garage") == ServiceCall(domain: "cover", service: "close_cover", entityId: "cover.garage"))
        #expect(call(.stopCover, "cover.garage") == ServiceCall(domain: "cover", service: "stop_cover", entityId: "cover.garage"))
        #expect(call(.openCover, "switch.a") == nil)
    }

    @Test func climateSetTemperature() {
        #expect(call(.setTemperature(21.5), "climate.hall") == ServiceCall(
            domain: "climate", service: "set_temperature", entityId: "climate.hall",
            data: ["temperature": .number(21.5)]
        ))
        #expect(call(.setTemperature(21.5), "light.a") == nil)
    }

    @Test func readOnlyDomainsHaveNoActions() {
        #expect(call(.toggle, "sensor.temp") == nil)
        #expect(call(.toggle, "binary_sensor.door") == nil)
        #expect(call(.toggle, "media_player.tv") == nil)
    }
}
