import AppKit
import Foundation
import Observation

enum SettingsTab: Hashable {
    case connection, entities
}

/// UI state for the panel: entity states, connection status and user actions.
@MainActor
@Observable
final class HomeStore {
    let settings: SettingsStore

    private(set) var entities: [String: Entity] = [:]
    private(set) var status: ConnectionStatus = .notConfigured
    private(set) var lastError: String?
    /// Home Assistant version reported by `auth_ok` on the current connection.
    private(set) var haVersion: String?
    /// Last hour of numeric values for pinned power sensors, keyed by entity id.
    private(set) var powerHistory: [String: [PowerSample]] = [:]
    var settingsTab: SettingsTab = .connection

    @ObservationIgnored private let client = HAWebSocketClient()
    @ObservationIgnored private var errorClearTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    init(settings: SettingsStore) {
        self.settings = settings
        client.onEvent = { [weak self] event in self?.handle(event) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.client.refresh() }
        }
    }

    // MARK: Derived state

    var groups: [PanelGroup] {
        PanelLayout.groups(pinned: settings.pinnedEntityIds, entities: entities)
    }

    func catalog(query: String) -> [CatalogGroup] {
        PanelLayout.catalog(entities: Array(entities.values), query: query)
    }

    // MARK: Connection

    /// Connects (or reconnects) with the current settings.
    func start() {
        guard let url = settings.webSocketURL, let token = settings.token() else {
            client.stop()
            entities = [:]
            powerHistory = [:]
            haVersion = nil
            status = .notConfigured
            return
        }
        client.connect(url: url, token: token)
    }

    func refresh() {
        if case .connected = status { client.refresh() } else { start() }
    }

    // MARK: Actions

    func perform(_ action: EntityAction, on entity: Entity) {
        let current = entities[entity.entityId] ?? entity
        let lastMode = settings.lastHvacMode(for: entity.entityId)
        guard let call = ServiceCallMapper.serviceCall(for: action, entity: current, lastHvacMode: lastMode)
        else { return }
        if let predicted = OptimisticUpdate.apply(action, to: current, lastHvacMode: lastMode) {
            entities[entity.entityId] = predicted
        }
        client.callService(call)
    }

    /// Pins or unpins an entity, loading sparkline history when a power sensor gets pinned.
    func togglePin(_ entityId: String) {
        settings.togglePin(entityId)
        if settings.isPinned(entityId) {
            loadPowerHistory(for: [entityId])
        } else {
            powerHistory[entityId] = nil
        }
    }

    /// Only confirmed states from HA are remembered, never optimistic predictions.
    private func rememberHvacMode(_ entity: Entity) {
        if let mode = entity.activeHvacMode { settings.recordHvacMode(mode, for: entity.entityId) }
    }

    // MARK: Power history

    private var pinnedPowerSensorIds: [String] {
        settings.pinnedEntityIds.filter { entities[$0]?.isPowerSensor == true }
    }

    private func loadPowerHistory(for ids: [String]) {
        let powerIds = ids.filter { entities[$0]?.isPowerSensor == true }
        guard !powerIds.isEmpty else { return }
        // Start tracking right away so live updates are kept while history loads.
        for id in powerIds where powerHistory[id] == nil { powerHistory[id] = [] }
        client.requestHistory(entityIds: powerIds, since: Date().addingTimeInterval(-PowerHistory.window))
    }

    private func mergeHistory(_ result: JSONValue?) {
        let now = Date()
        for (id, samples) in PowerHistory.parse(result) where powerHistory[id] != nil {
            powerHistory[id] = PowerHistory.merge(history: samples, live: powerHistory[id] ?? [], now: now)
        }
    }

    private func recordLiveSample(_ entity: Entity) {
        guard let existing = powerHistory[entity.entityId], let value = entity.numericState else { return }
        powerHistory[entity.entityId] = PowerHistory.appending(
            PowerSample(date: Date(), value: value), to: existing, now: Date()
        )
    }

    // MARK: Events

    private func handle(_ event: HAWebSocketClient.Event) {
        switch event {
        case let .status(newStatus):
            status = newStatus
        case let .serverVersion(version):
            haVersion = version
        case let .states(list):
            entities = Dictionary(list.map { ($0.entityId, $0) }, uniquingKeysWith: { _, last in last })
            list.forEach(rememberHvacMode)
            loadPowerHistory(for: pinnedPowerSensorIds)
        case let .history(result):
            mergeHistory(result)
        case let .stateChanged(entityId, entity):
            entities[entityId] = entity
            if let entity {
                recordLiveSample(entity)
                rememberHvacMode(entity)
            }
        case let .serviceError(message):
            showError(message)
            client.refresh()
        }
    }

    private func showError(_ message: String) {
        lastError = message
        errorClearTask?.cancel()
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }
}
