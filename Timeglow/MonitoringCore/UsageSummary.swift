import Foundation

enum DomainRules {
    static func normalized(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              var host = components.url?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard host.count <= 253, host.range(of: "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$", options: .regularExpression) != nil,
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
        return host
    }

    static func matches(host: String, rule: String) -> Bool {
        let host = host.lowercased(), rule = rule.lowercased()
        return host == rule || host.hasSuffix("." + rule)
    }
}

enum UsageCalculator {
    struct Calculation {
        var summary: UsageSummary
        var confirmedScopedSeconds: Double
    }
    private struct Span {
        var start: Date
        var end: Date
        var seconds: Double { end.timeIntervalSince(start) }
    }

    private static func merged(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.end >= span.start {
                result[result.count - 1].end = max(last.end, span.end)
            } else { result.append(span) }
        }
        return result
    }

    private static func intersect(_ lhs: [Span], _ rhs: [Span]) -> [Span] {
        var result: [Span] = [], i = 0, j = 0
        while i < lhs.count && j < rhs.count {
            let start = max(lhs[i].start, rhs[j].start), end = min(lhs[i].end, rhs[j].end)
            if end > start { result.append(.init(start: start, end: end)) }
            if lhs[i].end < rhs[j].end { i += 1 } else { j += 1 }
        }
        return result
    }

    static func summarize(_ segments: [TrackingSegment], from: Date, to: Date, preferences: MonitoringPreferences = .init()) -> UsageSummary {
        calculate(segments, from: from, to: to, preferences: preferences).summary
    }

    /// Shares grouping, clipping and scope merging between display totals and reminders.
    static func calculate(_ segments: [TrackingSegment], from: Date, to: Date, preferences: MonitoringPreferences = .init(), confirmedPresenceEnds: [UUID: Date] = [:]) -> Calculation {
        guard to > from else { return .init(summary: .init(), confirmedScopedSeconds: 0) }
        let segments = segments.filter { $0.start < to && $0.end > from && $0.end > $0.start }
        func spans(_ rows: [TrackingSegment]) -> [Span] {
            merged(rows.map { Span(start: max(from, $0.start), end: min(to, $0.end)) })
        }
        let presence = segments.filter { $0.kind == .presence && $0.value == "active" }
        let active = spans(presence)
        let appGroups = Dictionary(grouping: segments.filter { $0.kind == .application }, by: \.value)
        let browserGroups = Dictionary(grouping: segments.filter { $0.kind == .website }, by: \.browserBundleID)
        var applications: [ApplicationUsage] = [], scoped: [Span] = []
        for (bundleID, rows) in appGroups {
            let appSpans = intersect(spans(rows), active)
            let seconds = appSpans.reduce(0) { $0 + $1.seconds }
            guard seconds > 0 else { continue }
            let websites = Dictionary(grouping: browserGroups[bundleID] ?? [], by: \.value)
            var websiteUsage: [WebsiteUsage] = []
            if preferences.selectedApps.contains(bundleID) { scoped += appSpans }
            for (domain, websiteRows) in websites {
                let websiteSpans = intersect(spans(websiteRows), appSpans)
                let duration = websiteSpans.reduce(0) { $0 + $1.seconds }
                guard duration > 0 else { continue }
                websiteUsage.append(.init(id: domain, seconds: duration))
                if !preferences.selectedApps.contains(bundleID), preferences.websites.contains(where: { $0.enabled && DomainRules.matches(host: domain, rule: $0.domain) }) {
                    scoped += websiteSpans
                }
            }
            applications.append(.init(id: bundleID, name: rows.max(by: { $0.end < $1.end })?.label ?? bundleID, seconds: seconds, websites: websiteUsage.sorted { $0.seconds > $1.seconds }))
        }
        let scope = merged(scoped)
        let scopedSeconds = scope.reduce(0) { $0 + $1.seconds }
        let confirmedScoped: Double
        if confirmedPresenceEnds.isEmpty { confirmedScoped = scopedSeconds }
        else {
            let confirmed = spans(presence.map { row in
                var row = row
                if let end = confirmedPresenceEnds[row.id] { row.end = min(row.end, end) }
                return row
            })
            confirmedScoped = intersect(scope, confirmed).reduce(0) { $0 + $1.seconds }
        }
        return .init(summary: .init(applications: applications.sorted { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }, scopedSeconds: scopedSeconds), confirmedScopedSeconds: confirmedScoped)
    }
}
