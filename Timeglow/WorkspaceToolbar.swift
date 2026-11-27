import AppKit
import SwiftUI

enum WorkspaceStyle {
    static let toolbarHeight: CGFloat = 55
    static let pageInset: CGFloat = 28
    static let cardGap: CGFloat = 14
}

// This workspace is an AppKit-owned NSWindow. Handle titlebar background
// dragging at the window boundary, before the hosting view's hit testing.
final class WorkspaceWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 1,
           let contentView {
            let location = event.locationInWindow
            let distanceFromTop = contentView.frame.maxY - location.y
            let width = contentView.bounds.width
            let outsideControls = location.x > 90
                && abs(location.x - width / 2) > 104
                && location.x < width - 196
            if distanceFromTop > 3 && distanceFromTop < WorkspaceStyle.toolbarHeight && outsideControls {
                performDrag(with: event)
                return
            }
        }
        super.sendEvent(event)
    }
}

struct WorkspaceToolbar: View {
    let monitor: MonitoringController
    @ObservedObject var navigation: WorkspaceNavigation

    private var status: String {
        if monitor.isPaused { return "已暂停" }
        if monitor.state == "正在记录" { return "记录中" }
        return monitor.state.contains("闲置") ? "闲置中" : "已挂起"
    }
    private var statusColor: Color {
        monitor.isPaused ? Graphite.warning : monitor.state == "正在记录" ? Graphite.safe : Graphite.muted
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                WorkspaceWindowControls().frame(width: 54, height: WorkspaceStyle.toolbarHeight)
                HStack(spacing: 8) {
                    Text("Timeglow").font(.system(size: 15, weight: .semibold))
                    if monitor.isVerification {
                        Text("开发版").font(.system(size: 9)).foregroundStyle(Graphite.muted)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Graphite.line, lineWidth: 1))
                    }
                }.padding(.leading, 16).allowsHitTesting(false)
                Spacer(minLength: 0)
                HStack(spacing: 13) {
                    HStack(spacing: 7) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(status).font(.system(size: 11))
                    }
                    .foregroundStyle(Graphite.muted)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("记录状态：\(monitor.state)")
                    .help(monitor.state)
                    Button(action: monitor.togglePause) {
                        HStack(spacing: 6) {
                            Image(systemName: monitor.isPaused ? "play.fill" : "pause")
                                .font(.system(size: 11, weight: .medium))
                            Text(monitor.isPaused ? "继续记录" : "暂停记录")
                        }.frame(width: 74)
                    }
                    .buttonStyle(WorkspaceActionButtonStyle(emphasized: monitor.isPaused))
                    .accessibilityIdentifier("workspace.record-toggle")
                    .help(monitor.isPaused ? "恢复自动记录前台应用与已授权网站的用时。" : "暂停自动记录，已保存的统计仍可查看。")
                }
            }
            HStack(spacing: 2) {
                section("statistics", title: "使用统计", icon: "chart.bar")
                section("settings", title: "设置", icon: "gearshape")
            }
            .padding(3)
            .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.025), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("主导航")
        }
        .padding(.horizontal, 20)
        .frame(height: WorkspaceStyle.toolbarHeight)
        .background(.white.opacity(0.018))
        .overlay(alignment: .bottom) { Rectangle().fill(Graphite.line).frame(height: 1) }
        .accessibilityIdentifier("workspace.toolbar")
    }

    private func section(_ id: String, title: String, icon: String) -> some View {
        let selected = navigation.section == id
        return Button { navigation.section = id } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13))
                Text(title).font(.system(size: 12))
            }.frame(width: 90, height: 28)
        }
        .buttonStyle(WorkspaceSelectionButtonStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("workspace.\(id)")
    }
}

