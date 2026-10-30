import SwiftUI

/// Picks the right row for an entity's domain.
struct EntityRow: View {
    let entity: Entity

    var body: some View {
        Group {
            switch entity.domain {
            case .light: LightRow(entity: entity)
            case .switch, .inputBoolean, .fan, .automation: ToggleRow(entity: entity)
            case .cover: CoverRow(entity: entity)
            case .climate: ClimateRow(entity: entity)
            case .sensor where entity.isPowerSensor: PowerSensorRow(entity: entity)
            default: SensorRow(entity: entity)
            }
        }
        .opacity(entity.isUnavailable ? 0.55 : 1)
    }
}

/// Icon + name + subtitle, shared by all rows (including ClimateRow and PowerSensorRow).
struct EntityRowLabel: View {
    let entity: Entity
    var subtitle: String?
    var active: Bool

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: entity.symbolName, tint: entity.tint, active: active)
            VStack(alignment: .leading, spacing: 1) {
                Text(entity.friendlyName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
        }
        .help(entity.entityId)
    }
}

private struct EntityToggle: View {
    @Environment(HomeStore.self) private var store
    let entity: Entity
    var tint: Color

    var body: some View {
        Toggle("", isOn: Binding(
            get: { entity.isOn },
            set: { store.perform($0 ? .turnOn : .turnOff, on: entity) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(tint)
        .disabled(entity.isUnavailable)
    }
}

// MARK: - Light

private struct LightRow: View {
    @Environment(HomeStore.self) private var store
    let entity: Entity

    @State private var brightness: Double = 0
    @State private var isEditing = false
    @State private var sendTask: Task<Void, Never>?

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
                EntityToggle(entity: entity, tint: Theme.accentWarm)
            }
            if entity.supportsBrightness {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Slider(value: $brightness, in: 1...100) { editing in
                        isEditing = editing
                        if !editing { send(immediately: true) }
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .hoverHighlight()
        .onAppear(perform: syncFromEntity)
        .onChange(of: entity.brightnessPercent) { syncFromEntity() }
        .onChange(of: entity.isOn) { syncFromEntity() }
        .onChange(of: brightness) {
            if isEditing { send(immediately: false) }
        }
    }

    private func syncFromEntity() {
        guard !isEditing, sendTask == nil else { return }
        brightness = Double(entity.isOn ? (entity.brightnessPercent ?? 100) : 1)
    }

    /// Debounced: sends ~300 ms after the last change while dragging, or right away on release.
    private func send(immediately: Bool) {
        sendTask?.cancel()
        let target = Int(brightness.rounded())
        sendTask = Task {
            if !immediately {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            store.perform(.setBrightness(percent: target), on: entity)
            sendTask = nil
        }
    }
}

// MARK: - Toggle (switch, input_boolean, fan, automation)

private struct ToggleRow: View {
    let entity: Entity

    var body: some View {
        HStack {
            EntityRowLabel(entity: entity, subtitle: entity.displayState, active: entity.isOn)
            Spacer()
            EntityToggle(entity: entity, tint: entity.domain == .fan ? .cyan : .green)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .hoverHighlight()
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .hoverHighlight()
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .hoverHighlight()
    }
}
