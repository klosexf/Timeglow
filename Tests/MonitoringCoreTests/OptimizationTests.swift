import Foundation
import Testing
import SQLite3
@testable import MonitoringCore

struct OptimizationTests {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    let day = Date(timeIntervalSince1970: 1_799_971_200)

    @Test func delayedSaveCannotAcknowledgeLaterClosureOrIdleRetraction() {
        var engine = TrackingEngine(at: day)
        engine.setApplication(.init(bundleID: "chat", name: "Chat"), at: day)
        let earlier = engine.checkpoint(at: day.addingTimeInterval(5))
        engine.setApplication(.init(bundleID: "code", name: "Code"), at: day.addingTimeInterval(7))
        engine.samplePresence(secondsSinceInput: 10, idleAfter: 10, at: day.addingTimeInterval(10))
        engine.acknowledgeSaved(earlier)
        let later = engine.checkpoint(at: day.addingTimeInterval(12))
        #expect(later.contains { $0.value == "chat" && $0.end == day.addingTimeInterval(7) })
        #expect(later.contains { $0.kind == .presence && $0.value == "active" && $0.end == day })
        engine.acknowledgeSaved(later)
        #expect(!engine.checkpoint(at: day.addingTimeInterval(13)).contains { $0.value == "chat" })
    }

