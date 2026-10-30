import Foundation

struct PanelGroup: Identifiable, Equatable, Sendable {
    let section: PanelSection
    var entities: [Entity]
    var id: PanelSection { section }
}

/// One picker row's identity. Only ids and names matter, so state changes don't rebuild the catalog.
struct CatalogEntry: Equatable, Sendable {
    let entityId: String
    let name: String
    let domain: EntityDomain
}

/// Picker section. Holds ids only; rows read live state from the store.
struct CatalogGroup: Identifiable, Equatable, Sendable {
    let domain: EntityDomain
    var entityIds: [String]
    var id: EntityDomain { domain }
}

/// Pure layout logic for the panel and the entity picker.
enum PanelLayout {
    /// Groups pinned entities by section. Sections appear in the order their first entity was pinned;
    /// entities keep the user's order. Unknown/unloaded/unsupported ids are skipped.
    static func groups(pinned: [String], entities: [String: Entity]) -> [PanelGroup] {
        var groups: [PanelGroup] = []
        for id in pinned {
            guard let entity = entities[id], let section = entity.kind?.section else { continue }
            if let index = groups.firstIndex(where: { $0.section == section }) {
                groups[index].entities.append(entity)
            } else {
                groups.append(PanelGroup(section: section, entities: [entity]))
            }
        }
        return groups
    }

    /// Supported entities as picker entries, sorted once by name (natural order: "Lamp 2" < "Lamp 10").
    /// Sorting by entity id breaks ties so the result is deterministic.
    static func catalogEntries(from entities: some Sequence<Entity>) -> [CatalogEntry] {
        entities
            .compactMap { entity in
                entity.domain.map { CatalogEntry(entityId: entity.entityId, name: entity.friendlyName, domain: $0) }
            }
            .sorted {
                switch $0.name.localizedStandardCompare($1.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: $0.entityId < $1.entityId
                }
            }
    }

    /// Entries grouped by domain (in `EntityDomain` order), filtered by a case-insensitive query
    /// matched against name and entity id. Entries must already be sorted (see `catalogEntries`).
    static func catalog(entries: [CatalogEntry], query: String) -> [CatalogGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var byDomain: [EntityDomain: [String]] = [:]
        for entry in entries
        where needle.isEmpty || entry.name.localizedCaseInsensitiveContains(needle)
            || entry.entityId.localizedCaseInsensitiveContains(needle) {
            byDomain[entry.domain, default: []].append(entry.entityId)
        }
        return EntityDomain.allCases.compactMap { domain in
            byDomain[domain].map { CatalogGroup(domain: domain, entityIds: $0) }
        }
    }
}

extension Array {
    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`, without importing SwiftUI.
    func moving(fromOffsets source: IndexSet, toOffset destination: Int) -> [Element] {
        let moving = source.compactMap { indices.contains($0) ? self[$0] : nil }
        var remaining = enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: Swift.min(Swift.max(insertAt, 0), remaining.count))
        return remaining
    }
}
