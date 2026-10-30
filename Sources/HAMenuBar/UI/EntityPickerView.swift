import SwiftUI

/// Searchable list of supported entities with pin checkboxes, plus a reorderable list of pinned ones.
struct EntityPickerView: View {
    @Environment(HomeStore.self) private var store
    @State private var query = ""

    private var settings: SettingsStore { store.settings }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(12)
            Divider()
            if store.entities.isEmpty {
                placeholder
            } else {
                list
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search entities", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Spacer()
            if store.status == .connected {
                ProgressView().controlSize(.small)
                Text("Loading entities…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "network.slash").font(.title2).foregroundStyle(.secondary)
                Text("Connect to Home Assistant to choose entities.")
                    .foregroundStyle(.secondary)
                Button("Connection Settings") { store.settingsTab = .connection }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        List {
            if query.isEmpty && !settings.pinnedEntityIds.isEmpty {
                Section {
                    ForEach(settings.pinnedEntityIds, id: \.self) { id in
                        pinnedRow(id)
                    }
                    .onMove { settings.movePinned(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Pinned — drag to reorder")
                }
            }

            ForEach(store.catalog(query: query)) { group in
                Section(group.domain.displayName) {
                    ForEach(group.entities) { entity in
                        catalogRow(entity)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func pinnedRow(_ id: String) -> some View {
        let entity = store.entities[id]
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            if let entity {
                IconBadge(symbol: entity.symbolName, tint: entity.tint, size: 22)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(entity?.friendlyName ?? id)
                Text(id).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.togglePin(id) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Unpin")
        }
        .padding(.vertical, 2)
    }

    private func catalogRow(_ entity: Entity) -> some View {
        Toggle(isOn: Binding(
            get: { settings.isPinned(entity.entityId) },
            set: { _ in store.togglePin(entity.entityId) }
        )) {
            HStack(spacing: 10) {
                IconBadge(symbol: entity.symbolName, tint: entity.tint, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entity.friendlyName)
                    Text(entity.entityId).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entity.displayState)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
    }
}
