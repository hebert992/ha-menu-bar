import Foundation
import Testing
@testable import HAMenuBar

@Suite("Power history")
struct PowerHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ secondsAgo: TimeInterval, _ value: Double) -> PowerSample {
        PowerSample(date: now.addingTimeInterval(-secondsAgo), value: value)
    }

    // MARK: Detection

    @Test func detectsPowerSensors() {
        func sensor(_ id: String, _ attributes: [String: JSONValue]) -> Entity {
            Entity(entityId: id, state: "1", attributes: attributes)
        }
        #expect(sensor("sensor.ecoflow_out", ["device_class": .string("power")]).isPowerSensor)
        #expect(sensor("sensor.plug", ["unit_of_measurement": .string("W")]).isPowerSensor)
        #expect(sensor("sensor.house", ["unit_of_measurement": .string("kW")]).isPowerSensor)
        #expect(!sensor("sensor.energy", ["unit_of_measurement": .string("kWh")]).isPowerSensor)
        #expect(!sensor("sensor.temp", ["device_class": .string("temperature")]).isPowerSensor)
        #expect(!sensor("binary_sensor.x", ["device_class": .string("power")]).isPowerSensor)
    }

    @Test func numericState() {
        #expect(Entity(entityId: "sensor.a", state: "142.5", attributes: [:]).numericState == 142.5)
        #expect(Entity(entityId: "sensor.a", state: "unavailable", attributes: [:]).numericState == nil)
    }

    // MARK: Request encoding

    @Test func encodesHistoryRequest() throws {
        let message = HAOutgoingMessage.historyDuringPeriod(
            id: 8, start: Date(timeIntervalSince1970: 0), entityIds: ["sensor.a", "sensor.b"]
        )
        let value = try JSONDecoder().decode(JSONValue.self, from: message.encoded())
        #expect(value == .object([
            "id": .number(8),
            "type": .string("history/history_during_period"),
            "start_time": .string("1970-01-01T00:00:00Z"),
            "entity_ids": .array([.string("sensor.a"), .string("sensor.b")]),
            "minimal_response": .bool(true),
            "no_attributes": .bool(true),
            "significant_changes_only": .bool(false),
        ]))
    }

    // MARK: Parsing

    @Test func parsesCompressedHistoryDroppingNonNumeric() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {
          "sensor.ecoflow": [
            {"s": "120", "lu": 1799996500.5},
            {"s": "unavailable", "lu": 1799996600},
            {"s": "unknown", "lu": 1799996700},
            {"s": "142.25", "lu": 1799999000, "lc": 1799999000},
            {"s": "100", "lu": 1799998000}
          ],
          "sensor.other": [{"s": "5", "lu": 1799999500}]
        }
        """.utf8))

        let history = HAHistoryDecoder.samples(from: json)
        #expect(history["sensor.ecoflow"] == [
            PowerSample(date: Date(timeIntervalSince1970: 1_799_996_500.5), value: 120),
            PowerSample(date: Date(timeIntervalSince1970: 1_799_998_000), value: 100),
            PowerSample(date: Date(timeIntervalSince1970: 1_799_999_000), value: 142.25),
        ])
        #expect(history["sensor.other"]?.count == 1)
    }

    @Test func parsesFullStateFormatAsFallback() throws {
        let json = JSONValue.object(["sensor.a": .array([
            .object(["state": .string("7"), "last_updated": .string("2027-01-15T08:00:00+00:00")]),
        ])])
        #expect(HAHistoryDecoder.samples(from: json)["sensor.a"]?.first?.value == 7)
        #expect(HAHistoryDecoder.samples(from: nil).isEmpty)
    }

    // MARK: Trimming

    @Test func trimsToWindowCarryingLastValueToWindowStart() {
        let samples = [at(7200, 10), at(4000, 20), at(1800, 30), at(60, 40)]
        #expect(PowerHistory.trimmed(samples, now: now) == [at(3600, 20), at(1800, 30), at(60, 40)])
    }

    @Test func trimKeepsSampleExactlyAtWindowStart() {
        let samples = [at(4000, 20), at(3600, 25), at(10, 30)]
        #expect(PowerHistory.trimmed(samples, now: now) == [at(3600, 25), at(10, 30)])
    }

    @Test func trimHandlesEmpty() {
        #expect(PowerHistory.trimmed([], now: now).isEmpty)
    }

    @Test func appendingOutOfOrderSampleKeepsOrder() {
        let samples = PowerHistory.appending(at(50, 9), to: [at(100, 1), at(10, 2)], now: now)
        #expect(samples == [at(100, 1), at(50, 9), at(10, 2)])
    }

    @Test func appendingAddsTrimsAndReplacesSameTimestamp() {
        var samples = [at(4000, 1), at(100, 2)]
        samples = PowerHistory.appending(at(0, 3), to: samples, now: now)
        #expect(samples == [at(3600, 1), at(100, 2), at(0, 3)])
        samples = PowerHistory.appending(at(0, 9), to: samples, now: now)
        #expect(samples.last == at(0, 9))
        #expect(samples.count == 3)
    }

    private var windowStart: Date { now.addingTimeInterval(-PowerHistory.window) }

    @Test func mergeSortsHistory() {
        #expect(PowerHistory.merge(history: [at(10, 2), at(20, 1)], live: [], since: windowStart, now: now)
            == [at(20, 1), at(10, 2)])
    }

    @Test func mergeCombinesHistoryWithNewerLiveSamples() {
        let history = [at(3000, 1), at(2000, 2)]
        let live = [at(2500, 99), at(30, 3)]
        #expect(PowerHistory.merge(history: history, live: live, since: windowStart, now: now)
            == [at(3000, 1), at(2000, 2), at(30, 3)])
    }

    @Test func fullLoadKeepsHistoryStartStateOlderThanWindow() {
        // HA's start-time state carries its real (older) timestamp; it becomes the window-start value.
        let history = [at(5000, 7), at(100, 8)]
        #expect(PowerHistory.merge(history: history, live: [], since: windowStart, now: now)
            == [at(3600, 7), at(100, 8)])
    }

    // MARK: Gap fill after reconnect

    @Test func gapFillKeepsBufferAndInsertsMissedSamples() {
        let live = [at(3000, 1), at(2000, 2), at(900, 5)]  // 900: received after reconnect
        let gap = [at(2500, 99), at(1500, 3), at(1000, 4)] // 2500 predates `since` and is ignored
        let since = now.addingTimeInterval(-2000)
        #expect(PowerHistory.merge(history: gap, live: live, since: since, now: now)
            == [at(3000, 1), at(2000, 2), at(1500, 3), at(1000, 4), at(900, 5)])
    }

    @Test func gapFillReplacesLiveDuplicatesInsideTheFetchedRange() {
        let live = [at(2000, 2), at(1200, 7)]
        let gap = [at(1500, 3), at(1000, 4)]
        let since = now.addingTimeInterval(-2000)
        #expect(PowerHistory.merge(history: gap, live: live, since: since, now: now)
            == [at(2000, 2), at(1500, 3), at(1000, 4)])
    }

    @Test func emptyGapFillLeavesBufferUntouched() {
        let live = [at(3000, 1), at(2000, 2), at(10, 3)]
        #expect(PowerHistory.merge(history: [], live: live, since: now.addingTimeInterval(-2000), now: now) == live)
    }

    @Test func historyStartIsLastSampleOrWindowStart() {
        #expect(PowerHistory.historyStart(for: [], now: now) == windowStart)
        #expect(PowerHistory.historyStart(for: [at(3000, 1), at(42, 2)], now: now) == now.addingTimeInterval(-42))
    }

    @Test func chartPointsExtendLastValueToNow() {
        #expect(PowerHistory.chartPoints([at(600, 5)], now: now) == [at(600, 5), at(0, 5)])
        #expect(PowerHistory.chartPoints([], now: now).isEmpty)
    }

    @Test func downsampleLeavesSmallSeriesUntouched() {
        let points = (0..<50).map { at(Double(3000 - $0 * 60), Double($0)) }
        #expect(PowerHistory.downsampled(points, now: now, buckets: 120) == points)
    }

    @Test func downsampleAveragesIntoBucketsKeepingEdges() {
        // One sample per second for the whole hour: 3601 points.
        let points = (0...3600).map { at(Double(3600 - $0), Double($0 % 10)) }
        let reduced = PowerHistory.downsampled(points, now: now, buckets: 120)
        #expect(reduced.count <= 122)
        #expect(reduced.count >= 100)
        #expect(reduced.first == points.first)
        #expect(reduced.last == points.last)
        #expect(zip(reduced, reduced.dropFirst()).allSatisfy { $0.date <= $1.date })
        // Each full 30 s bucket of 0...9 repeating averages to 4.5.
        #expect(reduced.dropFirst().dropLast().allSatisfy { abs($0.value - 4.5) < 0.6 })
    }

    @Test func rangeReportsMinAndMax() {
        let range = PowerHistory.range([at(30, 5), at(20, 1), at(10, 9)])
        #expect(range?.min == 1)
        #expect(range?.max == 9)
        #expect(PowerHistory.range([]) == nil)
    }
}
