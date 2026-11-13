import Foundation
import Testing
@testable import MonitoringCore

struct PerformanceRegressionTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test func throttlingDoesNotRoundApplicationBoundariesOrIdleRetractions() {
        var engine = TrackingEngine(at: base)
        engine.setApplication(.init(bundleID: "chat", name: "Chat"), at: base)
        engine.setApplication(.init(bundleID: "code", name: "Code"), at: base.addingTimeInterval(2.25))
        // Saving/painting every five seconds must not quantize the 2.25s switch.
        let rows = engine.checkpoint(at: base.addingTimeInterval(5))
        #expect(rows.first(where: { $0.value == "chat" })?.end == base.addingTimeInterval(2.25))
        engine.acknowledge(Set(rows.map(\.id)))
        engine.samplePresence(secondsSinceInput: 10, idleAfter: 10, at: base.addingTimeInterval(12))
        var saved = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for row in engine.checkpoint(at: base.addingTimeInterval(20)) { saved[row.id] = row }
        #expect(UsageCalculator.summarize(Array(saved.values), from: base, to: base.addingTimeInterval(20)).totalSeconds == 2)
    }

    @Test func cadenceSkipsHeavyWorkWhileIdleOrSuspendedWithoutChangingSaveInterval() {
        let schedule = MonitoringCadence()
        #expect(!schedule.shouldRefresh(last: base, at: base.addingTimeInterval(1), idle: false, suspended: false))
        #expect(schedule.shouldRefresh(last: base, at: base.addingTimeInterval(5), idle: false, suspended: false))
        #expect(!schedule.shouldRefresh(last: base, at: base.addingTimeInterval(60), idle: true, suspended: false))
        #expect(!schedule.shouldRefresh(last: nil, at: base, idle: false, suspended: true))
    }

    @Test func dailyCacheReplacesStableIDsAndRetractsProvisionalTime() {
        var cache = DailySegmentCache(day: calendar.startOfDay(for: base))
        var presence = TrackingSegment(kind: .presence, value: "active", label: "active", start: base, end: base.addingTimeInterval(100))
        cache.apply([presence])
        presence.end = base
        cache.apply([presence])
        #expect(cache.segments.isEmpty)
        presence.end = base.addingTimeInterval(20)
        cache.apply([presence, presence])
        #expect(cache.segments.count == 1)
        #expect(cache.segments.first?.end == presence.end)
    }

    @Test func onePassLiveAndConfirmedScopeMatchSeparateCalculations() {
        var engine = TrackingEngine(at: base)
        engine.setApplication(.init(bundleID: "chrome", name: "Chrome"), at: base)
        engine.setWebsite("example.com", browser: "chrome", at: base)
        engine.setApplication(.init(bundleID: "chat", name: "Chat"), at: base.addingTimeInterval(40))
        let end = base.addingTimeInterval(100)
        let live = engine.checkpoint(at: end)
        let confirmed = engine.checkpoint(at: end, confirmedThrough: base.addingTimeInterval(30))
        var preferences = MonitoringPreferences()
        preferences.selectedApps = ["chat"]
        preferences.websites = [.init(domain: "example.com")]
        let overrides = Dictionary(uniqueKeysWithValues: confirmed.filter { $0.kind == .presence }.map { ($0.id, $0.end) })
        let result = UsageCalculator.calculate(live, from: base, to: end, preferences: preferences, confirmedPresenceEnds: overrides)
        #expect(result.summary.totalSeconds == 100)
        #expect(result.summary.scopedSeconds == 100)
        #expect(result.confirmedScopedSeconds == UsageCalculator.summarize(confirmed, from: base, to: end, preferences: preferences).scopedSeconds)
        #expect(result.confirmedScopedSeconds == 30)
    }

    @Test func dailyReportPartitionsCrossMidnightAndPreservesQuotaDeduplication() throws {
        let start = calendar.startOfDay(for: base)
        let midnight = calendar.date(byAdding: .day, value: 1, to: start)!
        let end = midnight.addingTimeInterval(90)
        let rows: [TrackingSegment] = [
            .init(kind: .application, value: "chrome", label: "Chrome", start: midnight.addingTimeInterval(-60), end: end),
            .init(kind: .website, value: "example.com", label: "example.com", browserBundleID: "chrome", start: midnight.addingTimeInterval(-30), end: end),
            .init(kind: .presence, value: "active", label: "active", start: midnight.addingTimeInterval(-60), end: midnight.addingTimeInterval(30)),
            .init(kind: .presence, value: "active", label: "active", start: midnight.addingTimeInterval(10), end: end)
        ]
        var preferences = MonitoringPreferences()
        preferences.selectedApps = ["chrome"]
        preferences.websites = [.init(domain: "example.com")]
        let report = try UsageReportBuilder.build(segments: rows, interval: .init(start: start, end: end), period: .all, now: end, preferences: preferences, quotas: [start: 60, midnight: 120], calendar: calendar)
        #expect(report.summary.totalSeconds == 150)
        #expect(report.summary.scopedSeconds == 150)
        #expect(report.summary.applications.first?.websites.first?.seconds == 120)
        #expect(report.days.map(\.total) == [60, 90])
        #expect(report.days.map(\.quotaMinutes) == [60, 120])
        #expect(report.summary == UsageCalculator.summarize(rows, from: start, to: end, preferences: preferences))
    }

    @Test func reportIncludesEmptyDaysAndDaylightSavingHours() throws {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = ISO8601DateFormatter().date(from: "2026-03-08T00:00:00-08:00")!
        let end = local.date(byAdding: .day, value: 1, to: start)!
        let report = try UsageReportBuilder.build(segments: [], interval: .init(start: start, end: end), period: .day, now: end, preferences: .init(), calendar: local)
        #expect(report.days.count == 1)
        #expect(!report.days[0].hasRecord)
        #expect(report.trend.count == 23)
        #expect(report.summary.totalSeconds == 0)
    }

    @Test func readOnlyReportConnectionCannotModifyUsage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let writer = try SegmentStore(url: url)
        let row = TrackingSegment(kind: .application, value: "chat", label: "Chat", start: base, end: base.addingTimeInterval(10))
        try writer.upsert([row])
        let reader = try SegmentStore(url: url, readOnly: true)
        #expect(try reader.segments(from: base, to: base.addingTimeInterval(20)).count == 1)
        #expect(throws: SegmentStore.StoreError.self) { try reader.upsert([row]) }
        #expect(try writer.segments(from: base, to: base.addingTimeInterval(20)).first?.end == row.end)
    }

    @Test func backgroundReportHonorsZeroLengthIdleRetractionOverSavedCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let writer = try SegmentStore(url: url)
        let end = base.addingTimeInterval(100)
        var presence = TrackingSegment(kind: .presence, value: "active", label: "active", start: base, end: end)
        try writer.upsert([presence, .init(kind: .application, value: "chat", label: "Chat", start: base, end: end)])
        presence.end = base
        let report = try await UsageReportLoader.load(url: url, period: .day, anchor: base, now: end, preferences: .init(), checkpoint: [presence], calendar: calendar)
        #expect(report.summary.totalSeconds == 0)
        #expect(report.days.first?.hasRecord == true)
        #expect(try writer.segments(from: base, to: end).count == 2)
    }

    @Test func newDayCacheKeepsCrossMidnightActivityButDropsRetractedRows() {
        let midnight = calendar.startOfDay(for: base)
        var cache = DailySegmentCache(day: midnight)
        var row = TrackingSegment(kind: .presence, value: "active", label: "active", start: midnight.addingTimeInterval(-100), end: midnight.addingTimeInterval(20))
        cache.apply([row])
        #expect(cache.segments.count == 1)
        row.end = midnight.addingTimeInterval(-10)
        cache.apply([row])
        #expect(cache.segments.isEmpty)
    }
}
