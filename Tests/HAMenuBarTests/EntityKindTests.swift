import Testing
@testable import HAMenuBar

@Suite("Entity kind")
struct EntityKindTests {
    private func entity(_ id: String, _ attributes: [String: JSONValue] = [:]) -> Entity {
        Entity(entityId: id, state: "on", attributes: attributes)
    }

    @Test(arguments: [
        ("scene.a", EntityKind.action), ("script.a", .action), ("button.a", .action), ("input_button.a", .action),
        ("light.a", .light),
        ("switch.a", .toggle), ("input_boolean.a", .toggle), ("fan.a", .toggle), ("automation.a", .toggle),
        ("cover.a", .cover), ("climate.a", .climate),
        ("sensor.a", .sensor), ("binary_sensor.a", .sensor),
    ])
    func kindPerDomain(id: String, kind: EntityKind) {
        #expect(entity(id).kind == kind)
    }

    @Test func powerSensorKind() {
        #expect(entity("sensor.p", ["device_class": .string("power")]).kind == .powerSensor)
        #expect(entity("sensor.p", ["unit_of_measurement": .string("W")]).kind == .powerSensor)
    }

    @Test func unsupportedHasNoKind() {
        #expect(entity("media_player.tv").kind == nil)
        #expect(entity("media_player.tv").domain == nil)
    }

    @Test func kindFollowsAttributeChanges() {
        var sensor = entity("sensor.p")
        sensor.attributes["unit_of_measurement"] = .string("kW")
        #expect(sensor.kind == .powerSensor)
    }

    @Test func toggleableKinds() {
        #expect(EntityKind.light.isToggleable)
        #expect(EntityKind.toggle.isToggleable)
        #expect(!EntityKind.climate.isToggleable)
        #expect(!EntityKind.action.isToggleable)
        #expect(EntityDomain.fan.isToggleable)
        #expect(!EntityDomain.cover.isToggleable)
    }
}

@Suite("String humanized")
struct HumanizedTests {
    @Test(arguments: [
        ("coffee_maker", "Coffee Maker"),
        ("fan_only", "Fan Only"),
        ("heating", "Heating"),
        ("", ""),
        ("a__b", "A B"),
    ])
    func humanizes(raw: String, expected: String) {
        #expect(raw.humanized == expected)
    }
}
