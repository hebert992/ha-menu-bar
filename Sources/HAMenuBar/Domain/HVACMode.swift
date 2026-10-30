import Foundation

/// Visual family of an HVAC mode; the UI maps each one to a color.
enum HVACModeStyle: Equatable, Sendable {
    case cooling, heating, drying, fan, auto, off, other
}

/// Human-readable label, SF Symbol and style for a Home Assistant `hvac_mode`.
struct HVACModeInfo: Equatable, Sendable {
    let label: String
    let symbolName: String
    let style: HVACModeStyle

    init(_ mode: String) {
        switch mode {
        case "cool": (label, symbolName, style) = ("Cool", "snowflake", .cooling)
        case "heat": (label, symbolName, style) = ("Heat", "flame.fill", .heating)
        case "dry": (label, symbolName, style) = ("Dry", "drop.fill", .drying)
        case "fan_only": (label, symbolName, style) = ("Fan only", "fan.fill", .fan)
        case "auto": (label, symbolName, style) = ("Auto", "arrow.triangle.2.circlepath", .auto)
        case "heat_cool": (label, symbolName, style) = ("Heat/Cool", "arrow.triangle.2.circlepath", .auto)
        case "off": (label, symbolName, style) = ("Off", "power", .off)
        default:
            label = mode.humanized
            symbolName = "thermometer.medium"
            style = .other
        }
    }
}
