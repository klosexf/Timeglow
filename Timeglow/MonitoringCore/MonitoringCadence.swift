import Foundation

/// Only painting/aggregation is throttled. Segment boundaries keep their event timestamps.
struct MonitoringCadence {
    let refreshInterval: TimeInterval = 5

    func shouldRefresh(last: Date?, at now: Date, idle: Bool, suspended: Bool) -> Bool {
        guard !idle, !suspended else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= refreshInterval
    }
}

/// Replaces checkpoints in memory instead of re-reading the entire day on each save.
struct DailySegmentCache {
    var day: Date
    private var rows: [UUID: TrackingSegment] = [:]
    var segments: [TrackingSegment] { Array(rows.values) }

    init(day: Date) { self.day = day }

    mutating func apply(_ checkpoint: [TrackingSegment]) {
        for row in checkpoint {
            if row.end > day && row.end > row.start { rows[row.id] = row }
            else { rows.removeValue(forKey: row.id) }
        }
    }
}
