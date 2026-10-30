import Foundation

struct PanelGroup: Identifiable, Equatable, Sendable {
    let section: PanelSection
    var entities: [Entity]
    var id: PanelSection { section }
}

struct CatalogGroup: Identifiable, Equatable, Sendable {
    let domain: EntityDomain
    var entities: [Entity]
    var id: EntityDomain { domain }
}

/// Pure layout logic for the panel and the entity picker.
enum PanelLayout {
    /// Groups pinned entities by section. Sections appear in the order their first entity was pinned;
    /// entities keep the user's order. Unknown/unloaded/unsupported ids are skipped.
    static func groups(pinned: [String], entities: [String: Entity]) -> [PanelGroup] {
        var groups: [PanelGroup] = []
        for id in pinned {
            guard let entity = entities[id], let section = entity.domain?.section else { continue }
            if let index = groups.firstIndex(where: { $0.section == section }) {
                groups[index].entities.append(entity)
            } else {
                groups.append(PanelGroup(section: section, entities: [entity]))
            }
        }
        return groups
    }

    /// Supported entities grouped by domain, sorted by name, filtered by a case-insensitive query
    /// matched against friendly name and entity id.
    static func catalog(entities: [Entity], query: String) -> [CatalogGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = entities.filter { entity in
            guard entity.domain != nil else { return false }
            guard !needle.isEmpty else { return true }
            return entity.friendlyName.localizedCaseInsensitiveContains(needle)
                || entity.entityId.localizedCaseInsensitiveContains(needle)
        }
        let byDomain = Dictionary(grouping: filtered) { $0.domain! }
        return EntityDomain.allCases.compactMap { domain in
            guard let items = byDomain[domain], !items.isEmpty else { return nil }
            let sorted = items.sorted {
                $0.friendlyName.localizedStandardCompare($1.friendlyName) == .orderedAscending
            }
            return CatalogGroup(domain: domain, entities: sorted)
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
