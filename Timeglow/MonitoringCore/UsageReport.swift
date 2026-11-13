import Foundation

enum ReportPeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, all
    var id: String { rawValue }
    var title: String { self == .day ? "今日" : self == .week ? "每周" : "累计" }
    func interval(anchor: Date, firstRecord: Date?, now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let day = calendar.startOfDay(for: anchor)
        if self == .day { return .init(start: day, end: calendar.date(byAdding: .day, value: 1, to: day)!) }
        if self == .week {
            let offset = (calendar.component(.weekday, from: day) + 5) % 7
            let start = calendar.date(byAdding: .day, value: -offset, to: day)!
            return .init(start: start, end: calendar.date(byAdding: .day, value: 7, to: start)!)
        }
        return .init(start: calendar.startOfDay(for: min(firstRecord ?? now, now)), end: now)
    }
}

struct DailyUsage: Identifiable, Sendable {
    var date: Date
    var total: Double
    var scoped: Double
    var quotaMinutes: Int
    var hasRecord: Bool
    var id: Date { date }
    var percent: Double { scoped / Double(max(1, quotaMinutes) * 60) * 100 }
}

struct UsageTrendPoint: Identifiable, Sendable {
    var date: Date
    var total: Double
    var scoped: Double
    var id: Date { date }
}

struct UsageCategory: Identifiable, Sendable {
    var name: String
    var seconds: Double
    var id: String { name }
}

struct UsageReport: Sendable {
    var interval: DateInterval
    var summary: UsageSummary
    var days: [DailyUsage]
    var trend: [UsageTrendPoint]
    var categories: [UsageCategory]
    var averageSeconds: Double { summary.totalSeconds / Double(max(1, days.filter(\.hasRecord).count)) }

    static func category(bundleID: String, name: String) -> String {
        let text = (bundleID + " " + name).lowercased()
        if ["safari", "chrome", "firefox", "browser", "edge", "arc", "vivaldi"].contains(where: text.contains) { return "网页浏览" }
        if ["xcode", "code", "figma", "sketch", "photoshop", "illustrator", "finalcut", "premiere", "jetbrains", "codex"].contains(where: text.contains) { return "创作与开发" }
        if ["wechat", "xinwechat", "slack", "mail", "messages", "teams", "qq"].contains(where: text.contains) { return "沟通" }
        if ["bilibili", "music", "iina", "vlc", "quicktime", "spotify"].contains(where: text.contains) { return "影音" }
        return "系统与其他"
    }
}
