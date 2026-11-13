import Foundation

enum UsageReportLoader {
    /// Own the read-only SQLite connection and all report work on a utility task.
    /// No mutable collector state or writer connection crosses the actor boundary.
    static func load(url: URL, period: ReportPeriod, anchor: Date, now: Date, preferences: MonitoringPreferences, checkpoint: [TrackingSegment], calendar: Calendar = .current) async throws -> UsageReport {
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let store = try SegmentStore(url: url, readOnly: true)
            let first = try store.firstRecordDate()
            let interval = period.interval(anchor: anchor, firstRecord: first, now: now, calendar: calendar)
            let saved = try store.segments(from: interval.start, to: min(interval.end, now))
            var rows = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
            // Stable IDs also retract saved provisional rows after an idle backdate.
            for row in checkpoint { rows[row.id] = row }
            var quotas: [Date: Int] = [:]
            var date = interval.start
            while date < interval.end {
                try Task.checkCancellation()
                let key = "quota:" + ISO8601DateFormatter.string(from: date, timeZone: calendar.timeZone, formatOptions: [.withFullDate])
                if let data = try store.data(forKey: key), let quota = try? JSONDecoder().decode(Int.self, from: data) { quotas[date] = quota }
                date = calendar.date(byAdding: .day, value: 1, to: date)!
            }
            return try UsageReportBuilder.build(segments: Array(rows.values), interval: interval, period: period, now: now, preferences: preferences, quotas: quotas, calendar: calendar)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}
