import Foundation

enum UsageReportBuilder {
    /// Each segment is assigned only to the calendar buckets it intersects.
    /// A year report no longer scans a year's raw rows once for every day.
    static func build(segments: [TrackingSegment], interval: DateInterval, period: ReportPeriod, now: Date, preferences: MonitoringPreferences, quotas: [Date: Int] = [:], calendar: Calendar = .current,
                      onDay: ((DailyUsage, UsageSummary) -> Void)? = nil) throws -> UsageReport {
        let end = min(interval.end, now)
        let buckets = try partition(segments, from: interval.start, to: end, component: .day, calendar: calendar)
        var days: [DailyUsage] = [], trend: [UsageTrendPoint] = []
        var apps: [String: ApplicationUsage] = [:]
        var sites: [String: [String: Double]] = [:]
        var timesByDay: [Date: [ApplicationTime]] = [:]
        var scoped = 0.0
        var date = interval.start
        while date < interval.end {
            try Task.checkCancellation()
            let next = calendar.date(byAdding: .day, value: 1, to: date)!
            let rows = buckets[date] ?? []
            let summary = UsageCalculator.summarize(rows, from: date, to: min(next, end), preferences: preferences)
            scoped += summary.scopedSeconds
            for app in summary.applications {
                var total = apps[app.id] ?? .init(id: app.id, name: app.name, seconds: 0, websites: [])
                total.name = app.name
                total.seconds += app.seconds
                apps[app.id] = total
                for site in app.websites { sites[app.id, default: [:]][site.id, default: 0] += site.seconds }
            }
            let daily = DailyUsage(date: date, total: summary.totalSeconds, scoped: summary.scopedSeconds, quotaMinutes: quotas[date] ?? preferences.quotaMinutes, hasRecord: rows.contains { $0.kind == .application })
            days.append(daily)
            timesByDay[date] = summary.applications.map(ApplicationTime.init)
            onDay?(daily, summary)
            date = next
        }
        if period == .day {
            let hours = try partition(segments, from: interval.start, to: end, component: .hour, calendar: calendar)
            date = interval.start
            while date < interval.end {
                try Task.checkCancellation()
                let next = calendar.date(byAdding: .hour, value: 1, to: date)!
                let summary = UsageCalculator.summarize(hours[date] ?? [], from: date, to: min(next, end), preferences: preferences)
                trend.append(.init(date: date, total: summary.totalSeconds, scoped: summary.scopedSeconds, hasRecord: hours[date]?.contains { $0.kind == .application } == true))
                date = next
            }
        } else { trend = days.map { .init(date: $0.date, total: $0.total, scoped: $0.scoped, hasRecord: $0.hasRecord) } }
        var applications: [ApplicationUsage] = []
        for var app in apps.values {
            let values: [String: Double] = sites[app.id] ?? [:]
            let websites: [WebsiteUsage] = values.map { WebsiteUsage(id: $0.key, seconds: $0.value) }
            app.websites = websites.sorted { $0.seconds > $1.seconds }
            applications.append(app)
        }
        applications.sort { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }
        var totals: [String: Double] = [:]
        for app in applications { totals[UsageReport.category(bundleID: app.id, name: app.name), default: 0] += app.seconds }
        return .init(interval: interval, summary: .init(applications: applications, scopedSeconds: scoped), days: days, trend: trend, categories: totals.map { .init(name: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }, timesByDay: timesByDay)
    }

    static func combine(_ reports: [UsageReport], interval: DateInterval) -> UsageReport {
        var apps: [String: ApplicationUsage] = [:]
        var sites: [String: [String: Double]] = [:]
        for report in reports {
            for app in report.summary.applications {
                var total = apps[app.id] ?? .init(id: app.id, name: app.name, seconds: 0, websites: [])
                total.name = app.name
                total.seconds += app.seconds
                apps[app.id] = total
                for site in app.websites { sites[app.id, default: [:]][site.id, default: 0] += site.seconds }
            }
        }
        var applications = apps.values.map { app in
            var app = app
            app.websites = (sites[app.id] ?? [:]).map { WebsiteUsage(id: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
            return app
        }
        applications.sort { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }
        var categories: [String: Double] = [:]
        for app in applications { categories[UsageReport.category(bundleID: app.id, name: app.name), default: 0] += app.seconds }
        return .init(interval: interval,
                     summary: .init(applications: applications, scopedSeconds: reports.reduce(0) { $0 + $1.summary.scopedSeconds }),
                     days: reports.flatMap(\.days), trend: reports.flatMap(\.trend),
                     categories: categories.map { .init(name: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds },
                     timesByDay: reports.reduce(into: [:]) { $0.merge($1.timesByDay) { first, _ in first } })
    }

    static func partition(_ segments: [TrackingSegment], from: Date, to: Date, component: Calendar.Component, calendar: Calendar) throws -> [Date: [TrackingSegment]] {
        guard to > from else { return [:] }
        var buckets: [Date: [TrackingSegment]] = [:]
        for (index, segment) in segments.enumerated() where segment.start < to && segment.end > from && segment.end > segment.start {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            var start = max(from, segment.start)
            let end = min(to, segment.end)
            while start < end {
                let bucket = calendar.dateInterval(of: component, for: start)!
                var clipped = segment
                clipped.start = start
                clipped.end = min(bucket.end, end)
                buckets[bucket.start, default: []].append(clipped)
                start = clipped.end
            }
        }
        return buckets
    }
}
