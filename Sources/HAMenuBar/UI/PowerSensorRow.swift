import Charts
import SwiftUI

/// Power sensor row: large current value plus a one-hour sparkline with min/max.
struct PowerSensorRow: View {
    @Environment(HomeStore.self) private var store
    let entity: Entity

    var body: some View {
        // Re-render every 30 s so the window keeps sliding even when the value is steady.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let points = PowerHistory.chartPoints(store.powerHistory[entity.entityId] ?? [], now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    EntityRowLabel(entity: entity, subtitle: rangeText(points), active: !entity.isUnavailable)
                    Spacer(minLength: 4)
                    currentValue
                }
                PowerSparkline(
                    points: PowerHistory.downsampled(points, now: context.date),
                    now: context.date,
                    tint: entity.tint
                )
                .padding(.leading, 36)
            }
        }
    }

    private var currentValue: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let value = entity.numericState {
                Text(value.formatted(.compactValue))
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: value))
                    .animation(.snappy, value: value)
                if let unit = entity.unit {
                    Text(unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(entity.displayState)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Min/max over the full (not downsampled) hour.
    private func rangeText(_ points: [PowerSample]) -> String? {
        guard let range = PowerHistory.range(points) else { return nil }
        let unit = entity.unit.map { " \($0)" } ?? ""
        return "1h · min \(range.min.formatted(.compactValue))\(unit) · max \(range.max.formatted(.compactValue))\(unit)"
    }
}

/// Axis-less line + gradient area chart covering the last hour.
struct PowerSparkline: View {
    let points: [PowerSample]
    let now: Date
    let tint: Color

    var body: some View {
        if points.count < 2 {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.hairline)
                .frame(height: 2)
                .frame(height: 36, alignment: .bottom)
        } else {
            // Computed once per render; reading it per mark would be O(n²).
            let yDomain = Self.yDomain(for: points)
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Min", yDomain.lowerBound),
                    yEnd: .value("Power", point.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                )
                LineMark(x: .value("Time", point.date), y: .value("Power", point.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .chartXScale(domain: now.addingTimeInterval(-PowerHistory.window)...now)
            .chartYScale(domain: yDomain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 36)
            .accessibilityLabel("Power over the last hour")
        }
    }

    /// Pads the range so a flat line sits mid-chart instead of on the edge.
    private static func yDomain(for points: [PowerSample]) -> ClosedRange<Double> {
        guard let range = PowerHistory.range(points) else { return 0...1 }
        let span = range.max - range.min
        let pad = span > 0 ? span * 0.15 : max(abs(range.max) * 0.1, 1)
        return (range.min - pad)...(range.max + pad)
    }
}
