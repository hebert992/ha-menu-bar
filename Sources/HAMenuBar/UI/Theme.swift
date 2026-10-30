import AppKit
import SwiftUI

// MARK: - Palette & metrics

enum Theme {
    static let panelWidth: CGFloat = 360
    static let maxContentHeight: CGFloat = 560
    static let cornerRadius: CGFloat = 12
    static let cardFill = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.07)
    static let hoverFill = Color.white.opacity(0.08)
    static let controlFill = Color.white.opacity(0.10)
    static let accentWarm = Color(red: 1.0, green: 0.78, blue: 0.28)
}

// MARK: - Entity icons

extension Entity {
    var symbolName: String {
        switch domain {
        case .scene: return "sparkles"
        case .script: return "scroll.fill"
        case .button: return "button.programmable"
        case .inputButton: return "hand.tap.fill"
        case .light: return isOn ? "lightbulb.fill" : "lightbulb"
        case .switch: return "power"
        case .inputBoolean: return "switch.2"
        case .fan: return "fan.fill"
        case .automation: return "gearshape.2.fill"
        case .cover:
            let open = state == "open" || state == "opening"
            if deviceClass == "garage" { return open ? "door.garage.open" : "door.garage.closed" }
            return open ? "blinds.vertical.open" : "blinds.vertical.closed"
        case .climate: return isOn ? HVACModeInfo(hvacMode).symbolName : "thermometer.medium"
        case .sensor:
            switch deviceClass {
            case "temperature": return "thermometer.medium"
            case "humidity": return "humidity.fill"
            case "power", "energy", "current", "voltage": return "bolt.fill"
            case _ where isPowerSensor: return "bolt.fill"
            case "battery": return "battery.75"
            case "illuminance": return "sun.max.fill"
            default: return "gauge.medium"
            }
        case .binarySensor:
            switch deviceClass {
            case "door", "garage_door", "opening": return isOn ? "door.left.hand.open" : "door.left.hand.closed"
            case "window": return isOn ? "window.vertical.open" : "window.vertical.closed"
            case "motion", "occupancy", "presence": return "figure.walk.motion"
            case "moisture": return "drop.fill"
            case "smoke", "gas", "carbon_monoxide": return "smoke.fill"
            default: return isOn ? "circle.inset.filled" : "circle"
            }
        case nil: return "questionmark.circle"
        }
    }

    var tint: Color {
        if isUnavailable { return .gray }
        switch domain {
        case .scene: return .purple
        case .script: return .blue
        case .button, .inputButton: return .teal
        case .light: return isOn ? Theme.accentWarm : .gray
        case .switch, .inputBoolean: return isOn ? .green : .gray
        case .fan: return isOn ? .cyan : .gray
        case .automation: return isOn ? .orange : .gray
        case .cover: return .indigo
        case .climate: return HVACModeInfo(hvacMode).style.color
        case .sensor: return isPowerSensor ? Theme.accentWarm : .mint
        case .binarySensor: return isOn ? .orange : .gray
        case nil: return .gray
        }
    }
}

// MARK: - Reusable pieces

struct IconBadge: View {
    let symbol: String
    let tint: Color
    var active = true
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            Circle()
                .fill(active ? tint.opacity(0.22) : Color.white.opacity(0.08))
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(active ? tint : .secondary)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: size, height: size)
    }
}

extension HVACModeStyle {
    var color: Color {
        switch self {
        case .cooling: Color(red: 0.36, green: 0.66, blue: 1.0)
        case .heating: .orange
        case .drying: .teal
        case .fan: .cyan
        case .auto: .green
        case .off: .gray
        case .other: .mint
        }
    }
}

extension StatusIndicator {
    var color: Color {
        switch self {
        case .ok: .green
        case .pending: .orange
        case .failure: .red
        case .inactive: .gray
        }
    }
}

/// Glowing dot used in the panel header, Settings status row and test result.
struct IndicatorDot: View {
    let indicator: StatusIndicator
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(indicator.color)
            .frame(width: size, height: size)
            .shadow(color: indicator.color.opacity(0.7), radius: 3)
    }
}

/// Connection dot for the panel header.
struct StatusDot: View {
    let status: ConnectionStatus
    var haVersion: String?

    var body: some View {
        let label = status.label(haVersion: haVersion)
        IndicatorDot(indicator: status.indicator)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Dot plus text, e.g. "● Connected · Home Assistant 2026.10.1".
struct StatusLine: View {
    let indicator: StatusIndicator
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            IndicatorDot(indicator: indicator)
            Text(text)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rounded container that hosts a stack of rows separated by hairlines.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke)
            )
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 46)
    }
}

/// Small circular icon button used in the header and for cover / climate controls.
struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 24
    var fill: Color = Theme.controlFill

    func makeBody(configuration: Configuration) -> some View {
        HoverCircle(size: size, fill: fill, pressed: configuration.isPressed) {
            configuration.label
        }
    }

    private struct HoverCircle<Label: View>: View {
        let size: CGFloat
        let fill: Color
        let pressed: Bool
        @ViewBuilder var label: Label
        @State private var hovering = false

        var body: some View {
            label
                .font(.system(size: size * 0.46, weight: .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? fill.opacity(1.8) : fill))
                .scaleEffect(pressed ? 0.9 : 1)
                .animation(.easeOut(duration: 0.12), value: pressed)
                .onHover { hovering = $0 }
                .contentShape(Circle())
        }
    }
}

/// Highlights a row on hover, like list rows in the system calendar popover.
struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Theme.hoverFill : .clear)
                    .padding(.horizontal, 4)
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

/// Brings the hosting window to the front. Needed because the app runs as an accessory (no Dock icon).
struct BringWindowToFront: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            NSApp.activate()
            view.window?.makeKeyAndOrderFront(nil)
            view.window?.orderFrontRegardless()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Opens the Settings window on a given tab and activates the app so it comes to the front.
@MainActor
struct SettingsOpener {
    let store: HomeStore
    let openSettings: OpenSettingsAction

    func callAsFunction(_ tab: SettingsTab) {
        store.settingsTab = tab
        NSApp.activate()
        openSettings()
    }
}
