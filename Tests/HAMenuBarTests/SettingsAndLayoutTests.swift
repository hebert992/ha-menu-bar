import Foundation
import Testing
@testable import HAMenuBar

final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    func readToken() throws -> String? { lock.withLock { token } }
    func saveToken(_ token: String) throws { lock.withLock { self.token = token } }
    func deleteToken() throws { lock.withLock { token = nil } }
}

@MainActor
@Suite("Settings store")
struct SettingsStoreTests {
    private func makeStore() -> (SettingsStore, UserDefaults) {
        let suite = "HAMenuBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SettingsStore(defaults: defaults, tokenStore: InMemoryTokenStore()), defaults)
    }

    @Test func persistsBaseURLAndPins() {
        let (store, defaults) = makeStore()
        store.setBaseURL("http://ha.local:8123")
        store.togglePin("light.a")
        store.togglePin("switch.b")

        let reloaded = SettingsStore(defaults: defaults, tokenStore: InMemoryTokenStore())
        #expect(reloaded.baseURLString == "http://ha.local:8123")
        #expect(reloaded.pinnedEntityIds == ["light.a", "switch.b"])
    }

    @Test func togglePinRemovesExisting() {
        let (store, _) = makeStore()
        store.togglePin("light.a")
        store.togglePin("light.a")
        #expect(store.pinnedEntityIds.isEmpty)
        #expect(!store.isPinned("light.a"))
    }

    @Test func movesPinned() {
        let (store, _) = makeStore()
        ["a", "b", "c", "d"].forEach { store.togglePin($0) }
        store.movePinned(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(store.pinnedEntityIds == ["d", "a", "b", "c"])
        store.movePinned(fromOffsets: IndexSet([0, 1]), toOffset: 4)
        #expect(store.pinnedEntityIds == ["b", "c", "d", "a"])
    }

    @Test func tokenGoesToTokenStoreNotDefaults() throws {
        let (store, defaults) = makeStore()
        #expect(!store.hasToken)
        try store.saveToken("  secret-token \n")
        #expect(store.hasToken)
        #expect(store.token() == "secret-token")
        let allValues = defaults.dictionaryRepresentation().values.map { "\($0)" }
        #expect(!allValues.contains { $0.contains("secret-token") })
        try store.saveToken("")
        #expect(!store.hasToken)
    }

    @Test func remembersLastHvacModePerEntity() {
        let (store, defaults) = makeStore()
        #expect(store.lastHvacMode(for: "climate.a") == nil)
        store.recordHvacMode("cool", for: "climate.a")
        store.recordHvacMode("heat", for: "climate.b")
        store.recordHvacMode("dry", for: "climate.a")

        let reloaded = SettingsStore(defaults: defaults, tokenStore: InMemoryTokenStore())
        #expect(reloaded.lastHvacMode(for: "climate.a") == "dry")
        #expect(reloaded.lastHvacMode(for: "climate.b") == "heat")
    }

    @Test func ignoresOffWhenRecordingHvacMode() {
        let (store, _) = makeStore()
        store.recordHvacMode("cool", for: "climate.a")
        store.recordHvacMode("off", for: "climate.a")
        #expect(store.lastHvacMode(for: "climate.a") == "cool")
    }

    @Test func isConfiguredNeedsValidURLAndToken() throws {
        let (store, _) = makeStore()
        #expect(!store.isConfigured)
        store.setBaseURL("http://ha.local:8123")
        #expect(!store.isConfigured)
        try store.saveToken("t")
        #expect(store.isConfigured)
    }
}

@Suite("Array move")
struct ArrayMoveTests {
    @Test func matchesSwiftUISemantics() {
        #expect(["a", "b", "c"].moving(fromOffsets: IndexSet(integer: 0), toOffset: 3) == ["b", "c", "a"])
        #expect(["a", "b", "c"].moving(fromOffsets: IndexSet(integer: 2), toOffset: 0) == ["c", "a", "b"])
        #expect(["a", "b", "c"].moving(fromOffsets: IndexSet(integer: 1), toOffset: 1) == ["a", "b", "c"])
    }
}

@Suite("Panel layout")
struct PanelLayoutTests {
    private func entity(_ id: String, _ state: String = "on") -> Entity {
        Entity(entityId: id, state: state, attributes: [:])
    }

    @Test func groupsPinnedEntitiesBySectionInFirstAppearanceOrder() {
        let entities = Dictionary(uniqueKeysWithValues: [
            entity("light.a"), entity("scene.movie"), entity("light.b"),
            entity("sensor.temp", "21"), entity("script.night"), entity("media_player.tv"),
        ].map { ($0.entityId, $0) })

        let groups = PanelLayout.groups(
            pinned: ["light.b", "scene.movie", "sensor.temp", "light.a", "script.night",
                     "media_player.tv", "switch.not_loaded"],
            entities: entities
        )

        #expect(groups.map(\.section) == [.lights, .actions, .sensors])
        #expect(groups[0].entities.map(\.entityId) == ["light.b", "light.a"])
        #expect(groups[1].entities.map(\.entityId) == ["scene.movie", "script.night"])
        #expect(groups[2].entities.map(\.entityId) == ["sensor.temp"])
    }

    @Test func emptyWhenNothingPinned() {
        #expect(PanelLayout.groups(pinned: [], entities: ["light.a": entity("light.a")]).isEmpty)
    }

    @Test func pickerCatalogGroupsSupportedEntitiesAndFilters() {
        let entities = [
            Entity(entityId: "light.kitchen", state: "on", attributes: ["friendly_name": .string("Kitchen")]),
            Entity(entityId: "light.bath", state: "off", attributes: ["friendly_name": .string("Bathroom")]),
            Entity(entityId: "switch.kettle", state: "off", attributes: [:]),
            Entity(entityId: "media_player.tv", state: "off", attributes: [:]),
        ]
        let all = PanelLayout.catalog(entities: entities, query: "")
        #expect(all.map(\.domain) == [.light, .switch])
        #expect(all[0].entities.map(\.entityId) == ["light.bath", "light.kitchen"])

        let filtered = PanelLayout.catalog(entities: entities, query: "kit")
        #expect(filtered.map(\.domain) == [.light])
        #expect(filtered[0].entities.map(\.entityId) == ["light.kitchen"])

        let byId = PanelLayout.catalog(entities: entities, query: "kettle")
        #expect(byId.map(\.domain) == [.switch])
    }
}
