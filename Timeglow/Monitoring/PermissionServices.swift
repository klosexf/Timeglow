import Foundation
import Combine
import ServiceManagement
import UserNotifications

@MainActor
final class PermissionServices: ObservableObject {
    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published var loginError: String?
    @Published var notificationError: String?
    var previewReminder: ((ReminderContext, @escaping () -> Void) -> Void)?

    func refresh() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        notificationStatus = settings.authorizationStatus
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func requestNotifications() async {
        notificationError = nil
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refresh()
        } catch { self.notificationError = error.localizedDescription }
    }

    func setLoginEnabled(_ enabled: Bool) async {
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
            await refresh()
        } catch { self.loginError = error.localizedDescription }
    }

    func send(identifier: String, title: String, body: String, reminder: ReminderContext? = nil) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let reminder {
            content.userInfo["timeglow.reminder.v1"] = try JSONEncoder().encode(reminder)
        }
        try await UNUserNotificationCenter.current().add(.init(identifier: identifier, content: content, trigger: nil))
    }
}
