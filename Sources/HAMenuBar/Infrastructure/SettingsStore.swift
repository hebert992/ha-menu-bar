import Foundation
import Observation

/// User preferences: base URL, pinned entities and remembered HVAC modes in UserDefaults,
/// token in the Keychain.
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
    /// In-memory copy so the Keychain is not queried on every access. Never logged or displayed.
    private var cachedToken: String?

    private(set) var baseURLString: String
    private(set) var pinnedEntityIds: [String]
    /// Mirrors `pinnedEntityIds` for O(1) `isPinned`.
    private var pinnedSet: Set<String>
    /// Opaque per-entity map persisted for `ClimateMemory`; the rules live there.
    private(set) var lastHvacModes: [String: String]

    init(defaults: UserDefaults = .standard, tokenStore: any TokenStore = KeychainTokenStore()) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        baseURLString = defaults.string(forKey: Keys.baseURL) ?? ""
        let pinned = defaults.stringArray(forKey: Keys.pinned) ?? []
        pinnedEntityIds = pinned
        pinnedSet = Set(pinned)
        lastHvacModes = defaults.dictionary(forKey: Keys.lastHvacModes) as? [String: String] ?? [:]
        cachedToken = (try? tokenStore.readToken()).flatMap { $0?.isEmpty == false ? $0 : nil }
    }

    var hasToken: Bool { cachedToken != nil }
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
    }

    // MARK: Pinned entities

    func isPinned(_ entityId: String) -> Bool { pinnedSet.contains(entityId) }

    func togglePin(_ entityId: String) {
        if pinnedSet.remove(entityId) != nil {
            pinnedEntityIds.removeAll { $0 == entityId }
        } else {
            pinnedSet.insert(entityId)
            pinnedEntityIds.append(entityId)
        }
        persistPins()
    }

    func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        pinnedEntityIds = pinnedEntityIds.moving(fromOffsets: source, toOffset: destination)
        persistPins()
    }

    private func persistPins() {
        defaults.set(pinnedEntityIds, forKey: Keys.pinned)
    }

    // MARK: Climate

    func setLastHvacModes(_ modes: [String: String]) {
        lastHvacModes = modes
        defaults.set(modes, forKey: Keys.lastHvacModes)
    }
}
