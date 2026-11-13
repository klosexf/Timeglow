import Foundation

struct AppIdentity: Codable, Equatable, Sendable {
    var bundleID: String
    var name: String
}

enum SegmentKind: String, Codable, Sendable {
    case application, website, presence
}

struct TrackingSegment: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: SegmentKind
    var value: String
    var label: String
    var browserBundleID: String? = nil
    var start: Date
    var end: Date
}

struct WebsiteRule: Codable, Equatable, Hashable, Sendable {
    var domain: String
    var enabled: Bool = true
}

struct MonitoringPreferences: Codable, Equatable, Sendable {
    var idleSeconds: Double = 180
    var enabledBrowsers: Set<String> = []
    var quotaMinutes: Int = 120
    var warningPercent: Int = 70
    var spentPercent: Int = 100
    var notificationsEnabled: Bool = false
    var reminderKind: String = "percent"
    var percentThresholds: [Int] = [20, 30, 60]
    var minuteThresholds: [Int] = [30, 70, 80]
    var message: String = "先停一下，把时间留给今天真正想做的事。"
    var selectedApps: Set<String> = []
    var websites: [WebsiteRule] = []

    func includesWebsite(_ domain: String) -> Bool {
        websites.contains { $0.enabled && DomainRules.matches(host: domain, rule: $0.domain) }
    }

    @discardableResult
    mutating func addWebsite(_ input: String) -> Bool {
        guard let domain = DomainRules.normalized(input) else { return false }
        guard !includesWebsite(domain) else { return true }
        if let index = websites.firstIndex(where: { $0.domain == domain }) {
            websites[index].enabled = true
        } else {
            websites.append(.init(domain: domain))
        }
        return true
    }
}

struct ApplicationUsage: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var seconds: Double
    var websites: [WebsiteUsage]
}

struct WebsiteUsage: Identifiable, Equatable, Sendable {
    var id: String
    var seconds: Double
}

struct UsageSummary: Equatable, Sendable {
    var applications: [ApplicationUsage] = []
    var totalSeconds: Double { applications.reduce(0) { $0 + $1.seconds } }
    var scopedSeconds: Double = 0
}