    @Test @MainActor func writerIsOffMainOrderedAndDrainMakesFinalCorrectionDurable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let writer = SegmentWriter(store: try SegmentStore(url: url))
        let original = TrackingSegment(kind: .presence, value: "active", label: "active", start: day, end: day.addingTimeInterval(30))
        var corrected = original
        corrected.end = day
        let final = corrected
        let wasMain: Bool = try await withCheckedThrowingContinuation { continuation in
            writer.enqueue({ store in
                try store.upsert([original])
                return Thread.isMainThread
            }) { continuation.resume(with: $0) }
        }
        #expect(!wasMain)
        // Both jobs are queued before either completion runs on MainActor.
        writer.enqueue({ try $0.upsert([original]) }) { _ in }
        writer.enqueue({ try $0.upsert([final]) }) { _ in }
        writer.drain()
        let reader = try SegmentStore(url: url, readOnly: true)
        #expect(try reader.segments(from: day, to: day.addingTimeInterval(40)).isEmpty)
    }

    @Test @MainActor func failedWriteDoesNotPreventFollowingWritesOrQuotaPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let writer = SegmentWriter(store: try SegmentStore(url: url))
        let bad = TrackingSegment(kind: .application, value: "chat", label: "Chat", start: day, end: day.addingTimeInterval(-1))
        let failed: Bool = await withCheckedContinuation { continuation in
            writer.enqueue({ try $0.upsert([bad]) }) { result in
                if case .failure = result { continuation.resume(returning: true) }
                else { continuation.resume(returning: false) }
            }
        }
        #expect(failed)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.enqueue({ store in
                try store.ensureQuota(90, forKey: "quota:test")
                try store.ensureQuota(120, forKey: "quota:test")
            }) { continuation.resume(with: $0) }
        }
        let reader = try SegmentStore(url: url, readOnly: true)
        #expect(try reader.data(forKey: "quota:test").map { try JSONDecoder().decode(Int.self, from: $0) } == 90)
    }

    @Test func revisionsInvalidateBothSidesOfMidnightAfterBackdating() {
        let start = calendar.startOfDay(for: day)
        let midnight = calendar.date(byAdding: .day, value: 1, to: start)!
        var revisions = ReportRevision()
        var row = TrackingSegment(kind: .presence, value: "active", label: "active", start: midnight.addingTimeInterval(-30), end: midnight.addingTimeInterval(60))
        revisions.record([row], calendar: calendar)
        let previous = revisions.days
        row.end = row.start
        revisions.record([row], calendar: calendar)
        #expect(revisions.days[start, default: 0] > previous[start, default: 0])
        #expect(revisions.days[midnight, default: 0] > previous[midnight, default: 0])
        let untouched = calendar.date(byAdding: .day, value: -1, to: start)!
        #expect(revisions.version(in: .init(start: untouched, end: start)) == 0)
    }

    @Test func preferencesAndQuotaRollbackTogetherWhenStorageRejectsWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let store = try SegmentStore(url: url)
        var previous = MonitoringPreferences()
        previous.quotaMinutes = 90
        try store.savePreferences(previous, quotaKey: "quota:test")
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        #expect(sqlite3_exec(connection, "CREATE TRIGGER reject_quota BEFORE INSERT ON settings WHEN NEW.key='quota:test' BEGIN SELECT RAISE(ABORT,'quota write failed'); END", nil, nil, nil) == SQLITE_OK)
        var next = previous
        next.quotaMinutes = 120
        #expect(throws: SegmentStore.StoreError.self) { try store.savePreferences(next, quotaKey: "quota:test") }
        let saved = try JSONDecoder().decode(MonitoringPreferences.self, from: #require(try store.data(forKey: "preferences")))
        #expect(saved == previous)
        #expect(try JSONDecoder().decode(Int.self, from: #require(try store.data(forKey: "quota:test"))) == 90)
        #expect(sqlite3_exec(connection, "DROP TRIGGER reject_quota", nil, nil, nil) == SQLITE_OK)
        try store.savePreferences(next, quotaKey: "quota:test")
        try store.ensureQuota(30, forKey: "quota:test")
        #expect(try JSONDecoder().decode(Int.self, from: #require(try store.data(forKey: "quota:test"))) == 120)
    }

    @Test @MainActor func reminderClaimsRemainOrderedAndReleaseAllowsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SegmentWriter(store: try SegmentStore(url: directory.appendingPathComponent("usage.sqlite")))
        let claims: [Bool] = try await withCheckedThrowingContinuation { continuation in
            writer.enqueue({ store in
                let first = try store.claimReminder("day:percent:20")
                let duplicate = try store.claimReminder("day:percent:20")
                try store.releaseReminder("day:percent:20")
                let retry = try store.claimReminder("day:percent:20")
                return [first, duplicate, retry]
            }) { continuation.resume(with: $0) }
        }
        #expect(claims == [true, false, true])
    }

    @Test func cachedDSTDayPreservesTwentyThreeHourlyBuckets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let store = try SegmentStore(url: url)
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = ISO8601DateFormatter().date(from: "2026-03-08T00:00:00-08:00")!
        let end = local.date(byAdding: .day, value: 1, to: start)!
        try store.upsert([
            .init(kind: .application, value: "chat", label: "Chat", start: start, end: end),
            .init(kind: .presence, value: "active", label: "active", start: start, end: end)
        ])
        let repository = try UsageReportRepository(url: url)
        for _ in 0..<2 {
            let report = try await repository.load(period: .day, anchor: start, now: end.addingTimeInterval(1), preferences: .init(), checkpoint: [], revisions: [:], calendar: local)
            #expect(report.trend.count == 23)
            #expect(report.summary.totalSeconds == 23 * 3600)
        }
        #expect(await repository.dayBuildCount == 1)
    }

    @Test func historyCacheMatchesOriginalAndOnlyRebuildsChangedDays() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let store = try SegmentStore(url: url)
        let start = calendar.startOfDay(for: day)
        let midnight = calendar.date(byAdding: .day, value: 1, to: start)!
        let now = midnight.addingTimeInterval(120)
        let rows: [TrackingSegment] = [
            .init(kind: .application, value: "chrome", label: "Chrome", start: midnight.addingTimeInterval(-60), end: now),
            .init(kind: .website, value: "example.com", label: "example.com", browserBundleID: "chrome", start: midnight.addingTimeInterval(-30), end: now),
            .init(kind: .presence, value: "active", label: "active", start: midnight.addingTimeInterval(-60), end: now)
        ]
        try store.upsert(rows)
        try store.setData(JSONEncoder().encode(60), forKey: "quota:" + ISO8601DateFormatter.string(from: start, timeZone: calendar.timeZone, formatOptions: [.withFullDate]))
        var prefs = MonitoringPreferences()
        prefs.selectedApps = ["chrome"]
        prefs.websites = [.init(domain: "example.com")]
        let repository = try UsageReportRepository(url: url)
        let expected = try await UsageReportLoader.load(url: url, period: .all, anchor: now, now: now, preferences: prefs, checkpoint: [], calendar: calendar)
        let actual = try await repository.load(period: .all, anchor: now, now: now, preferences: prefs, checkpoint: [], revisions: [:], calendar: calendar)
        #expect(actual.summary == expected.summary)
        #expect(actual.days.map(\.total) == expected.days.map(\.total))
        #expect(actual.days.map(\.quotaMinutes) == expected.days.map(\.quotaMinutes))
        #expect(actual.trend.map(\.scoped) == expected.trend.map(\.scoped))
        #expect(actual.interval == expected.interval)
        let built = await repository.dayBuildCount
        let warm = try await repository.load(period: .all, anchor: now, now: now, preferences: prefs, checkpoint: [], revisions: [:], calendar: calendar)
        #expect(actual.timesByDay[start]?.first?.seconds == 60)
        #expect(warm.timesByDay[start]?.first?.seconds == 60)
        #expect(warm.timesByDay[midnight]?.first?.seconds == 120)
        #expect(await repository.dayBuildCount == built + 1) // only today

        // Zero-duration correction retracts yesterday as well as today's presence.
        var presence = rows[2]
        presence.end = presence.start
        try store.upsert([presence])
        let revised = try await repository.load(period: .all, anchor: now, now: now, preferences: prefs, checkpoint: [], revisions: [start: 1, midnight: 1], calendar: calendar)
        #expect(revised.summary.totalSeconds == 0)
        #expect(await repository.dayBuildCount == built + 3)
    }

    @Test func cachedHistoricalDayReusesWorkButScopeTimezoneAndHourlyTrendStayCorrect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let store = try SegmentStore(url: url)
        let start = calendar.startOfDay(for: day)
        let now = start.addingTimeInterval(3 * 86400)
        let rows: [TrackingSegment] = [
            .init(kind: .application, value: "chat", label: "Chat", start: start, end: start.addingTimeInterval(60)),
            .init(kind: .presence, value: "active", label: "active", start: start, end: start.addingTimeInterval(60))
        ]
        try store.upsert(rows)
        let repository = try UsageReportRepository(url: url, capacity: 2)
        var prefs = MonitoringPreferences()
        let first = try await repository.load(period: .day, anchor: start, now: now, preferences: prefs, checkpoint: [], revisions: [:], calendar: calendar)
        let built = await repository.dayBuildCount
        _ = try await repository.load(period: .day, anchor: start, now: now.addingTimeInterval(5), preferences: prefs, checkpoint: [], revisions: [calendar.startOfDay(for: now): 99], calendar: calendar)
        #expect(await repository.dayBuildCount == built)
        #expect(first.trend.count == 24)
        prefs.selectedApps = ["chat"]
        let selected = try await repository.load(period: .day, anchor: start, now: now, preferences: prefs, checkpoint: [], revisions: [:], calendar: calendar)
        #expect(first.summary.scopedSeconds == 0)
        #expect(selected.summary.scopedSeconds == 60)
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let shifted = try await repository.load(period: .day, anchor: start, now: now, preferences: prefs, checkpoint: [], revisions: [:], calendar: local)
        let expected = try await UsageReportLoader.load(url: url, period: .day, anchor: start, now: now, preferences: prefs, checkpoint: [], calendar: local)
        #expect(shifted.summary == expected.summary)
        #expect(shifted.trend.map(\.total) == expected.trend.map(\.total))
    }
}
