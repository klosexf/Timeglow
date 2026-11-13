import Foundation

/// App, website and presence are independent streams. Checkpoints keep stable IDs.
struct TrackingEngine {
    private(set) var application: AppIdentity?
    private(set) var isSuspended = false
    private(set) var isIdle = false
    private var appCursor: TrackingSegment?
    private var webCursor: TrackingSegment?
    private var presenceCursor: TrackingSegment?
    private var pending: [UUID: TrackingSegment] = [:]

    init(at date: Date) {
        presenceCursor = .init(kind: .presence, value: "active", label: "active", start: date, end: date)
    }

    mutating func setApplication(_ app: AppIdentity?, at date: Date) {
        guard !isSuspended, app != application else { return }
        close(.application, at: date)
        close(.website, at: date)
        application = app
        if let app {
            appCursor = .init(kind: .application, value: app.bundleID, label: app.name, start: date, end: date)
        }
    }

    @discardableResult mutating func setWebsite(_ domain: String?, browser: String, at date: Date) -> Bool {
        guard !isSuspended, !isIdle, application?.bundleID == browser else { return false }
        let normalized = domain.flatMap(DomainRules.normalized)
        guard webCursor?.value != normalized else { return true }
        close(.website, at: date)
        if let normalized {
            webCursor = .init(kind: .website, value: normalized, label: normalized, browserBundleID: browser, start: date, end: date)
        }
        return true
    }

    mutating func samplePresence(secondsSinceInput: Double, idleAfter: Double, at date: Date) {
        guard !isSuspended else { return }
        let idle = idleAfter > 0 && secondsSinceInput.isFinite && secondsSinceInput >= idleAfter
        guard idle != isIdle else { return }
        let boundary = idle ? max(presenceCursor?.start ?? date, date.addingTimeInterval(-secondsSinceInput)) : date
        close(.presence, at: boundary)
        isIdle = idle
        presenceCursor = .init(kind: .presence, value: idle ? "idle" : "active", label: idle ? "idle" : "active", start: boundary, end: date)
        // URL context must be reacquired after a break instead of extending a stale page.
        close(.website, at: date)
    }

    mutating func suspend(at date: Date) {
        guard !isSuspended else { return }
        close(.application, at: date)
        close(.website, at: date)
        close(.presence, at: date)
        application = nil
        isSuspended = true
        isIdle = false
    }

    mutating func resume(at date: Date) {
        guard isSuspended else { return }
        isSuspended = false
        presenceCursor = .init(kind: .presence, value: "active", label: "active", start: date, end: date)
    }

    func checkpoint(at date: Date, confirmedThrough: Date? = nil) -> [TrackingSegment] {
        var result = Array(pending.values)
        for cursor in [appCursor, webCursor, presenceCursor].compactMap({ $0 }) {
            var segment = cursor
            segment.end = max(segment.start, date)
            if segment.kind == .presence, segment.value == "active", let confirmedThrough {
                segment.end = max(segment.start, min(segment.end, confirmedThrough))
            }
            result.append(segment)
        }
        return result
    }

    mutating func acknowledge(_ ids: Set<UUID>) {
        for id in ids { pending.removeValue(forKey: id) }
    }

    mutating func acknowledgeSaved(_ segments: [TrackingSegment]) {
        // A cursor may have closed/backdated while an earlier snapshot was saving.
        // Only remove the exact version that reached durable storage.
        for row in segments where pending[row.id] == row { pending.removeValue(forKey: row.id) }
    }

    private mutating func close(_ kind: SegmentKind, at date: Date) {
        let cursor: TrackingSegment?
        switch kind {
        case .application: cursor = appCursor; appCursor = nil
        case .website: cursor = webCursor; webCursor = nil
        case .presence: cursor = presenceCursor; presenceCursor = nil
        }
        guard var value = cursor else { return }
        value.end = max(value.start, date)
        // Zero duration updates retract any previously stored provisional checkpoint.
        pending[value.id] = value
    }
}
