import Foundation

/// Kept inside the system notification so clicks survive app restarts and settings changes.
struct ReminderContext: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case percent, minutes }

    var day: String
    var kind: Kind
    var node: Int
    var quotaMinutes: Int?
    var scopedSeconds: Double?
    var triggeredAt: Date?
    var message: String
    var isTest = false

    static func dayKey(at date: Date, calendar: Calendar = .current) -> String {
        ISO8601DateFormatter.string(from: calendar.startOfDay(for: date), timeZone: calendar.timeZone, formatOptions: [.withFullDate])
    }

    var isValid: Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day), formatter.string(from: date) == day,
              (1...(kind == .percent ? 300 : 1440)).contains(node),
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let quotaMinutes, !(1...1440).contains(quotaMinutes) { return false }
        if let scopedSeconds, !scopedSeconds.isFinite || scopedSeconds < 0 { return false }
        if let triggeredAt, !triggeredAt.timeIntervalSince1970.isFinite { return false }
        return true
    }

    /// Notifications from older builds have an identifier and body but no snapshot.
    /// In particular, never calculate yesterday's minutes using today's quota.
    static func legacy(identifier: String, body: String) -> Self? {
        let parts = identifier.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = Kind(rawValue: String(parts[1])), let node = Int(parts[2]) else { return nil }
        let value = Self(day: String(parts[0]), kind: kind, node: node, message: body)
        return value.isValid ? value : nil
    }
}

struct ReminderReading: Equatable, Sendable {
    var value: Int
    var unit: String
    var isHistorical: Bool
    var usesCurrentUsage: Bool

    static func make(context: ReminderContext, currentSeconds: Double, currentQuotaMinutes: Int,
                     now: Date = Date(), calendar: Calendar = .current) -> Self {
        let historical = context.day != ReminderContext.dayKey(at: now, calendar: calendar)
        let current = !historical && !context.isTest && currentSeconds.isFinite && currentSeconds >= 0 && currentQuotaMinutes > 0
        let seconds = current ? currentSeconds : context.scopedSeconds
        let quota = current ? currentQuotaMinutes : context.quotaMinutes
        if let seconds, seconds.isFinite, let quota, quota > 0 {
            let percentage = seconds / (Double(quota) * 60) * 100
            // Keep percentages above 100 visible while avoiding integer overflow on malformed data.
            return .init(value: Int(max(0, min(percentage, 100_000))), unit: "%", isHistorical: historical, usesCurrentUsage: current)
        }
        return .init(value: context.node, unit: context.kind == .percent ? "%" : "分钟", isHistorical: historical, usesCurrentUsage: false)
    }
}
