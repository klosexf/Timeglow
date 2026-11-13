import Testing
@testable import MonitoringCore

struct ReminderRulesTests {
    @Test func crossesMultipleConfiguredNodesOnceWithoutRepeating() {
        var preferences = MonitoringPreferences()
        preferences.notificationsEnabled = true
        preferences.quotaMinutes = 100
        #expect(ReminderRules.crossed(previous: 19 * 60, current: 31 * 60, preferences: preferences) == [20, 30])
        #expect(ReminderRules.crossed(previous: 31 * 60, current: 32 * 60, preferences: preferences).isEmpty)
        #expect(ReminderRules.crossed(previous: 31 * 60, current: 20 * 60, preferences: preferences).isEmpty)
    }

    @Test func minuteRulesAndDisabledNotifications() {
        var preferences = MonitoringPreferences()
        preferences.notificationsEnabled = true
        preferences.reminderKind = "minutes"
        #expect(ReminderRules.crossed(previous: 29 * 60, current: 80 * 60, preferences: preferences) == [30, 70, 80])
        preferences.notificationsEnabled = false
        #expect(ReminderRules.crossed(previous: 0, current: 10000, preferences: preferences).isEmpty)
    }
}
