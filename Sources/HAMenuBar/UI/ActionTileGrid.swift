import SwiftUI

/// Grid of compact tiles for scenes, scripts and buttons.
struct ActionTileGrid: View {
    let entities: [Entity]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(entities) { entity in
                ActionTile(entity: entity)
            }
        }
    }
}

private struct ActionTile: View {
    @Environment(HomeStore.self) private var store
    let entity: Entity

    @State private var hovering = false
    @State private var fired = false

    var body: some View {
        Button(action: activate) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    IconBadge(symbol: entity.symbolName, tint: entity.tint, active: !entity.isUnavailable, size: 28)
                        .opacity(fired ? 0 : 1)
                    IconBadge(symbol: "checkmark", tint: .green, size: 28)
                        .opacity(fired ? 1 : 0)
                }
                Text(entity.friendlyName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(fired ? entity.tint.opacity(0.28) : (hovering ? Theme.hoverFill.opacity(1.6) : Theme.cardFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(fired ? entity.tint.opacity(0.6) : Theme.cardStroke)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(entity.isUnavailable)
        .opacity(entity.isUnavailable ? 0.5 : 1)
        .onHover { hovering = $0 }
        .help(entity.entityId)
        .animation(.easeOut(duration: 0.18), value: fired)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func activate() {
        store.perform(.activate, on: entity)
        fired = true
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            fired = false
        }
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
