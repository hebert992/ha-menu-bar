import Foundation

struct PowerSample: Equatable, Sendable {
    var date: Date
    var value: Double
}

/// Pure helpers for the power sparkline. All functions expect and return samples sorted by date;
/// only `merge` sorts, because history from HA may arrive in any order.
enum PowerHistory {
    static let window: TimeInterval = 3600

    /// Keeps samples inside `[now - window, ...]`. The most recent sample before the window is carried
    /// to the window start, so a value that has not changed for over an hour still draws a line.
    static func trimmed(_ samples: [PowerSample], now: Date) -> [PowerSample] {
        var result = samples
        dropExpired(&result, now: now)
        return result
    }

    /// Appends a live sample, then drops expired samples from the front.
    /// A sample with the same timestamp as an existing one replaces it.
    static func appending(_ sample: PowerSample, to samples: [PowerSample], now: Date) -> [PowerSample] {
        var result = samples
        if let last = result.last, sample.date <= last.date {
            // Rare: clock skew or an out-of-order event. Keep the buffer sorted.
            if let same = result.lastIndex(where: { $0.date == sample.date }) {
                result[same] = sample
            } else {
                let index = result.firstIndex { $0.date > sample.date } ?? result.endIndex
                result.insert(sample, at: index)
            }
        } else {
            result.append(sample)
        }
        dropExpired(&result, now: now)
        return result
    }

    /// Where a history request for this buffer should start: right after its last sample (gap fill
    /// after a reconnect), or the start of the window when nothing is known yet.
    static func historyStart(for buffer: [PowerSample], now: Date) -> Date {
        buffer.last?.date ?? now.addingTimeInterval(-window)
    }

    /// Merges history fetched from `since` into the live buffer:
    /// - live samples up to `since` are kept (what we already had before the gap);
    /// - history after `since` fills the gap and replaces live duplicates of the same events;
    /// - live samples newer than the last history entry are appended.
    /// On a full load (no live samples before `since`) all history is used, including HA's
    /// start-time state, which may carry an older timestamp and becomes the window-start value.
    static func merge(history: [PowerSample], live: [PowerSample], since: Date, now: Date) -> [PowerSample] {
        let sortedHistory = history.sorted { $0.date < $1.date }
        let kept = live.filter { $0.date <= since }
        let fetched = kept.isEmpty ? sortedHistory : sortedHistory.filter { $0.date > since }
        let lastFetched = fetched.last?.date ?? .distantPast
        var result = kept + fetched + live.filter { $0.date > since && $0.date > lastFetched }
        dropExpired(&result, now: now)
        return result
    }

    /// Points to plot: the trimmed samples plus the latest value held until `now`.
    static func chartPoints(_ samples: [PowerSample], now: Date) -> [PowerSample] {
        var points = trimmed(samples, now: now)
        if let last = points.last, last.date < now {
            points.append(PowerSample(date: now, value: last.value))
        }
        return points
    }

    /// Reduces dense series to about `buckets` points by averaging per time bucket over the window.
    /// The first and last points are kept as-is so the line still spans the whole chart.
    static func downsampled(_ points: [PowerSample], now: Date, buckets: Int = 120) -> [PowerSample] {
        guard points.count > buckets, buckets > 0, let first = points.first, let last = points.last else {
            return points
        }
        let start = now.addingTimeInterval(-window)
        let width = window / Double(buckets)
        var result = [first]
        var bucket = -1, count = 0.0, sumValue = 0.0, sumTime = 0.0

        func flush() {
            guard count > 0 else { return }
            result.append(PowerSample(date: Date(timeIntervalSinceReferenceDate: sumTime / count),
                                      value: sumValue / count))
        }

        for point in points.dropFirst().dropLast() {
            let index = min(max(Int(point.date.timeIntervalSince(start) / width), 0), buckets - 1)
            if index != bucket {
                flush()
                bucket = index
                count = 0; sumValue = 0; sumTime = 0
            }
            count += 1
            sumValue += point.value
            sumTime += point.date.timeIntervalSinceReferenceDate
        }
        flush()
        result.append(last)
        return result
    }

    /// Minimum and maximum value in one pass.
    static func range(_ samples: [PowerSample]) -> (min: Double, max: Double)? {
        guard let first = samples.first?.value else { return nil }
        return samples.dropFirst().reduce((min: first, max: first)) { range, sample in
            (Swift.min(range.min, sample.value), Swift.max(range.max, sample.value))
        }
    }

    /// Drops samples older than the window from the front, carrying the last expired value to the start.
    private static func dropExpired(_ samples: inout [PowerSample], now: Date) {
        let start = now.addingTimeInterval(-window)
        guard let firstInside = samples.firstIndex(where: { $0.date >= start }) else {
            // Everything expired: keep only the latest value, carried to the window start.
            if let last = samples.last { samples = [PowerSample(date: start, value: last.value)] }
            return
        }
        guard firstInside > 0 else { return }
        let carried = samples[firstInside - 1].value
        samples.removeFirst(firstInside)
        if samples.first?.date != start {
            samples.insert(PowerSample(date: start, value: carried), at: 0)
        }
    }
}
