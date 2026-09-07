import Foundation
import Testing
@testable import BatteryCore

@Suite("Charge sessions and daily statistics")
struct ChargeSessionTests {

    private let start = referenceDate

    private func rows(_ specification: [(minutes: Double, percent: Int, external: Bool, watts: Double?)]) throws -> [HistoryReading] {
        try specification.map {
            try HistoryFixtures.phoneRow(
                at: start.addingTimeInterval($0.minutes * 60),
                percent: $0.percent,
                charging: $0.external && $0.percent < 100,
                external: $0.external,
                watts: $0.watts
            )
        }
    }

    @Test("A plug-in, a charge and an unplug become one closed session")
    func closedSession() throws {
        let readings = try rows([
            (0, 30, false, -4.0),
            (5, 31, true, 15.0),
            (35, 55, true, 13.0),
            (65, 82, true, 9.0),
            (70, 83, false, -3.0),
        ])
        let sessions = ChargeSessionBuilder.sessions(from: readings)
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)

        #expect(session.start == start.addingTimeInterval(5 * 60))
        // Ends at the last reading that still showed external power, not at the
        // reading that discovered the unplug.
        #expect(session.end == start.addingTimeInterval(65 * 60))
        #expect(session.isOpen == false)
        #expect(session.fromPercent == 31)
        #expect(session.toPercent == 82)
        #expect(session.percentGained == 51)
        #expect(session.duration == TimeInterval(3600))
        #expect(session.peakWatts == 15.0)
        #expect(session.adapterWatts == 45)
        // 15 + 13 + 9 over three samples.
        #expect(abs((session.averageWatts ?? 0) - 37.0 / 3) < 0.0001)
    }

    @Test("reached80At is the first reading at or above 80 %")
    func reaches80() throws {
        let readings = try rows([
            (0, 60, true, 20.0),
            (20, 79, true, 18.0),
            (40, 81, true, 8.0),
            (60, 92, true, 6.0),
        ])
        let session = try #require(ChargeSessionBuilder.sessions(from: readings).first)
        #expect(session.reached80At == start.addingTimeInterval(40 * 60))
        #expect(session.timeTo80 == TimeInterval(2400))
        // Still on the charger as of the newest reading we hold.
        #expect(session.isOpen)
        #expect(session.end == nil)
    }

    @Test("A gap longer than 30 minutes splits one plugged-in run into two sessions")
    func gapSplitsSession() throws {
        let readings = try rows([
            (0, 40, true, 15.0),
            (20, 55, true, 14.0),
            // 45 minutes of nothing: the laptop slept or the phone went off the
            // air. We do not know it stayed on the charger, so the session ends.
            (65, 90, true, 5.0),
            (85, 97, true, 3.0),
        ])
        let sessions = ChargeSessionBuilder.sessions(from: readings)
        #expect(sessions.count == 2)
        #expect(sessions[0].end == start.addingTimeInterval(20 * 60))
        #expect(sessions[0].toPercent == 55)
        #expect(sessions[1].start == start.addingTimeInterval(65 * 60))
        #expect(sessions[1].fromPercent == 90)
        #expect(sessions[1].isOpen)
    }

    @Test("A gap exactly at the limit does not split, and energy integrates the clipped gaps")
    func energyEstimate() throws {
        let readings = try rows([
            (0, 20, true, 10.0),
            (30, 45, true, 10.0),
            (60, 70, true, 10.0),
        ])
        let sessions = ChargeSessionBuilder.sessions(from: readings)
        #expect(sessions.count == 1)
        // Two half-hour intervals at 10 W.
        #expect(abs((sessions[0].energyWh ?? 0) - 10.0) < 0.0001)
    }

    @Test("No wattage anywhere leaves the power fields nil rather than zero")
    func partialOnlySession() throws {
        let readings = try rows([
            (0, 40, true, nil),
            (10, 44, true, nil),
        ])
        let session = try #require(ChargeSessionBuilder.sessions(from: readings).first)
        #expect(session.peakWatts == nil)
        #expect(session.averageWatts == nil)
        #expect(session.energyWh == nil)
        #expect(session.toPercent == 44)
    }

    @Test("Nothing plugged in produces no sessions at all")
    func noSessions() throws {
        let readings = try rows([(0, 80, false, -5.0), (30, 70, false, -6.0)])
        #expect(ChargeSessionBuilder.sessions(from: readings).isEmpty)
    }

    @Test("Daily statistics sum the percent steps and the charger time")
    func dailyStatistics() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: referenceDate)

        let readings = try [
            (0.0, 80, false, -10.0),
            (60.0, 70, false, -8.0),
            (120.0, 60, false, -6.0),
            (150.0, 62, true, 12.0),
            (180.0, 90, true, 12.0),
            (210.0, 85, false, -4.0),
        ].map { (minutes: Double, percent: Int, external: Bool, watts: Double) in
            try HistoryFixtures.phoneRow(
                at: midnight.addingTimeInterval(minutes * 60),
                percent: percent,
                charging: external,
                external: external,
                watts: watts
            )
        }

        let stats = ChargeSessionBuilder.dailyStats(from: readings, calendar: calendar)
        #expect(stats.count == 1)
        let day = try #require(stats.first)
        #expect(day.day == midnight)
        #expect(day.minPercent == 60)
        #expect(day.maxPercent == 90)
        // 10 + 10 down to 60, then 5 back off the top.
        #expect(day.percentConsumed == 25)
        // 2 up to 62, then 28 up to 90.
        #expect(day.percentGained == 30)
        #expect(abs(day.cyclesEstimate - 0.30) < 0.0001)
        // Two 30-minute intervals whose earlier reading was on external power.
        #expect(day.minutesOnCharger == 60)
        // Four negative samples: 10, 8, 6, 4.
        #expect(abs((day.averageDrawWatts ?? 0) - 7.0) < 0.0001)
        // Neither OS tells us, and we do not guess.
        #expect(day.screenOnMinutes == nil)
        #expect(day.sampleCount == 6)
    }

    @Test("Days are separated and returned newest first")
    func multipleDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: referenceDate)
        let readings = try [-2.0, -1.0, 0.0].flatMap { dayOffset in
            try [1.0, 5.0].map { hour in
                try HistoryFixtures.phoneRow(
                    at: midnight.addingTimeInterval(dayOffset * 86_400 + hour * 3600),
                    percent: 50,
                    external: false,
                    watts: -5
                )
            }
        }
        let stats = ChargeSessionBuilder.dailyStats(from: readings, calendar: calendar)
        #expect(stats.count == 3)
        #expect(stats[0].day > stats[1].day)
        #expect(stats[2].day == midnight.addingTimeInterval(-2 * 86_400))
    }

    @Test("Downsampling caps the series and keeps it in order")
    func downsampling() throws {
        let end = referenceDate
        let from = end.addingTimeInterval(-24 * 3600)
        // One reading a minute for a day: 1440 rows into at most 96 points.
        let readings = try (0..<1440).map { minute in
            try HistoryFixtures.phoneRow(
                at: from.addingTimeInterval(Double(minute) * 60),
                percent: 20 + minute % 80,
                external: minute % 2 == 0
            )
        }
        let series = ChargeSessionBuilder.downsample(readings, from: from, through: end, limit: HistoryStore.seriesPointLimit)
        #expect(series.count <= HistoryStore.seriesPointLimit)
        #expect(series.count == HistoryStore.seriesPointLimit)
        #expect(zip(series, series.dropFirst()).allSatisfy { $0.t < $1.t })
        #expect(series.first!.t >= from)
        #expect(series.last!.t <= end)
    }

    @Test("Fewer readings than buckets survive unchanged")
    func downsamplingIsLossless() throws {
        let end = referenceDate
        let from = end.addingTimeInterval(-24 * 3600)
        let readings = try (0..<5).map { index in
            try HistoryFixtures.phoneRow(
                at: from.addingTimeInterval(Double(index) * 3600),
                percent: 40 + index
            )
        }
        let series = ChargeSessionBuilder.downsample(readings, from: from, through: end, limit: 96)
        #expect(series.count == 5)
        #expect(series.map(\.percent) == [40, 41, 42, 43, 44])
    }
}
