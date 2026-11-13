import AppKit
import SwiftUI

@MainActor
final class ReminderWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?

    func present(_ context: ReminderContext, monitor: MonitoringController) {
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
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        // Release the observer hierarchy rather than refreshing a hidden reminder window.
        window?.contentView = nil
        window = nil
    }
}

private final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
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
    static let width: CGFloat = 540
    static let inset: CGFloat = 39
    static let numberSize: CGFloat = 89
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
        if context.isTest { return "测试提醒 · \(node)" }
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
                Text("Timeglow / 给自己的提醒").font(.system(size: 11)).foregroundStyle(Graphite.muted)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 12)).frame(width: 27, height: 27) }
                    .buttonStyle(.plain).foregroundStyle(Graphite.muted).accessibilityLabel("关闭提醒")
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 7)

            VStack(spacing: 0) {
                Text(contextText).font(.system(size: 10)).foregroundStyle(Graphite.muted)
                Text(reading.unit == "%" ? (reading.usesCurrentUsage ? "当前已用每日限额的" : "提醒发出时已用每日限额的") : "这次提醒的累计用时")
                    .font(.system(size: 12)).foregroundStyle(Graphite.muted).padding(.top, 24)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(reading.value)").font(.system(size: ReminderStyle.numberSize, weight: .regular)).tracking(-5)
                    Text(reading.unit).font(.system(size: reading.unit == "%" ? 31 : 22, weight: .regular))
                }
                .monospacedDigit().foregroundStyle(Graphite.ink)
                .frame(height: 100).padding(.top, 5)
                .accessibilityElement(children: .ignore).accessibilityLabel("已用 \(reading.value)\(reading.unit)")

                if reading.usesCurrentUsage && context.kind == .percent && context.node != reading.value {
                    Text("提醒在 \(context.node)% 时发出")
                        .font(.system(size: 10)).foregroundStyle(Graphite.muted).padding(.top, 8)
                }

                Rectangle().fill(Graphite.muted.opacity(0.35)).frame(width: 28, height: 1)
                    .padding(.top, ReminderStyle.ruleGap).padding(.bottom, 17)

                Text(context.message)
                    .font(.system(size: 17)).lineSpacing(10)
                    .foregroundStyle(Graphite.ink).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                VStack(spacing: 7) {
                    Button(action: dismiss) {
                        HStack(spacing: 9) {
                            Text("💪").font(.system(size: 21))
                            Text("我可以做到").font(.system(size: 14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .foregroundStyle(ReminderStyle.primaryInk)
                        .background(ReminderStyle.primary, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.defaultAction)
                    .accessibilityLabel("我可以做到").accessibilityIdentifier("reminder.accept")
                    Button("我不听", action: dismiss)
                        .font(.system(size: 12)).foregroundStyle(Graphite.muted)
                        .padding(.horizontal, 17).frame(minHeight: 32)
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("reminder.dismiss")
                }.padding(.top, 27)
            }
            .padding(.horizontal, ReminderStyle.inset).padding(.top, 17).padding(.bottom, 28)
        }
        .frame(width: ReminderStyle.width)
        .background {
            GraphiteSurface(radius: 17)
                .overlay(LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 17))
        }
        .preferredColorScheme(.dark)
    }
}
