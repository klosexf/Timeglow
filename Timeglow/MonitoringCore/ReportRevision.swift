import Foundation

struct ReportScope: Hashable, Sendable {
    var apps: Set<String>
    var websites: [WebsiteRule]
    var quota: Int
    init(_ preferences: MonitoringPreferences) {
        apps = preferences.selectedApps
        websites = preferences.websites
        quota = preferences.quotaMinutes
    }
}

/// Tracks both the new and previously published extent, including zero-length retractions.
struct ReportRevision: Sendable {
    private(set) var days: [Date: UInt64] = [:]
    private var extents: [UUID: TrackingSegment] = [:]
    private var counter: UInt64 = 0
    private var calendar: Calendar?
    private var latestEnd = Date.distantPast

    mutating func record(_ rows: [TrackingSegment], calendar: Calendar) {
        if self.calendar != calendar { days.removeAll(); extents.removeAll(); self.calendar = calendar }
        counter &+= 1
        for row in rows {
            let end = max(row.end, extents[row.id]?.end ?? row.end)
            latestEnd = max(latestEnd, end)
            var day = calendar.startOfDay(for: row.start)
            repeat {
                days[day] = counter
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            } while day < end
            extents[row.id] = row
        }
        // Only open/recently edited IDs need their previous extent retained.
        extents = extents.filter { $0.value.end >= latestEnd.addingTimeInterval(-2 * 86400) }
    }

    func version(in interval: DateInterval) -> UInt64 {
        days.filter { $0.key >= interval.start && $0.key < interval.end }.values.max() ?? 0
    }
}
