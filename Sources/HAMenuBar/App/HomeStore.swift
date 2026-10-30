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

    /// Supported entities only, keyed by entity id.
    private(set) var entities: [String: Entity] = [:]
    private(set) var status: ConnectionStatus = .notConfigured
    private(set) var lastError: String?
    /// Pinned entities grouped for the panel. Rebuilt only when pins or a pinned entity change.
    private(set) var groups: [PanelGroup] = []
    /// Picker sections for `catalogQuery`. Rebuilt only when the query or entity ids/names change.
    private(set) var catalog: [CatalogGroup] = []
    private(set) var catalogQuery = ""
    /// Last hour of numeric values for pinned power sensors, keyed by entity id.
    private(set) var powerHistory: [String: [PowerSample]] = [:]
    var settingsTab: SettingsTab = .connection

    @ObservationIgnored private let client = HAWebSocketClient()
    @ObservationIgnored private var climateMemory: ClimateMemory
    @ObservationIgnored private var catalogEntries: [CatalogEntry] = []
    /// Pre-action entity snapshots, keyed by service call id, restored if the call fails.
    @ObservationIgnored private var rollbacks: [Int: Entity] = [:]
    /// Power sensors whose history request has not answered yet, with the start time requested.
    @ObservationIgnored private var historyInFlight: [String: Date] = [:]
    @ObservationIgnored private var errorClearTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    init(settings: SettingsStore) {
        self.settings = settings
        climateMemory = ClimateMemory(lastModes: settings.lastHvacModes)
        client.onEvent = { [weak self] event in self?.handle(event) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.client.refresh() }
        }
    }

    // MARK: Connection

    /// Connects (or reconnects) with the current settings.
    func start() {
        guard let url = settings.webSocketURL, let token = settings.token() else {
            client.stop()
            status = .notConfigured
            powerHistory = [:]
            replaceEntities([])
            return
        }
        client.connect(url: url, token: token)
    }

    func refresh() {
        if status.isConnected { client.refresh() } else { start() }
    }

    // MARK: Actions

    func perform(_ action: EntityAction, on entity: Entity) {
        let id = entity.entityId
        let current = entities[id] ?? entity
        guard let command = action.resolved(for: current, lastHvacMode: climateMemory.lastMode(for: id)),
              let call = ServiceCallMapper.serviceCall(for: command, entityId: id)
        else { return }

        switch client.callService(call) {
        case .notConnected:
            showError("Not connected to Home Assistant.")
            client.refresh()
        case let .sent(callId):
            if let predicted = OptimisticUpdate.apply(command, to: current) {
                rollbacks[callId] = current
                setEntity(predicted, for: id)
            }
        }
    }

    // MARK: Pins (every pin mutation goes through here)

    func togglePin(_ entityId: String) {
        settings.togglePin(entityId)
        if settings.isPinned(entityId), let entity = entities[entityId] {
            rememberClimateModes([entity])
        }
        rebuildGroups()
        reconcilePowerTracking(fillGaps: false)
    }

    func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        settings.movePinned(fromOffsets: source, toOffset: destination)
        rebuildGroups()
    }

    // MARK: Picker

    func setCatalogQuery(_ query: String) {
        guard query != catalogQuery else { return }
        catalogQuery = query
        rebuildCatalog()
    }

    // MARK: Events

    private func handle(_ event: HAWebSocketClient.Event) {
        switch event {
        case let .status(newStatus):
            status = newStatus
            if !newStatus.isConnected {
                // In-flight requests died with the socket; their answers will never arrive.
                rollbacks.removeAll()
                historyInFlight.removeAll()
            }
        case let .states(list):
            replaceEntities(list)
            rememberClimateModes(settings.pinnedEntityIds.compactMap { entities[$0] })
            // `.states` follows every (re)connect: fetch only what was missed while disconnected.
            reconcilePowerTracking(fillGaps: true)
        case let .stateChanged(entityId, entity):
            ingest(entityId: entityId, entity: entity)
        case let .history(requested, samples):
            let now = Date()
            for id in requested {
                guard let since = historyInFlight.removeValue(forKey: id),
                      let history = samples[id], let live = powerHistory[id]
                else { continue }
                powerHistory[id] = PowerHistory.merge(history: history, live: live, since: since, now: now)
            }
        case let .serviceResult(id, errorMessage):
            let snapshot = rollbacks.removeValue(forKey: id)
            guard let errorMessage else { return }
            if let snapshot { setEntity(snapshot, for: snapshot.entityId) }
            showError(errorMessage)
        }
    }

    /// Hot path: called for every `state_changed` in the whole HA instance.
    private func ingest(entityId: String, entity: Entity?) {
        guard EntityDomain(entityId: entityId) != nil, entities[entityId] != entity else { return }
        setEntity(entity, for: entityId)
        guard let entity, settings.isPinned(entityId) else { return }
        recordLiveSample(entity)
        rememberClimateModes([entity])
    }

    // MARK: Entity storage

    private func replaceEntities(_ list: [Entity]) {
        var map: [String: Entity] = [:]
        for entity in list where entity.domain != nil { map[entity.entityId] = entity }
        entities = map
        rebuildGroups()
        rebuildCatalogEntries()
    }

    /// Updates one entity and refreshes only the caches it affects.
    private func setEntity(_ entity: Entity?, for entityId: String) {
        let previousName = entities[entityId]?.friendlyName
        entities[entityId] = entity
        if settings.isPinned(entityId) { rebuildGroups() }
        if previousName != entity?.friendlyName { rebuildCatalogEntries() }
    }

    private func rebuildGroups() {
        groups = PanelLayout.groups(pinned: settings.pinnedEntityIds, entities: entities)
    }

    private func rebuildCatalogEntries() {
        catalogEntries = PanelLayout.catalogEntries(from: entities.values)
        rebuildCatalog()
    }

    private func rebuildCatalog() {
        catalog = PanelLayout.catalog(entries: catalogEntries, query: catalogQuery)
    }

    // MARK: Climate memory

    /// Records running modes of confirmed (never optimistic) states, with one write per batch.
    private func rememberClimateModes(_ candidates: [Entity]) {
        var changed = false
        for entity in candidates where entity.kind == .climate {
            changed = climateMemory.record(entity) || changed
        }
        if changed { settings.setLastHvacModes(climateMemory.lastModes) }
    }

    // MARK: Power history

    /// Tracks exactly the pinned power sensors and requests the history they lack: the full hour for
    /// empty buffers and, when `fillGaps` is set (after a reconnect), only the time since each
    /// buffer's last sample. One request covers all sensors; `merge` uses each sensor's own start.
    private func reconcilePowerTracking(fillGaps: Bool) {
        let wanted = Set(settings.pinnedEntityIds.filter { entities[$0]?.isPowerSensor == true })
        for id in powerHistory.keys where !wanted.contains(id) { powerHistory[id] = nil }
        for id in wanted where powerHistory[id] == nil { powerHistory[id] = [] }
        guard status.isConnected else { return }

        let now = Date()
        var starts: [String: Date] = [:]
        for id in wanted where historyInFlight[id] == nil {
            let buffer = powerHistory[id] ?? []
            guard buffer.isEmpty || fillGaps else { continue }
            starts[id] = PowerHistory.historyStart(for: buffer, now: now)
        }
        guard let earliest = starts.values.min() else { return }
        historyInFlight.merge(starts) { _, new in new }
        client.requestHistory(entityIds: starts.keys.sorted(), since: earliest)
    }

    private func recordLiveSample(_ entity: Entity) {
        guard let existing = powerHistory[entity.entityId], let value = entity.numericState else { return }
        let now = Date()
        powerHistory[entity.entityId] = PowerHistory.appending(
            PowerSample(date: now, value: value), to: existing, now: now
        )
    }

    // MARK: Errors

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
