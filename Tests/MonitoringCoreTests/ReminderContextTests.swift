import Foundation
import Testing
@testable import MonitoringCore

struct ReminderContextTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }
    private var now: Date { ISO8601DateFormatter().date(from: "2026-11-13T06:30:00Z")! }
    private func context(day: String = "2026-11-13", isTest: Bool = false) -> ReminderContext {
        .init(day: day, kind: .percent, node: 20, quotaMinutes: 150, scopedSeconds: 1800, triggeredAt: now,
              message: "先停下来思考5分钟，想一想，这是你想要过的生活吗？\n身体先行。", isTest: isTest)
    }

    @Test func notificationPayloadRoundTripPreservesTheOriginalMessage() throws {
        let original = context()
        let decoded = try JSONDecoder().decode(ReminderContext.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.isValid)
    }

    @Test func todayUsesCurrentUsageWhileRetainingTheTriggerNode() {
        let original = context()
        let reading = ReminderReading.make(context: original, currentSeconds: 1890, currentQuotaMinutes: 150, now: now, calendar: calendar)
        #expect(reading.value == 21)
        #expect(reading.usesCurrentUsage)
        #expect(original.node == 20)
    }

    @Test func historicalAndTestNotificationsUseTheirOwnSnapshot() {
        for original in [context(day: "2026-11-12"), context(isTest: true)] {
            let reading = ReminderReading.make(context: original, currentSeconds: 9000, currentQuotaMinutes: 100, now: now, calendar: calendar)
            #expect(reading.value == 20)
            #expect(!reading.usesCurrentUsage)
        }
    }

    @Test func legacyMinuteNotificationsNeverUseTodaysQuotaForHistory() throws {
        let original = try #require(ReminderContext.legacy(identifier: "2026-11-12:minutes:30", body: "我的原话"))
        let reading = ReminderReading.make(context: original, currentSeconds: 9000, currentQuotaMinutes: 150, now: now, calendar: calendar)
        #expect(reading.value == 30)
        #expect(reading.unit == "分钟")
        #expect(reading.isHistorical)
        #expect(ReminderContext.legacy(identifier: "2026-02-30:percent:20", body: "原话") == nil)
        #expect(ReminderContext.legacy(identifier: "unrelated", body: "原话") == nil)
    }

    @Test func percentagesCanExceedOneHundredAndMidnightUsesTheLocalDay() {
        let reading = ReminderReading.make(context: context(), currentSeconds: 9180, currentQuotaMinutes: 150, now: now, calendar: calendar)
        #expect(reading.value == 102)
        let midnight = ISO8601DateFormatter().date(from: "2026-11-13T16:00:00Z")!
        #expect(ReminderContext.dayKey(at: midnight, calendar: calendar) == "2026-11-14")
        #expect(ReminderReading.make(context: context(), currentSeconds: 0, currentQuotaMinutes: 150, now: midnight, calendar: calendar).isHistorical)
    }

    @Test func invalidPayloadNumbersAreRejected() {
        var original = context()
        original.scopedSeconds = .infinity
        #expect(!original.isValid)
        original.scopedSeconds = 100
        original.quotaMinutes = 0
        #expect(!original.isValid)
    }
}
