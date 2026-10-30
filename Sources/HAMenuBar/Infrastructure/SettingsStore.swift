import Foundation
import Observation

/// User preferences: base URL and pinned entities in UserDefaults, token in the Keychain.
@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let baseURL = "baseURL"
        static let pinned = "pinnedEntityIds"
        static let lastHvacModes = "lastHvacModes"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokenStore: any TokenStore
    /// In-memory cache so the Keychain is not queried on every access. Never logged or displayed.
    @ObservationIgnored private var cachedToken: String?
    /// Last non-off HVAC mode seen per climate entity, restored on power-on.
    @ObservationIgnored private var lastHvacModes: [String: String]

    private(set) var baseURLString: String
    private(set) var pinnedEntityIds: [String]
    private(set) var hasToken: Bool

    init(defaults: UserDefaults = .standard, tokenStore: any TokenStore = KeychainTokenStore()) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        baseURLString = defaults.string(forKey: Keys.baseURL) ?? ""
        pinnedEntityIds = defaults.stringArray(forKey: Keys.pinned) ?? []
        lastHvacModes = defaults.dictionary(forKey: Keys.lastHvacModes) as? [String: String] ?? [:]
        cachedToken = (try? tokenStore.readToken()).flatMap { $0?.isEmpty == false ? $0 : nil }
        hasToken = cachedToken != nil
    }

    var webSocketURL: URL? { HAEndpoint.webSocketURL(from: baseURLString) }
    var isConfigured: Bool { webSocketURL != nil && hasToken }

    // MARK: Connection

    func setBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURLString = trimmed
        defaults.set(trimmed, forKey: Keys.baseURL)
    }

    func token() -> String? { cachedToken }

    /// Saves the token to the Keychain. An empty value deletes it.
    func saveToken(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try tokenStore.deleteToken()
            cachedToken = nil
        } else {
            try tokenStore.saveToken(trimmed)
            cachedToken = trimmed
        }
        hasToken = cachedToken != nil
    }

    // MARK: Pinned entities

    func isPinned(_ entityId: String) -> Bool { pinnedEntityIds.contains(entityId) }

    func togglePin(_ entityId: String) {
        if let index = pinnedEntityIds.firstIndex(of: entityId) {
            pinnedEntityIds.remove(at: index)
        } else {
            pinnedEntityIds.append(entityId)
        }
        persistPins()
    }

    func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        pinnedEntityIds = pinnedEntityIds.moving(fromOffsets: source, toOffset: destination)
        persistPins()
    }

    // MARK: Climate

    func lastHvacMode(for entityId: String) -> String? { lastHvacModes[entityId] }

    func recordHvacMode(_ mode: String, for entityId: String) {
        guard mode != "off", lastHvacModes[entityId] != mode else { return }
        lastHvacModes[entityId] = mode
        defaults.set(lastHvacModes, forKey: Keys.lastHvacModes)
    }

    private func persistPins() {
        defaults.set(pinnedEntityIds, forKey: Keys.pinned)
    }
}
