import AppKit
import SwiftUI

@MainActor
final class BookmarkWindows {
    private let monitor: MonitoringController
    private let positionURL: URL
    private let openWorkspace: (String) -> Void
    private var bookmark: NSPanel!
    private var overview: NSPanel!
    private var screenObserver: NSObjectProtocol?
    private var presentationObserver: NSKeyValueObservation?
    private var overviewMouseMonitors: [Any] = []
    private var side: String
    private var heightFraction: Double
    private var overviewVisible = false {
        didSet {
            guard let handle = bookmark?.contentView as? BookmarkHandleView else { return }
            handle.setAccessibilityValue(overviewVisible ? "已展开" : "已收起")
            NSAccessibility.post(element: handle, notification: .valueChanged)
        }
    }
    private var dragOffset = NSPoint.zero

    init(monitor: MonitoringController, openWorkspace: @escaping (String) -> Void) {
        self.monitor = monitor
        self.openWorkspace = openWorkspace
        positionURL = monitor.databaseURL.deletingLastPathComponent().appendingPathComponent("bookmark.json")
        let position = (try? Data(contentsOf: positionURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        side = position?["side"] as? String == "left" ? "left" : "right"
        heightFraction = max(0, min(1, position?["heightFraction"] as? Double ?? 0.5))
        bookmark = makePanel(size: BookmarkLayout.size, title: "Timeglow 书签")
        overview = makePanel(size: .init(width: 348, height: 610), title: "Timeglow 使用概览")
        let handle = BookmarkHandleView(frame: .init(origin: .zero, size: bookmark.frame.size))
        handle.setAccessibilityElement(true)
        handle.setAccessibilityRole(.button)
        handle.setAccessibilityLabel("Timeglow 书签，点击查看使用概览，可拖动换边")
        handle.setAccessibilityValue("已收起")
        handle.onClick = { [weak self] in self?.toggleOverview() }
        handle.onDragStart = { [weak self] point in
            guard let self else { return }
            self.hideOverview()
            self.dragOffset = .init(x: point.x - self.bookmark.frame.minX, y: point.y - self.bookmark.frame.minY)
        }
        handle.onDrag = { [weak self] point in self?.drag(to: point) }
        handle.onDrop = { [weak self] in self?.dockAndSave() }
        bookmark.contentView = handle
        updateBookmarkFace()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeOnScreen() }
        }
        // This observes the active app's system presentation, including other apps.
        presentationObserver = NSApp.observe(\.currentSystemPresentationOptions, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateVisibility() }
        }
        placeOnScreen()
        updateVisibility()
    }

    func close() {
        presentationObserver?.invalidate()
        presentationObserver = nil
        bookmark.orderOut(nil)
        hideOverview()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    private func makePanel(size: NSSize, title: String) -> NSPanel {
        let panel = NSPanel(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title
        panel.level = .floating
        // Keep the bookmark and overview on ordinary desktops, outside full-screen spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setAccessibilitySubrole(.floatingWindow)
        return panel
    }

    private var fullScreenActive: Bool {
        NSApp.currentSystemPresentationOptions.contains(.fullScreen)
    }

    private func updateVisibility() {
        guard presentationObserver != nil else { return }
        if fullScreenActive {
            hideOverview()
            bookmark.orderOut(nil)
        } else if !bookmark.isVisible {
            bookmark.orderFrontRegardless()
        }
    }

    private func updateBookmarkFace() {
        guard let handle = bookmark.contentView as? BookmarkHandleView else { return }
        handle.subviews.forEach { $0.removeFromSuperview() }
        let face = NSHostingView(rootView: LiveBookmarkFace(monitor: monitor, side: side).environment(\.locale, Locale(identifier: "zh_CN")))
        face.frame = handle.bounds
        face.autoresizingMask = [.width, .height]
        handle.addSubview(face)
    }

    private func screen(at point: NSPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? bookmark.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func placeOnScreen() {
        let frame = (bookmark.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let y = frame.minY + max(0, min(1, heightFraction)) * max(0, frame.height - bookmark.frame.height)
        bookmark.setFrameOrigin(.init(x: side == "left" ? frame.minX : frame.maxX - bookmark.frame.width, y: y))
        if overviewVisible, !fullScreenActive { positionOverview(); overview.orderFrontRegardless() }
    }

    private func drag(to point: NSPoint) {
        let frame = screen(at: point).visibleFrame
        bookmark.setFrameOrigin(.init(x: max(frame.minX, min(frame.maxX - bookmark.frame.width, point.x - dragOffset.x)), y: max(frame.minY, min(frame.maxY - bookmark.frame.height, point.y - dragOffset.y))))
    }

    private func dockAndSave() {
        let frame = screen(at: .init(x: bookmark.frame.midX, y: bookmark.frame.midY)).visibleFrame
        side = bookmark.frame.midX < frame.midX ? "left" : "right"
        heightFraction = max(0, min(1, (bookmark.frame.minY - frame.minY) / max(1, frame.height - bookmark.frame.height)))
        do {
            let data = try JSONSerialization.data(withJSONObject: ["side": side, "heightFraction": heightFraction])
            try data.write(to: positionURL, options: .atomic)
        } catch { monitor.error = "书签位置未保存：\(error.localizedDescription)" }
        updateBookmarkFace()
        placeOnScreen()
    }

    private func positionOverview() {
        let frame = (bookmark.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = NSSize(width: min(348, frame.width - 72), height: min(610, frame.height - 32))
        let x = side == "left" ? bookmark.frame.maxX + 12 : bookmark.frame.minX - 12 - size.width
        let y = min(frame.maxY - size.height - 8, max(frame.minY + 8, bookmark.frame.midY - size.height / 2))
        overview.setFrame(.init(origin: .init(x: x, y: y), size: size), display: true)
    }

    private func toggleOverview() {
        guard !fullScreenActive else { return }
        if overviewVisible { hideOverview() }
        else {
            overview.contentView = NSHostingView(rootView: OverviewPanel(monitor: monitor, close: { [weak self] in self?.hideOverview() }, open: { [weak self] section in
                self?.hideOverview()
                self?.openWorkspace(section)
            }))
            overviewVisible = true
            positionOverview()
            overview.orderFrontRegardless()
            monitorOverviewDismissal()
        }
    }

    private func monitorOverviewDismissal() {
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                // The bookmark handles its own toggle on mouse-up. Dismissing on
                // mouse-down there would make the same click reopen the overview.
                if event.window !== self.overview && event.window !== self.bookmark {
                    self.hideOverview()
                }
                return event
            }
        }) {
            overviewMouseMonitors.append(local)
        }
        // Nonactivating panels don't reliably receive a focus-loss notification.
        // Global monitoring covers clicks delivered to other applications.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hideOverview() }
        }) {
            overviewMouseMonitors.append(global)
        }
    }

    private func hideOverview() {
        overviewVisible = false
        overviewMouseMonitors.forEach(NSEvent.removeMonitor)
        overviewMouseMonitors.removeAll()
        overview.orderOut(nil)
        overview.contentView = nil
    }
}

