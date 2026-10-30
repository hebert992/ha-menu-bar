import SwiftUI

/// Searchable list of supported entities with pin checkboxes, plus a reorderable list of pinned ones.
struct EntityPickerView: View {
    @Environment(HomeStore.self) private var store

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
        // The query is view-scoped: start fresh each time the picker is shown.
        .onDisappear { store.setCatalogQuery("") }
    }

    private var query: Binding<String> {
        Binding(get: { store.catalogQuery }, set: { store.setCatalogQuery($0) })
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search entities", text: query)
                .textFieldStyle(.plain)
            if !store.catalogQuery.isEmpty {
                Button { store.setCatalogQuery("") } label: {
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
            if store.status.isConnected {
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
            if store.catalogQuery.isEmpty && !settings.pinnedEntityIds.isEmpty {
                Section {
                    ForEach(settings.pinnedEntityIds, id: \.self) { id in
                        pinnedRow(id)
                    }
                    .onMove { store.movePinned(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Pinned — drag to reorder")
                }
            }

            ForEach(store.catalog) { group in
                Section(group.domain.displayName) {
                    ForEach(group.entityIds, id: \.self) { id in
                        if let entity = store.entities[id] {
                            catalogRow(entity)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// Picker variant of the panel row label: smaller icon, body font, entity id underneath.
    private func label(for entity: Entity) -> some View {
        EntityRowLabel(entity: entity, active: true, iconSize: 22, nameFont: .body) {
            Text(entity.entityId).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pinnedRow(_ id: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            if let entity = store.entities[id] {
                label(for: entity)
            } else {
                Text(id)
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
                label(for: entity)
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
