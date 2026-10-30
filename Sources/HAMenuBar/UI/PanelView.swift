import AppKit
import SwiftUI

/// The popover panel shown from the menu bar icon.
struct PanelView: View {
    @Environment(HomeStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var contentHeight: CGFloat = 0

    private var showSettings: SettingsOpener { SettingsOpener(store: store, openSettings: openSettings) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

            content

            if let error = store.lastError {
                errorBanner(error)
            }
        }
        .frame(width: Theme.panelWidth)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: store.lastError)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Home")
                .font(.system(size: 15, weight: .bold))
            StatusDot(status: store.status, haVersion: store.haVersion)
            if case .connecting = store.status {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Button { showSettings(.entities) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(CircleIconButtonStyle())
            .help("Choose entities")

            Menu {
                Button("Settings…") { showSettings(.connection) }
                    .keyboardShortcut(",")
                Button("Refresh") { store.refresh() }
                    .keyboardShortcut("r")
                Divider()
                Button("Quit HA Menu Bar") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.controlFill))
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !store.settings.isConfigured {
            EmptyStateView(
                symbol: "house.and.flag.fill",
                title: "Connect to Home Assistant",
                message: "Add your server URL and a long-lived access token to get started.",
                actionTitle: "Open Settings"
            ) { showSettings(.connection) }
        } else if store.settings.pinnedEntityIds.isEmpty {
            EmptyStateView(
                symbol: "pin.fill",
                title: "Nothing pinned yet",
                message: "Pick the lights, scenes and sensors you want at hand.",
                actionTitle: "Choose Entities"
            ) { showSettings(.entities) }
        } else if store.groups.isEmpty {
            loadingState
        } else {
            ScrollView(.vertical) {
                sections
                    .padding(12)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                        }
                    )
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(contentHeight, 60), Theme.maxContentHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(store.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: group.section.title)
                    SectionContent(group: group)
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            if case let .error(message) = store.status {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 22))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { store.refresh() }
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
                Text("Loading entities…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 11.5))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.18))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Renders a section with the layout appropriate for its domains.
private struct SectionContent: View {
    let group: PanelGroup

    var body: some View {
        switch group.section {
        case .actions:
            ActionTileGrid(entities: group.entities)
        default:
            Card {
                ForEach(Array(group.entities.enumerated()), id: \.element.id) { index, entity in
                    if index > 0 { RowDivider() }
                    EntityRow(entity: entity)
                }
            }
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            IconBadge(symbol: symbol, tint: .accentColor, size: 44)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 28)
    }
}
