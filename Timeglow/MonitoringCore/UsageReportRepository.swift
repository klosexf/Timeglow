import Foundation

/// One reader/cache shared by statistics and overview. Actor work runs off the UI executor.
actor UsageReportRepository {
    private struct Key: Hashable {
        var day: Date
        var calendar: Calendar
        var scope: ReportScope
        var hourly: Bool
    }
    private struct Entry {
        var revision: UInt64
        var report: UsageReport
        var access: UInt64
    }
    private let store: SegmentStore
    private let capacity: Int
    private var cache: [Key: Entry] = [:]
    private var access: UInt64 = 0
    private(set) var dayBuildCount = 0

    init(url: URL, capacity: Int = 512) throws {
        store = try SegmentStore(url: url, readOnly: true)
        self.capacity = max(1, capacity)
    }

    func load(period: ReportPeriod, anchor: Date, now: Date, preferences: MonitoringPreferences,
              checkpoint: [TrackingSegment], revisions: [Date: UInt64], calendar: Calendar = .current) throws -> UsageReport {
        try Task.checkCancellation()
        let interval = period.interval(anchor: anchor, firstRecord: try store.firstRecordDate(), now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let scope = ReportScope(preferences)
        var dates: [Date] = [], missing: [Date] = []
        var result: [Date: UsageReport] = [:]
        var day = interval.start
        while day < interval.end {
            try Task.checkCancellation()
            dates.append(day)
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let key = Key(day: day, calendar: calendar, scope: scope, hourly: period == .day)
            let touched = checkpoint.contains { $0.start < next && max($0.start, $0.end) >= day }
            if day < today, !touched, var entry = cache[key], entry.revision == revisions[day, default: 0] {
                access &+= 1
                entry.access = access
                cache[key] = entry
                result[day] = entry.report
            } else { missing.append(day) }
            day = next
        }
        if let first = missing.first, let last = missing.last {
            let end = min(calendar.date(byAdding: .day, value: 1, to: last)!, now)
            let saved = try store.segments(from: first, to: end)
            var rows = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
            for row in checkpoint { rows[row.id] = row }
            // Cold loads use the existing single-pass builder and capture its daily
            // summaries. Do not construct hundreds of separate complete reports.
            if result.isEmpty && period != .day {
                var quotas: [Date: Int] = [:]
                for date in missing {
                    try Task.checkCancellation()
                    let key = "quota:" + ISO8601DateFormatter.string(from: date, timeZone: calendar.timeZone, formatOptions: [.withFullDate])
                    if let data = try store.data(forKey: key), let quota = try? JSONDecoder().decode(Int.self, from: data) { quotas[date] = quota }
                }
                let report = try UsageReportBuilder.build(segments: Array(rows.values), interval: interval, period: period, now: now,
                    preferences: preferences, quotas: quotas, calendar: calendar) { daily, summary in
                    self.dayBuildCount += 1
                    if daily.date < today {
                        let next = calendar.date(byAdding: .day, value: 1, to: daily.date)!
                        self.access &+= 1
                        self.cache[Key(day: daily.date, calendar: calendar, scope: scope, hourly: false)] = .init(
                            revision: revisions[daily.date, default: 0], report: .init(interval: .init(start: daily.date, end: next),
                                summary: summary, days: [daily], trend: [.init(date: daily.date, total: daily.total, scoped: daily.scoped)], categories: []), access: self.access)
                    }
                }
                trimCache()
                return report
            }
            let buckets = try UsageReportBuilder.partition(Array(rows.values), from: first, to: end, component: .day, calendar: calendar)
            for date in missing {
                try Task.checkCancellation()
                let next = calendar.date(byAdding: .day, value: 1, to: date)!
                let key = "quota:" + ISO8601DateFormatter.string(from: date, timeZone: calendar.timeZone, formatOptions: [.withFullDate])
                let quota = try store.data(forKey: key).flatMap { try? JSONDecoder().decode(Int.self, from: $0) }
                let report = try UsageReportBuilder.build(segments: buckets[date] ?? [], interval: .init(start: date, end: next),
                    period: period == .day ? .day : .week, now: now, preferences: preferences,
                    quotas: quota.map { [date: $0] } ?? [:], calendar: calendar)
                dayBuildCount += 1
                result[date] = report
                if date < today {
                    access &+= 1
                    cache[Key(day: date, calendar: calendar, scope: scope, hourly: period == .day)] = .init(revision: revisions[date, default: 0], report: report, access: access)
                }
            }
            trimCache()
        }
        let reports = dates.compactMap { result[$0] }
        if period == .day, let report = reports.first { return report }
        return UsageReportBuilder.combine(reports, interval: interval)
    }

    private func trimCache() {
        if cache.count > capacity {
            for key in cache.sorted(by: { $0.value.access < $1.value.access }).prefix(cache.count - capacity).map(\.key) { cache[key] = nil }
        }
    }
}
