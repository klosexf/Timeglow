import SwiftUI
import AppKit
import UserNotifications

@main
struct TimeglowApp: App {
    @NSApplicationDelegateAdaptor(TimeglowAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MonitoringMenu(monitor: delegate.monitor, openWorkspace: delegate.presentWorkspace)
        } label: {
            Image(nsImage: TimeglowMenuBarIcon.image)
                .renderingMode(.template)
                .accessibilityLabel("Timeglow")
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { delegate.presentWorkspace("settings") }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class TimeglowAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let monitor = MonitoringController()
    let navigation = WorkspaceNavigation()
    private var mainWindow: NSWindow?
    private var bookmarkWindows: BookmarkWindows?
    private let reminderWindow = ReminderWindowController()
    private var finishedLaunching = false
    private var pendingReminder: ReminderContext?

    override init() {
        super.init()
        // Assign before launch completes so clicks that cold-launch the app are routed too.
        UNUserNotificationCenter.current().delegate = self
        monitor.permissions.previewReminder = { [weak self] in self?.presentReminder($0) }
    }

    private func presentReminder(_ context: ReminderContext) {
        if finishedLaunching { reminderWindow.present(context, monitor: monitor) }
        else { pendingReminder = context }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        monitor.start()
        bookmarkWindows = BookmarkWindows(monitor: monitor, openWorkspace: { [weak self] in self?.presentWorkspace($0) })
        finishedLaunching = true
        if let pendingReminder {
            self.pendingReminder = nil
            reminderWindow.present(pendingReminder, monitor: monitor)
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-monitoring") {
            let arguments = ProcessInfo.processInfo.arguments
            let index = arguments.firstIndex(of: "--verification-seconds")
            let value = index.flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? 25
            if arguments.contains("--verification-performance") {
                // Only this opt-in benchmark opens the statistics page at launch.
                presentWorkspace("statistics")
                var testPreferences = monitor.preferences
                testPreferences.idleSeconds = 0 // Stable active/paused benchmark, independent of operator input.
                monitor.updatePreferences(testPreferences)
            }
            let started = Date()
            var phases: [[String: Any]] = []
            func phase(_ name: String) {
                let store = try? SegmentStore(url: monitor.databaseURL)
                let rows = (try? store?.segments(from: .distantPast, to: Date())) ?? []
                let seconds = rows.filter { $0.kind == .application }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
                phases.append(["name": name, "uptime": ProcessInfo.processInfo.systemUptime, "date": Date().timeIntervalSince1970,
                               "savedApplicationSeconds": seconds, "state": monitor.state])
                if let data = try? JSONSerialization.data(withJSONObject: phases, options: [.prettyPrinted]) {
                    try? data.write(to: monitor.databaseURL.deletingLastPathComponent().appendingPathComponent("phases.json"), options: .atomic)
                }
            }
            Task {
                if arguments.contains("--verification-performance") {
                    // Shared, opt-in test sequence used unchanged in the before/after builds.
                    phase("statistics")
                    try? await Task.sleep(for: .seconds(45))
                    self.mainWindow?.performClose(nil)
                    phase("background")
                    try? await Task.sleep(for: .seconds(50))
                    self.monitor.togglePause()
                    phase("paused")
                    try? await Task.sleep(for: .seconds(40))
                    self.monitor.togglePause()
                    phase("resumed-background")
                    try? await Task.sleep(for: .seconds(30))
                } else {
                    try? await Task.sleep(for: .seconds(min(180, max(5, value))))
                }
                monitor.stop()
                do {
                    let store = try SegmentStore(url: monitor.databaseURL)
                    let rows = try store.segments(from: .distantPast, to: Date())
                    let report: [String: Any] = [
                        "mode": "isolated-live-verification", "database": monitor.databaseURL.path,
                        "elapsedSeconds": Date().timeIntervalSince(started), "phases": phases,
                        "activeApplicationSeconds": UsageCalculator.summarize(rows, from: started, to: Date()).totalSeconds,
                        "segmentCount": rows.count,
                        "applications": Array(Set(rows.filter { $0.kind == .application }.map(\.label))).sorted(),
                        "presenceStates": Array(Set(rows.filter { $0.kind == .presence }.map(\.value))).sorted(),
                        "websiteSegments": rows.filter { $0.kind == .website }.count,
                        "applicationSecondsBeforeIdleFilter": rows.filter { $0.kind == .application }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) },
                        "error": monitor.error ?? NSNull()
                    ]
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: monitor.databaseURL.deletingLastPathComponent().appendingPathComponent("report.json"), options: .atomic)
                    print(String(decoding: data, as: UTF8.self))
                } catch { print("Verification failed: \(error)") }
                NSApp.terminate(nil)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let content = response.notification.request.content
        let snapshot = (content.userInfo["timeglow.reminder.v1"] as? Data)
            .flatMap { try? JSONDecoder().decode(ReminderContext.self, from: $0) }
        let context = snapshot.flatMap { $0.isValid ? $0 : nil }
            ?? ReminderContext.legacy(identifier: response.notification.request.identifier, body: content.body)
        await MainActor.run {
            if let context {
                self.presentReminder(context)
            } else {
                // Older settings test notifications do not contain a usage snapshot.
                self.presentWorkspace("settings")
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func presentWorkspace(_ section: String) {
        navigation.section = section
        if mainWindow == nil {
            let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let window = WorkspaceWindow(contentRect: .init(x: 0, y: 0, width: min(1060, frame.width - 80), height: min(820, frame.height - 70)), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Timeglow"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentMinSize = .init(width: 800, height: 620)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: ContentView(monitor: monitor, navigation: navigation)
                .ignoresSafeArea(.container, edges: .top))
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching an already-running menu bar app must not open the workspace.
        false
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        // Drop the hosting view as well as the window: an ordered-out SwiftUI
        // hierarchy otherwise keeps observing saves and recomputing reports.
        window.contentView = nil
        mainWindow = nil
    }
    func applicationWillTerminate(_ notification: Notification) { reminderWindow.close(); bookmarkWindows?.close(); monitor.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct MonitoringMenu: View {
    let monitor: MonitoringController
    let openWorkspace: (String) -> Void
    var body: some View {
        Text(monitor.state)
        Text("今天全部应用 · \(DurationText.format(monitor.summary.totalSeconds))")
        Divider()
        Button("设置…") { openWorkspace("settings") }
        Button(monitor.isPaused ? "继续记录" : "暂停记录") { monitor.togglePause() }
        Divider()
        Button("退出 Timeglow") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
