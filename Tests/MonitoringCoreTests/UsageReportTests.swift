import Foundation
import Testing
@testable import MonitoringCore

struct UsageReportTests {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!; return c }
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func weekStartsMondayEvenWhenCalendarDefaultsToSunday() {
        let interval = ReportPeriod.week.interval(anchor: date("2026-11-12T16:00:00+08:00"), firstRecord: nil, calendar: calendar)
        #expect(interval.start == date("2026-11-09T00:00:00+08:00"))
        #expect(interval.end == date("2026-11-16T00:00:00+08:00"))
    }

    @Test func totalPeriodBeginsAtFirstLocalRecordingDay() {
        let first = date("2026-11-12T13:00:00+08:00"), now = date("2026-11-13T10:00:00+08:00")
        let interval = ReportPeriod.all.interval(anchor: now, firstRecord: first, now: now, calendar: calendar)
        #expect(interval.start == date("2026-11-12T00:00:00+08:00"))
        #expect(interval.end == now)
    }

    @Test func initialRecordingDateComesFromDurableApplicationRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SegmentStore(url: directory.appendingPathComponent("usage.sqlite"))
        #expect(try store.firstRecordDate() == nil)
        let first = date("2026-11-12T13:00:00+08:00")
        try store.upsert([.init(kind: .application, value: "test", label: "Test", start: first, end: first.addingTimeInterval(10))])
        #expect(try store.firstRecordDate() == first)
    }
}