struct PeriodControl: View {
    @Binding var period: ReportPeriod
    let overview: Bool
    @FocusState private var focus: ReportPeriod?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ReportPeriod.allCases) { item in
                Button {
                    period = item
                } label: {
                    Text(overview && item != .all ? (item == .week ? "本周" : "今日") : item.title)
                        .font(.system(size: 12)).frame(maxWidth: .infinity).frame(height: 24)
                }.buttonStyle(WorkspaceSelectionButtonStyle(selected: item == period))
                    .focused($focus, equals: item)
                    .accessibilityAddTraits(item == period ? .isSelected : [])
            }
        }.padding(2).background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Graphite.line, lineWidth: 1))
            .accessibilityElement(children: .contain).accessibilityLabel(overview ? "应用排行的统计周期" : "统计周期")
            .onMoveCommand { direction in
                let items = ReportPeriod.allCases
                guard focus != nil, let index = items.firstIndex(of: period), direction == .left || direction == .right else { return }
                period = items[(index + (direction == .right ? 1 : items.count - 1)) % items.count]
                focus = period
            }
    }
}

struct WorkspaceActionButtonStyle: ButtonStyle {
    var emphasized = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundStyle(emphasized ? Graphite.warning : Graphite.ink.opacity(0.86))
            .padding(.horizontal, 10).frame(height: 30)
            .background((emphasized ? Graphite.warning : Color.white).opacity(configuration.isPressed ? 0.12 : hovering ? 0.075 : 0.028), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(emphasized ? Graphite.warning.opacity(0.24) : .white.opacity(hovering ? 0.15 : 0.09), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

struct WorkspaceSelectionButtonStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Graphite.ink : Graphite.muted)
            .background(.white.opacity(configuration.isPressed ? 0.13 : selected ? 0.16 : hovering ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(selected ? 0.035 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}

// Use AppKit's standard button factory so the system frame does not move
// the toolbar controls back into its original titlebar during a resize.
private struct WorkspaceWindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceControlsView { WorkspaceControlsView() }
    func updateNSView(_ view: WorkspaceControlsView, context: Context) { view.installControls() }
    static func dismantleNSView(_ view: WorkspaceControlsView, coordinator: ()) { view.restoreControls() }
}

private final class WorkspaceControlsView: NSView {
    private let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private var buttons: [NSButton] = []
    private weak var ownerWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private var controlsUpdateScheduled = false
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        guard let window else { return }
        ownerWindow = window
        for name in [NSWindow.didUpdateNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleControlsUpdate() }
            })
        }
        installControls()
    }

    private func scheduleControlsUpdate() {
        guard !controlsUpdateScheduled else { return }
        controlsUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.controlsUpdateScheduled = false
            self.installControls()
        }
    }

    func installControls() {
        guard let window else { return }
        for kind in kinds { window.standardWindowButton(kind)?.isHidden = true }
        if buttons.isEmpty {
            for kind in kinds {
                guard let button = NSWindow.standardWindowButton(kind, for: window.styleMask) else { continue }
                button.target = self
                switch kind {
                case .closeButton: button.action = #selector(closeWindow(_:))
                case .miniaturizeButton: button.action = #selector(miniaturizeWindow(_:))
                default: button.action = #selector(zoomWindow(_:))
                }
                buttons.append(button)
                addSubview(button)
            }
        }
        positionControls()
    }

    override func layout() { super.layout(); positionControls() }

    private func positionControls() {
        for (index, button) in buttons.enumerated() {
            let origin = NSPoint(x: CGFloat(index) * 20, y: (bounds.height - button.frame.height) / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    @objc private func closeWindow(_ sender: Any?) { window?.performClose(sender) }
    @objc private func miniaturizeWindow(_ sender: Any?) { window?.performMiniaturize(sender) }
    @objc private func zoomWindow(_ sender: Any?) {
        if NSEvent.modifierFlags.contains(.option) { window?.performZoom(sender) }
        else { window?.toggleFullScreen(sender) }
    }

    func restoreControls() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        for kind in kinds { ownerWindow?.standardWindowButton(kind)?.isHidden = false }
        ownerWindow = nil
    }
}
