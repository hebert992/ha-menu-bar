import Foundation

struct PowerSample: Equatable, Sendable {
    var date: Date
    var value: Double
}

/// Pure helpers for the power sparkline: parsing HA history, trimming to a window, merging live values.
enum PowerHistory {
    static let window: TimeInterval = 3600

    /// Parses a `history/history_during_period` result (`{entity_id: [state, ...]}`).
    /// Accepts the compressed format (`s`, `lu`, `lc`) and the full format (`state`, `last_updated`).
    /// Non-numeric states (unavailable, unknown, ...) are dropped. Samples are sorted by date.
    static func parse(_ result: JSONValue?) -> [String: [PowerSample]] {
        guard let object = result?.objectValue else { return [:] }
        var history: [String: [PowerSample]] = [:]
        for (entityId, states) in object {
            let samples = (states.arrayValue ?? []).compactMap(sample(from:))
            history[entityId] = samples.sorted { $0.date < $1.date }
        }
        return history
    }

    private static func sample(from state: JSONValue) -> PowerSample? {
        guard let raw = state["s"]?.stringValue ?? state["state"]?.stringValue,
              let value = Double(raw), value.isFinite,
              let date = timestamp(state["lu"]) ?? timestamp(state["lc"])
                ?? timestamp(state["last_updated"]) ?? timestamp(state["last_changed"])
        else { return nil }
        return PowerSample(date: date, value: value)
    }

    private static func timestamp(_ value: JSONValue?) -> Date? {
        switch value {
        case let .number(seconds)?:
            return Date(timeIntervalSince1970: seconds)
        case let .string(text)?:
            if let date = try? Date(text, strategy: .iso8601) { return date }
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            return try? fractional.parse(text)
        default:
            return nil
        }
    }

    /// Keeps samples inside `[now - window, ...]`. The most recent sample before the window is carried
    /// to the window start, so a value that has not changed for over an hour still draws a line.
    static func trimmed(_ samples: [PowerSample], now: Date, window: TimeInterval = window) -> [PowerSample] {
        let start = now.addingTimeInterval(-window)
        let sorted = samples.sorted { $0.date < $1.date }
        var inside = sorted.filter { $0.date >= start }
        if inside.first?.date != start, let carried = sorted.last(where: { $0.date < start }) {
            inside.insert(PowerSample(date: start, value: carried.value), at: 0)
        }
        return inside
    }

    /// Appends a live sample. A sample with the same timestamp as an existing one replaces it.
    static func appending(_ sample: PowerSample, to samples: [PowerSample], now: Date,
                          window: TimeInterval = window) -> [PowerSample] {
        var updated = samples.filter { $0.date != sample.date }
        updated.append(sample)
        return trimmed(updated, now: now, window: window)
    }

    /// Combines a freshly loaded history with live samples that arrived after its last entry.
    static func merge(history: [PowerSample], live: [PowerSample], now: Date,
                      window: TimeInterval = window) -> [PowerSample] {
        let lastHistoryDate = history.map(\.date).max() ?? .distantPast
        return trimmed(history + live.filter { $0.date > lastHistoryDate }, now: now, window: window)
    }

    /// Points to plot: the trimmed samples plus the latest value held until `now`.
    static func chartPoints(_ samples: [PowerSample], now: Date, window: TimeInterval = window) -> [PowerSample] {
        var points = trimmed(samples, now: now, window: window)
        if let last = points.last, last.date < now {
            points.append(PowerSample(date: now, value: last.value))
        }
        return points
    }

    static func range(_ samples: [PowerSample]) -> (min: Double, max: Double)? {
        guard let min = samples.map(\.value).min(), let max = samples.map(\.value).max() else { return nil }
        return (min, max)
    }
}
