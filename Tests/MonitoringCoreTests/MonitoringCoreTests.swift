import Foundation
import Testing
@testable import MonitoringCore

struct MonitoringCoreTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func segment(_ kind: SegmentKind, _ value: String, _ start: Double, _ end: Double, browser: String? = nil) -> TrackingSegment {
        .init(kind: kind, value: value, label: value, browserBundleID: browser, start: base.addingTimeInterval(start), end: base.addingTimeInterval(end))
    }

    @Test func onlyActiveForegroundTimeCounts() {
        let rows = [segment(.application, "chat", 0, 100), segment(.application, "browser", 100, 200), segment(.presence, "active", 0, 120), segment(.presence, "idle", 120, 200)]
        let result = UsageCalculator.summarize(rows, from: base, to: base.addingTimeInterval(200))
        #expect(result.totalSeconds == 120)
        #expect(result.applications.first(where: { $0.id == "chat" })?.seconds == 100)
        #expect(result.applications.first(where: { $0.id == "browser" })?.seconds == 20)
    }

    @Test func websitesRequireMatchingForegroundBrowser() {
        let rows = [segment(.application, "chrome", 0, 50), segment(.application, "chat", 50, 100), segment(.presence, "active", 0, 100), segment(.website, "bilibili.com", 0, 100, browser: "chrome")]
        var preferences = MonitoringPreferences()
        preferences.websites = [.init(domain: "bilibili.com")]
        let result = UsageCalculator.summarize(rows, from: base, to: base.addingTimeInterval(100), preferences: preferences)
        #expect(result.scopedSeconds == 50)
        #expect(result.totalSeconds == 100)
        #expect(result.applications.first(where: { $0.id == "chrome" })?.websites.first?.seconds == 50)
    }

    @Test func browserAndItsSelectedWebsiteAreNotDoubleCounted() {
        let rows = [segment(.application, "chrome", 0, 100), segment(.presence, "active", 0, 100), segment(.website, "bilibili.com", 0, 60, browser: "chrome")]
        var preferences = MonitoringPreferences()
        preferences.selectedApps = ["chrome"]
        preferences.websites = [.init(domain: "bilibili.com")]
        let result = UsageCalculator.summarize(rows, from: base, to: base.addingTimeInterval(100), preferences: preferences)
        #expect(result.scopedSeconds == 100)
        #expect(result.totalSeconds == 100)
    }

    @Test func rangesClipAcrossMidnightAndIgnoreMissingPresence() {
        let rows = [segment(.application, "chat", -50, 50), segment(.presence, "active", -50, 50)]
        #expect(UsageCalculator.summarize(rows, from: base, to: base.addingTimeInterval(100)).totalSeconds == 50)
        #expect(UsageCalculator.summarize([rows[0]], from: base, to: base.addingTimeInterval(100)).totalSeconds == 0)
    }

    @Test func duplicatePresenceIntervalsDoNotInflateTotals() {
        let rows = [segment(.application, "chat", 0, 100), segment(.presence, "active", 0, 80), segment(.presence, "active", 20, 100)]
        #expect(UsageCalculator.summarize(rows, from: base, to: base.addingTimeInterval(100)).totalSeconds == 100)
    }

    @Test func domainsAreNormalizedAndMatchedAtLabelBoundaries() {
        #expect(DomainRules.normalized("https://WWW.Bilibili.com/video/123?token=secret") == "www.bilibili.com")
        #expect(DomainRules.matches(host: "www.bilibili.com", rule: "bilibili.com"))
        #expect(!DomainRules.matches(host: "notbilibili.com", rule: "bilibili.com"))
        #expect(DomainRules.normalized("file:///private/secret") == nil)
        #expect(DomainRules.normalized("javascript:alert(1)") == nil)
    }

    @Test func websiteQuickAddReenablesExistingRuleWithoutDuplicates() {
        var preferences = MonitoringPreferences()
        preferences.websites = [.init(domain: "example.com", enabled: false)]
        let reenabled = preferences.addWebsite("https://EXAMPLE.com/path?query=private")
        #expect(reenabled)
        #expect(preferences.websites == [.init(domain: "example.com")])
        let addedAgain = preferences.addWebsite("example.com")
        #expect(addedAgain)
        #expect(preferences.websites.count == 1)
        let saved = preferences
        let addedInvalid = preferences.addWebsite("javascript:alert(1)")
        #expect(!addedInvalid)
        #expect(preferences == saved)
    }

    @Test func websiteQuickAddRespectsEnabledParentAndDomainBoundaries() {
        var preferences = MonitoringPreferences()
        preferences.websites = [.init(domain: "example.com")]
        #expect(preferences.includesWebsite("www.example.com"))
        let coveredByParent = preferences.addWebsite("www.example.com")
        #expect(coveredByParent)
        #expect(preferences.websites.count == 1)
        #expect(!preferences.includesWebsite("notexample.com"))
        preferences.websites[0].enabled = false
        #expect(!preferences.includesWebsite("www.example.com"))
        let addedChild = preferences.addWebsite("www.example.com")
        #expect(addedChild)
        #expect(!preferences.websites[0].enabled)
        #expect(preferences.includesWebsite("www.example.com"))
        #expect(!preferences.includesWebsite("other.example.com"))
    }

    @Test func websiteQuickAddCountsOnlyTheSiteAndPersistsItsSelection() throws {
        let rows = [segment(.application, "chrome", 0, 100), segment(.presence, "active", 0, 100), segment(.website, "example.com", 0, 60, browser: "chrome")]
        var preferences = MonitoringPreferences()
        #expect(UsageCalculator.summarize(rows, from: base, to: base.addingTimeInterval(100), preferences: preferences).scopedSeconds == 0)
        let added = preferences.addWebsite("example.com")
        #expect(added)
        let restored = try JSONDecoder().decode(MonitoringPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored.includesWebsite("example.com"))
        #expect(restored.selectedApps.isEmpty)
        #expect(UsageCalculator.summarize(rows, from: base, to: base.addingTimeInterval(100), preferences: restored).scopedSeconds == 60)
    }
}
