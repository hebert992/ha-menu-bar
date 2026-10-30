import SwiftUI

// The climate row is built from small parts (label, mode menu, stepper, power button)
// so it can be restyled to a reference design without touching the logic.

struct ClimateRow: View {
    @Environment(HomeStore.self) private var store
    let entity: Entity

    @State private var pendingTarget: Double?
    @State private var sendTask: Task<Void, Never>?

    private var displayedTarget: Double? { pendingTarget ?? entity.targetTemperature }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                IconBadge(symbol: entity.symbolName, tint: entity.tint, active: entity.isOn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entity.friendlyName)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        HVACModeMenu(entity: entity) { store.perform(.setHvacMode($0), on: entity) }
                        if let detail = ClimateRow.detail(for: entity) {
                            Text("· \(detail)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .help(entity.entityId)
            Spacer(minLength: 4)
            TemperatureStepper(
                value: displayedTarget,
                isDimmed: !entity.isOn,
                isEnabled: !entity.isUnavailable && entity.targetTemperature != nil,
                onStep: adjust(by:)
            )
            ClimatePowerButton(isOn: entity.isOn, tint: entity.tint) {
                store.perform(entity.isOn ? .turnOff : .turnOn, on: entity)
            }
            .disabled(entity.isUnavailable)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .hoverHighlight()
    }

    /// Debounced: rapid taps are merged and sent once, 600 ms after the last one.
    private func adjust(by delta: Double) {
        guard let next = entity.adjustedTargetTemperature(by: delta, from: displayedTarget) else { return }
        pendingTarget = next
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            store.perform(.setTemperature(next), on: entity)
            pendingTarget = nil
        }
    }

    /// Text shown after the mode menu, e.g. "Cooling · Now 24°".
    static func detail(for entity: Entity) -> String? {
        var parts: [String] = []
        if entity.isOn, let action = entity.hvacAction, action != "idle", action != "off" {
            parts.append(action.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        if let current = entity.currentTemperature {
            parts.append("Now \(formatTemperature(current))°")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func formatTemperature(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// Target temperature with −/+ buttons. Dimmed (but usable) when the device is off.
struct TemperatureStepper: View {
    let value: Double?
    var isDimmed = false
    var isEnabled = true
    let onStep: (Double) -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", delta: -0.5, help: "Decrease target")
            Text(value.map { "\(ClimateRow.formatTemperature($0))°" } ?? "—")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText(value: value ?? 0))
                .frame(minWidth: 44)
                .animation(.snappy(duration: 0.2), value: value)
            stepButton("plus", delta: 0.5, help: "Increase target")
        }
        .padding(2)
        .background(Capsule().fill(Theme.controlFill.opacity(0.6)))
        .opacity(isDimmed ? 0.45 : 1)
        .disabled(!isEnabled)
        .animation(.easeInOut(duration: 0.2), value: isDimmed)
    }

    private func stepButton(_ symbol: String, delta: Double, help: String) -> some View {
        Button { onStep(delta) } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(CircleIconButtonStyle(size: 24, fill: .clear))
        .help(help)
    }
}

/// Compact menu showing the current HVAC mode; lists the device's `hvac_modes`.
struct HVACModeMenu: View {
    let entity: Entity
    let onSelect: (String) -> Void

    var body: some View {
        let current = HVACModeInfo(entity.hvacMode)
        if entity.hvacModes.isEmpty || entity.isUnavailable {
            Text(entity.displayState)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(entity.hvacModes, id: \.self) { mode in
                    let info = HVACModeInfo(mode)
                    Button {
                        onSelect(mode)
                    } label: {
                        Label(mode == entity.hvacMode ? "\(info.label)  ✓" : info.label, systemImage: info.symbolName)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(current.label)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(entity.isOn ? current.style.color : .secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change mode")
        }
    }
}

/// Round power button, filled with the current mode's color when on and gray when off.
struct ClimatePowerButton: View {
    let isOn: Bool
    var tint: Color = .green
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .foregroundStyle(isOn ? Color.white : Color.secondary)
        }
        .buttonStyle(CircleIconButtonStyle(size: 26, fill: isOn ? tint.opacity(0.85) : Theme.controlFill))
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .help(isOn ? "Turn off" : "Turn on")
        .accessibilityLabel(isOn ? "Turn off" : "Turn on")
    }
}
