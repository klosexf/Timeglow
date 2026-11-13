import Foundation

enum ReminderRules {
    static func crossed(previous: Double, current: Double, preferences: MonitoringPreferences) -> [Int] {
        guard preferences.notificationsEnabled, current.isFinite, previous.isFinite, current >= previous, preferences.quotaMinutes > 0 else { return [] }
        let isPercent = preferences.reminderKind == "percent"
        let nodes = isPercent ? preferences.percentThresholds : preferences.minuteThresholds
        return Set(nodes).filter { value in
            guard value > 0 else { return false }
            let seconds = isPercent ? Double(preferences.quotaMinutes) * 60 * Double(value) / 100 : Double(value) * 60
            return previous < seconds && current >= seconds
        }.sorted()
    }
}
