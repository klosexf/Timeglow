import AppKit
import SwiftUI

@MainActor
final class ReminderWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?

    private var onClose: (() -> Void)?

    func present(_ context: ReminderContext, monitor: MonitoringController, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let panel: NSPanel
        if let existing = window {
            panel = existing
        } else {
            panel = ReminderPanel(contentRect: .init(x: 0, y: 0, width: ReminderStyle.width, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
            panel.title = "Timeglow · 给自己的提醒"
            panel.identifier = NSUserInterfaceItemIdentifier("timeglow.reminder")
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            // A notification click is handled while Notification Center / another
            // app still owns focus. Keep this reminder visible until dismissed,
            // instead of NSPanel's default hide-on-deactivation behavior.
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = false
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.delegate = self
            window = panel
        }
        let view = NSHostingView(rootView: ReminderView(context: context, monitor: monitor, dismiss: { [weak self] in self?.close() }))
        panel.contentView = view
        let fitting = view.fittingSize
        panel.setContentSize(.init(width: ReminderStyle.width, height: fitting.height))
        if !panel.isVisible { panel.center() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        // Release the observer hierarchy rather than refreshing a hidden reminder window.
        window?.contentView = nil
        window = nil
        let completion = onClose
        onClose = nil
        completion?()
    }
}

private final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { close() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 { close(); return }
        if event.type == .leftMouseDown, event.clickCount == 1, let contentView,
           event.locationInWindow.y > contentView.bounds.height - 50,
           event.locationInWindow.x < contentView.bounds.width - 55 {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
private enum ReminderStyle {
    static let width: CGFloat = 470
    static let inset: CGFloat = 30
    static let numberSize: CGFloat = 76
    static let ruleGap: CGFloat = 8
    // The app icon artwork includes a light presentation margin. Crop that margin
    // in the in-app header, then mask the original graphite rounded tile.
    static let headerIconScale: CGFloat = 1.22
    static let headerIconRadius: CGFloat = 6
    static let primary = Color(red: 210 / 255, green: 215 / 255, blue: 225 / 255)
    static let primaryInk = Color(red: 41 / 255, green: 46 / 255, blue: 56 / 255)
    static let appIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSApp.applicationIconImage
    }()
}

private struct ReminderView: View {
    let context: ReminderContext
    let monitor: MonitoringController
    let dismiss: () -> Void

    private var reading: ReminderReading {
        .make(context: context, currentSeconds: monitor.summary.scopedSeconds, currentQuotaMinutes: monitor.preferences.quotaMinutes)
    }

    private var contextText: String {
        let node = "\(context.node)\(context.kind == .percent ? "%" : " 分钟") 节点提醒"
        if context.isTest { return "提醒预览 · \(node)" }
        if reading.isHistorical { return "\(context.day) · 历史提醒记录" }
        let time = context.triggeredAt.map { $0.formatted(.dateTime.hour().minute()) }
        return [time, node].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: ReminderStyle.appIcon).resizable().frame(width: 23, height: 23)
                    .scaleEffect(ReminderStyle.headerIconScale)
                    .clipShape(RoundedRectangle(cornerRadius: ReminderStyle.headerIconRadius, style: .continuous))
                    .accessibilityHidden(true)
                Text("给自己的提醒").font(.system(size: 13, weight: .semibold)).foregroundStyle(Graphite.muted)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 12)).frame(width: 27, height: 27) }
                    .buttonStyle(.plain).foregroundStyle(Graphite.muted).accessibilityLabel("关闭提醒")
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 7)

            VStack(spacing: 0) {
                Text(contextText).font(.system(size: 12)).foregroundStyle(Graphite.muted)
                Text(reading.unit == "%" ? (reading.usesCurrentUsage ? "当前已用每日限额的" : "提醒发出时已用每日限额的") : "这次提醒的累计用时")
                    .font(.system(size: 12)).foregroundStyle(Graphite.muted).padding(.top, 10)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(reading.value)").font(.system(size: ReminderStyle.numberSize, weight: .regular)).tracking(-5)
                    Text(reading.unit).font(.system(size: reading.unit == "%" ? 25 : 22, weight: .regular))
                }
                .monospacedDigit().foregroundStyle(Graphite.ink)
                .frame(height: 86).padding(.top, 5)
                .accessibilityElement(children: .ignore).accessibilityLabel("已用 \(reading.value)\(reading.unit)")

                Rectangle().fill(Graphite.muted.opacity(0.35)).frame(width: 28, height: 1)
                    .padding(.top, ReminderStyle.ruleGap).padding(.bottom, 17)

                ViewThatFits(in: .vertical) {
                    reminderText
                    ScrollView { reminderText }
                }.frame(maxHeight: max(88, min(220, (NSScreen.main?.visibleFrame.height ?? 720) - 315)))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: dismiss) {
                    Text("知道了").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 39)
                        .foregroundStyle(ReminderStyle.primaryInk)
                        .background(ReminderStyle.primary, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("reminder.accept").padding(.top, 20)
            }
            .padding(.horizontal, ReminderStyle.inset).padding(.top, 8).padding(.bottom, 22)
        }
        .frame(width: ReminderStyle.width)
        .background {
            GraphiteSurface(radius: 17)
                .overlay(LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 17))
        }
        .preferredColorScheme(.dark)
    }
    private var reminderText: some View {
        Text(context.message).font(.system(size: 16)).lineSpacing(6)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}
