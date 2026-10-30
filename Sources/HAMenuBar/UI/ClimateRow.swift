import SwiftUI

// The climate row is built from small parts (label, mode menu, stepper, power button)
// so it can be restyled to a reference design without touching the logic.

struct ClimateRow: View {
    @Environment(HomeStore.self) private var store
    let entity: Entity

    /// Target chosen with −/+ but not sent yet. Changing it restarts the debounce in `.task(id:)`.
    @State private var pendingTarget: Double?

    private var displayedTarget: Double? { pendingTarget ?? entity.targetTemperature }

    var body: some View {
        HStack(spacing: 8) {
            EntityRowLabel(entity: entity, active: entity.isOn) {
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
        // Debounced: rapid taps are merged and sent once, 600 ms after the last one.
        .task(id: pendingTarget) {
            guard let target = pendingTarget else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            store.perform(.setTemperature(target), on: entity)
            pendingTarget = nil
        }
    }

    private func adjust(by delta: Double) {
        guard let next = entity.adjustedTargetTemperature(by: delta, from: displayedTarget) else { return }
        pendingTarget = next
    }

    /// Text shown after the mode menu, e.g. "Cooling · Now 24°".
    static func detail(for entity: Entity) -> String? {
        var parts: [String] = []
        if entity.isOn, let action = entity.hvacAction, action != "idle", action != "off" {
            parts.append(action.humanized)
        }
        if let current = entity.currentTemperature {
            parts.append("Now \(current.formatted(.compactValue))°")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            Text(value.map { "\($0.formatted(.compactValue))°" } ?? "—")
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

/// Compact menu showing the current HVAC mode; lists the device's `hvac_modes` with a native checkmark.
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
                Picker("Mode", selection: Binding(get: { entity.hvacMode }, set: { onSelect($0) })) {
                    ForEach(entity.hvacModes, id: \.self) { mode in
                        let info = HVACModeInfo(mode)
                        Label(info.label, systemImage: info.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
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
