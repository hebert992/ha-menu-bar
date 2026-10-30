import Foundation
import Testing
@testable import HAMenuBar

@Suite("Entity parsing")
struct EntityParsingTests {
    private func decode(_ json: String) throws -> Entity {
        try JSONDecoder().decode(Entity.self, from: Data(json.utf8))
    }

    @Test func parsesLightWithBrightness() throws {
        let entity = try decode("""
        {
          "entity_id": "light.kitchen",
          "state": "on",
          "attributes": {
            "friendly_name": "Kitchen",
            "brightness": 128,
            "supported_color_modes": ["color_temp", "xy"],
            "color_mode": "color_temp"
          },
          "last_changed": "2026-10-30T10:00:00+00:00"
        }
        """)
        #expect(entity.entityId == "light.kitchen")
        #expect(entity.domain == .light)
        #expect(entity.friendlyName == "Kitchen")
        #expect(entity.isOn)
        #expect(entity.brightness == 128)
        #expect(entity.brightnessPercent == 50)
        #expect(entity.supportsBrightness)
    }

    @Test func onOffOnlyLightDoesNotSupportBrightness() throws {
        let entity = try decode("""
        {"entity_id": "light.porch", "state": "off",
         "attributes": {"supported_color_modes": ["onoff"], "brightness": null}}
        """)
        #expect(!entity.supportsBrightness)
        #expect(!entity.isOn)
        #expect(entity.brightness == nil)
        #expect(entity.brightnessPercent == nil)
    }

    @Test func legacyLightWithBrightnessAttributeSupportsBrightness() throws {
        let entity = try decode("""
        {"entity_id": "light.old", "state": "on", "attributes": {"brightness": 255}}
        """)
        #expect(entity.supportsBrightness)
        #expect(entity.brightnessPercent == 100)
    }

    @Test func friendlyNameFallsBackToObjectId() throws {
        let entity = try decode("""
        {"entity_id": "switch.coffee_maker", "state": "off"}
        """)
        #expect(entity.friendlyName == "Coffee Maker")
        #expect(entity.attributes.isEmpty)
    }

    @Test func parsesSensorWithUnit() throws {
        let entity = try decode("""
        {"entity_id": "sensor.living_temp", "state": "21.4",
         "attributes": {"friendly_name": "Living Temp", "unit_of_measurement": "°C",
                        "device_class": "temperature"}}
        """)
        #expect(entity.domain == .sensor)
        #expect(entity.unit == "°C")
        #expect(entity.displayState == "21.4 °C")
    }

    @Test func parsesClimate() throws {
        let entity = try decode("""
        {"entity_id": "climate.hall", "state": "heat",
         "attributes": {"current_temperature": 19.5, "temperature": 21,
                        "min_temp": 7, "max_temp": 35, "hvac_action": "heating",
                        "friendly_name": "Hall"}}
        """)
        #expect(entity.domain == .climate)
        #expect(entity.currentTemperature == 19.5)
        #expect(entity.targetTemperature == 21)
        #expect(entity.minTemperature == 7)
        #expect(entity.maxTemperature == 35)
        #expect(entity.hvacMode == "heat")
    }

    @Test func climateTargetAdjustsInHalfStepsWithinBounds() throws {
        let entity = try decode("""
        {"entity_id": "climate.hall", "state": "heat",
         "attributes": {"temperature": 21, "min_temp": 20, "max_temp": 21.5}}
        """)
        #expect(entity.adjustedTargetTemperature(by: 0.5) == 21.5)
        #expect(entity.adjustedTargetTemperature(by: 0.5, from: 21.5) == 21.5)
        #expect(entity.adjustedTargetTemperature(by: -0.5, from: 20) == 20)
        #expect(entity.adjustedTargetTemperature(by: -0.5, from: 20.74) == 20.0)
    }

    @Test func climateWithoutSingleTargetCannotAdjust() throws {
        let entity = try decode("""
        {"entity_id": "climate.x", "state": "heat_cool",
         "attributes": {"target_temp_low": 18, "target_temp_high": 24}}
        """)
        #expect(entity.targetTemperature == nil)
        #expect(entity.adjustedTargetTemperature(by: 0.5) == nil)
    }

    @Test func binarySensorDisplayStateUsesDeviceClass() throws {
        let door = try decode("""
        {"entity_id": "binary_sensor.front_door", "state": "on",
         "attributes": {"device_class": "door"}}
        """)
        #expect(door.displayState == "Open")
        let motion = try decode("""
        {"entity_id": "binary_sensor.hall_motion", "state": "off",
         "attributes": {"device_class": "motion"}}
        """)
        #expect(motion.displayState == "Clear")
        let generic = try decode("""
        {"entity_id": "binary_sensor.thing", "state": "on"}
        """)
        #expect(generic.displayState == "On")
    }

    @Test func unavailableEntityIsFlagged() throws {
        let entity = try decode("""
        {"entity_id": "switch.x", "state": "unavailable"}
        """)
        #expect(entity.isUnavailable)
        #expect(entity.displayState == "Unavailable")
    }

    @Test func rejectsPayloadWithoutEntityId() {
        #expect(throws: (any Error).self) {
            try decode(#"{"state": "on"}"#)
        }
    }
}

@Suite("Domain detection")
struct DomainDetectionTests {
    @Test(arguments: [
        ("light.kitchen", EntityDomain.light),
        ("scene.movie", .scene),
        ("script.good_night", .script),
        ("button.restart", .button),
        ("input_button.doorbell", .inputButton),
        ("switch.plug", .switch),
        ("input_boolean.guest_mode", .inputBoolean),
        ("fan.bedroom", .fan),
        ("automation.lights_on", .automation),
        ("cover.garage", .cover),
        ("climate.hall", .climate),
        ("sensor.power", .sensor),
        ("binary_sensor.door", .binarySensor),
    ])
    func detectsSupportedDomains(entityId: String, expected: EntityDomain) {
        #expect(EntityDomain(entityId: entityId) == expected)
    }

    @Test(arguments: ["media_player.tv", "person.hebert", "nodot", "", ".light"])
    func rejectsUnsupportedOrMalformed(entityId: String) {
        #expect(EntityDomain(entityId: entityId) == nil)
    }

    @Test func domainsMapToPanelSections() {
        #expect(EntityDomain.scene.section == .actions)
        #expect(EntityDomain.inputButton.section == .actions)
        #expect(EntityDomain.light.section == .lights)
        #expect(EntityDomain.fan.section == .toggles)
        #expect(EntityDomain.cover.section == .covers)
        #expect(EntityDomain.climate.section == .climate)
        #expect(EntityDomain.binarySensor.section == .sensors)
    }
}