private final class BookmarkHandleView: NSView {
    var onClick: (() -> Void)?
    var onDragStart: ((NSPoint) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDrop: (() -> Void)?
    private var startPoint = NSPoint.zero
    private var dragging = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseDown(with event: NSEvent) { startPoint = NSEvent.mouseLocation; dragging = false }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        if !dragging, hypot(point.x - startPoint.x, point.y - startPoint.y) > 4 { dragging = true; onDragStart?(startPoint) }
        if dragging { onDrag?(point) }
    }
    override func mouseUp(with event: NSEvent) { if dragging { onDrop?() } else { onClick?() }; dragging = false }
}

private struct LiveBookmarkFace: View {
    let monitor: MonitoringController
    let side: String
    var body: some View {
        let percent = monitor.summary.scopedSeconds / Double(monitor.preferences.quotaMinutes * 60) * 100
        BookmarkFace(percent: percent, preferences: monitor.preferences, side: side)
    }
}

private struct OverviewPanel: View {
    let monitor: MonitoringController
    let close: () -> Void
    let open: (String) -> Void
    @State private var period: ReportPeriod = .day
    @State private var periodSummary = UsageSummary()
    private var summary: UsageSummary { period == .day ? monitor.summary : periodSummary }
    var body: some View {
        let used = monitor.summary.scopedSeconds
        let percent = used / Double(monitor.preferences.quotaMinutes * 60) * 100
        let state = Graphite.state(percent: percent, preferences: monitor.preferences)
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("今天 · 使用概览").font(.system(size: 11)).foregroundStyle(Graphite.muted)
                Spacer()
                Button { open("settings") } label: { Image(systemName: "gearshape") }
                    .help("提醒设置").accessibilityLabel("提醒设置")
                Button(action: close) { Image(systemName: "xmark") }.help("收起面板")
            }.buttonStyle(.plain)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("今天合计已用每日限额的").font(.system(size: 11)).foregroundStyle(Graphite.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(percent))").font(.system(size: 35, weight: .medium))
                        Text("%").font(.system(size: 16))
                    }
                }
                Spacer()
                HStack(spacing: 6) { Circle().fill(state.1).frame(width: 7, height: 7); Text(state.0).font(.system(size: 11)).foregroundStyle(Graphite.muted) }.padding(.bottom, 6)
            }
            SmoothQuotaBar(fraction: percent / 100, color: state.1)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("所选合计 · \(DurationText.format(used)) / \(monitor.preferences.quotaMinutes) 分钟")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(used < Double(monitor.preferences.quotaMinutes * 60) ? "剩余 \(DurationText.format(Double(monitor.preferences.quotaMinutes * 60) - used))" : "每日限额已用尽")
                    .fixedSize()
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(Graphite.muted)
            Picker("统计周期", selection: $period) { Text("今天").tag(ReportPeriod.day); Text("本周").tag(ReportPeriod.week); Text("累计").tag(ReportPeriod.all) }.pickerStyle(.segmented).labelsHidden()
            HStack(alignment: .firstTextBaseline) {
                Text("\(period == .day ? "今天" : period == .week ? "本周" : "累计") · 所有应用").font(.system(size: 11)).foregroundStyle(Graphite.muted)
                Spacer()
                Text(DurationText.format(summary.totalSeconds)).font(.system(size: 22, weight: .medium)).monospacedDigit()
            }
            Divider().overlay(Graphite.line)
            HStack { Text("应用使用时间"); Spacer(); Text("全部 \(summary.applications.count) 个 · 按时长") }.font(.system(size: 10)).foregroundStyle(Graphite.muted)
            if summary.applications.isEmpty {
                VStack(spacing: 8) { Text("时间从现在开始记录"); Text("应用产生使用记录后会显示在这里").font(.system(size: 10)) }.font(.system(size: 12)).foregroundStyle(Graphite.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ScrollView { UsageRows(applications: summary.applications, compact: true) } }
            HStack {
                Text("网站计入浏览器用时").font(.system(size: 9)).foregroundStyle(Graphite.muted)
                Spacer()
                Button("查看统计 ↗") { open("statistics") }.buttonStyle(.plain).font(.system(size: 11))
            }
        }.padding(20).foregroundStyle(Graphite.ink).background(GraphiteSurface())
            .task(id: monitor.reportRefreshKey(period: period, anchor: nil)) { await reload() }
    }
    private func reload() async {
        guard period != .day else { return }
        do {
            let report = try await monitor.report(period: period, anchor: Date())
            try Task.checkCancellation()
            periodSummary = report.summary
        } catch is CancellationError { }
        catch { monitor.error = "无法读取概览：\(error.localizedDescription)" }
    }
}
