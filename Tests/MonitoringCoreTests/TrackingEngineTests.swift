import Foundation
import Testing
@testable import MonitoringCore

struct TrackingEngineTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let chrome = AppIdentity(bundleID: "chrome", name: "Chrome")
    let chat = AppIdentity(bundleID: "chat", name: "Chat")
    func date(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    @Test func appSwitchClosesWebsiteAndRejectsStaleResponse() {
        var engine = TrackingEngine(at: base)
        engine.setApplication(chrome, at: base)
        engine.setWebsite("bilibili.com", browser: "chrome", at: base)
        engine.setApplication(chat, at: date(20))
        let accepted = engine.setWebsite("github.com", browser: "chrome", at: date(21))
        #expect(!accepted)
        let result = UsageCalculator.summarize(engine.checkpoint(at: date(40)), from: base, to: date(40))
        #expect(result.totalSeconds == 40)
        #expect(result.applications.first(where: { $0.id == "chrome" })?.websites.first?.seconds == 20)
    }

    @Test func idleBackdatesEvenAfterProvisionalCheckpoints() {
        var engine = TrackingEngine(at: base)
        engine.setApplication(chat, at: base)
        let provisional = engine.checkpoint(at: date(100))
        engine.acknowledge(Set(provisional.map(\.id)))
        engine.samplePresence(secondsSinceInput: 180, idleAfter: 180, at: date(200))
        let corrected = engine.checkpoint(at: date(200))
        let oldActiveID = provisional.first(where: { $0.kind == .presence })?.id
        #expect(corrected.first(where: { $0.id == oldActiveID })?.end == date(20))
        #expect(UsageCalculator.summarize(corrected, from: base, to: date(200)).totalSeconds == 20)
    }

    @Test func sleepAndRestartDoNotInventElapsedUsage() {
        var engine = TrackingEngine(at: base)
        engine.setApplication(chat, at: base)
        engine.suspend(at: date(20))
        #expect(UsageCalculator.summarize(engine.checkpoint(at: date(200)), from: base, to: date(200)).totalSeconds == 20)
        engine.resume(at: date(200))
        engine.setApplication(chat, at: date(200))
        #expect(UsageCalculator.summarize(engine.checkpoint(at: date(220)), from: base, to: date(220)).totalSeconds == 40)
    }

    @Test func failedWebsiteReadDropsOldDomain() {
        var engine = TrackingEngine(at: base)
        engine.setApplication(chrome, at: base)
        engine.setWebsite("github.com", browser: "chrome", at: base)
        engine.setWebsite(nil, browser: "chrome", at: date(10))
        let result = UsageCalculator.summarize(engine.checkpoint(at: date(30)), from: base, to: date(30))
        #expect(result.applications.first?.websites.first?.seconds == 10)
    }

    @Test func remindersDoNotCountUnconfirmedIdleGraceTime() {
        var engine = TrackingEngine(at: base)
        engine.setApplication(chat, at: base)
        let live = engine.checkpoint(at: date(100))
        let confirmed = engine.checkpoint(at: date(100), confirmedThrough: date(20))
        #expect(UsageCalculator.summarize(live, from: base, to: date(100)).totalSeconds == 100)
        #expect(UsageCalculator.summarize(confirmed, from: base, to: date(100)).totalSeconds == 20)
    }
}
