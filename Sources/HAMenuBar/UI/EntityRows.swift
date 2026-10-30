import SwiftUI

/// Picks the row for an entity's kind and applies the shared row chrome once.
struct EntityRow: View {
    let entity: Entity

    var body: some View {
        Group {
            switch entity.kind {
            case .light: LightRow(entity: entity)
            case .toggle: ToggleRow(entity: entity)
            case .cover: CoverRow(entity: entity)
            case .climate: ClimateRow(entity: entity)
            case .powerSensor: PowerSensorRow(entity: entity)
            case .sensor, .action, nil: SensorRow(entity: entity)
            }
        }
        .entityRowChrome()
        .opacity(entity.isUnavailable ? 0.55 : 1)
    }
}

/// Icon + name + a subtitle slot. Used by every panel row and by the entity picker.
struct EntityRowLabel<Subtitle: View>: View {
    let entity: Entity
    var active: Bool
    var iconSize: CGFloat = 26
    var nameFont: Font = .system(size: 12.5, weight: .medium)
    @ViewBuilder var subtitle: Subtitle

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: entity.symbolName, tint: entity.tint, active: active, size: iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(entity.friendlyName)
                    .font(nameFont)
                    .lineLimit(1)
                subtitle
            }
        }
        .help(entity.entityId)
    }
}

extension EntityRowLabel where Subtitle == EntityRowSubtitle {
    /// Convenience for the common case of a plain secondary text line.
    init(entity: Entity, subtitle: String?, active: Bool) {
        self.init(entity: entity, active: active) { EntityRowSubtitle(text: subtitle) }
    }
}

/// Small secondary line under an entity name; renders nothing when `text` is nil.
struct EntityRowSubtitle: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }
}

private struct EntityToggle: View {
    @Environment(HomeStore.self) private var store
    let entity: Entity

    var body: some View {
        Toggle("", isOn: Binding(
            get: { entity.isOn },
            set: { store.perform($0 ? .turnOn : .turnOff, on: entity) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(entity.tint)
        .disabled(entity.isUnavailable)
    }
}

// MARK: - Light

private struct LightRow: View {
    @Environment(HomeStore.self) private var store
    let entity: Entity

    /// A brightness value waiting to be sent. Changing it restarts the debounce in `.task(id:)`.
    private struct BrightnessRequest: Equatable {
        let percent: Int
        let immediate: Bool
    }

    @State private var brightness: Double = 0
    @State private var isEditing = false
    @State private var request: BrightnessRequest?

    private var subtitle: String {
        if entity.isUnavailable { return entity.displayState }
        guard entity.isOn else { return "Off" }
        if entity.supportsBrightness, let pct = entity.brightnessPercent { return "On · \(pct)%" }
        return "On"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                EntityRowLabel(entity: entity, subtitle: subtitle, active: entity.isOn)
                Spacer()
                EntityToggle(entity: entity)
            }
            if entity.supportsBrightness {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Slider(value: $brightness, in: 1...100) { editing in
                        isEditing = editing
                        if !editing { request = BrightnessRequest(percent: targetPercent, immediate: true) }
                    }
                    .controlSize(.mini)
                    .tint(entity.isOn ? Theme.accentWarm : .gray)
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 36)
                .disabled(entity.isUnavailable)
            }
        }
        .onAppear(perform: syncFromEntity)
        .onChange(of: entity.brightnessPercent) { syncFromEntity() }
        .onChange(of: entity.isOn) { syncFromEntity() }
        .onChange(of: brightness) {
            if isEditing { request = BrightnessRequest(percent: targetPercent, immediate: false) }
        }
        // Debounced: sends ~300 ms after the last change while dragging, or right away on release.
        .task(id: request) {
            guard let request else { return }
            if !request.immediate {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            store.perform(.setBrightness(percent: request.percent), on: entity)
            self.request = nil
        }
    }

    private var targetPercent: Int { Int(brightness.rounded()) }

    /// Follows HA state, except while the user drags or a value is pending (avoids echo jumps).
    private func syncFromEntity() {
        guard !isEditing, request == nil else { return }
        brightness = Double(entity.isOn ? (entity.brightnessPercent ?? 100) : 1)
    }
}

// MARK: - Toggle (switch, input_boolean, fan, automation)

private struct ToggleRow: View {
    let entity: Entity

    var body: some View {
        HStack {
            EntityRowLabel(entity: entity, subtitle: entity.displayState, active: entity.isOn)
            Spacer()
            EntityToggle(entity: entity)
        }
    }
}

// MARK: - Cover

private struct CoverRow: View {
    @Environment(HomeStore.self) private var store
    let entity: Entity

    private var subtitle: String {
        if let position = entity.coverPosition, !entity.isUnavailable {
            return "\(entity.displayState) · \(position)%"
        }
        return entity.displayState
    }

    var body: some View {
        HStack {
            EntityRowLabel(entity: entity, subtitle: subtitle, active: entity.state != "closed")
            Spacer()
            HStack(spacing: 6) {
                control("chevron.up", help: "Open", action: .openCover)
                control("stop.fill", help: "Stop", action: .stopCover)
                control("chevron.down", help: "Close", action: .closeCover)
            }
            .disabled(entity.isUnavailable)
        }
    }

    private func control(_ symbol: String, help: String, action: EntityAction) -> some View {
        Button { store.perform(action, on: entity) } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(CircleIconButtonStyle(size: 26))
        .help(help)
    }
}

// MARK: - Sensor / binary sensor

private struct SensorRow: View {
    let entity: Entity

    var body: some View {
        HStack {
            EntityRowLabel(entity: entity, subtitle: nil, active: entity.domain == .sensor || entity.isOn)
            Spacer()
            Text(entity.displayState)
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(entity.domain == .binarySensor && entity.isOn ? entity.tint : .primary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.snappy, value: entity.state)
        }
    }
}
