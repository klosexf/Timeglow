import SwiftUI
import AppKit
import Combine

@MainActor
final class WorkspaceNavigation: ObservableObject {
    @Published var section = "statistics"
}

struct ReportRefreshKey: Hashable {
    var period: ReportPeriod
    var anchor: Date?
    var revision: UInt64
    var scope: ReportScope
    var today: Date
    var calendar: Calendar
}

enum DurationText {
    static func format(_ seconds: Double) -> String {
        let n = max(0, Int(seconds))
        return n < 60 ? "\(n) 秒" : n < 3600 ? "\(n / 60) 分 \(n % 60) 秒" : "\(n / 3600) 时 \(n % 3600 / 60) 分"
    }
}

struct ContentView: View {
    let monitor: MonitoringController
    @ObservedObject var navigation: WorkspaceNavigation

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceToolbar(monitor: monitor, navigation: navigation)
            if monitor.isPaused {
                HStack(spacing: 7) {
                    Image(systemName: "pause.circle")
                    Text("记录已暂停，历史统计和提醒设置仍可查看。点击右上角“继续记录”恢复。")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11)).foregroundStyle(Graphite.warning.opacity(0.9))
                .padding(.horizontal, WorkspaceStyle.pageInset).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Graphite.warning.opacity(0.035))
                .overlay(alignment: .bottom) { Rectangle().fill(Graphite.warning.opacity(0.1)).frame(height: 1) }
            }
            if let error = monitor.error {
                HStack { Label(error, systemImage: "exclamationmark.triangle"); Spacer(); Button("关闭") { monitor.error = nil } }
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 28).padding(.vertical, 8)
            }
            if navigation.section == "statistics" { StatisticsView(monitor: monitor) }
            else { MonitoringSettingsView(monitor: monitor, permissions: monitor.permissions) }
        }.foregroundStyle(Graphite.ink).background(GraphiteSurface(radius: 0).ignoresSafeArea()).preferredColorScheme(.dark).environment(\.locale, Locale(identifier: "zh_CN"))
    }
}

struct UsageRows: View {
    let applications: [ApplicationUsage]
    var compact = false
    var selectedApps: Set<String> = []
    var websiteRules: [WebsiteRule] = []
    var addApplication: ((ApplicationUsage) -> Void)?
    var addWebsite: ((String) -> Void)?
    var body: some View {
        let largest = applications.map(\.seconds).max() ?? 1
        VStack(spacing: 0) {
            ForEach(applications) { usage in
                if BrowserReader.supported[usage.id] != nil {
                    DisclosureGroup {
                        LazyVStack(spacing: 9) {
                            ForEach(usage.websites) { site in
                                HStack(spacing: 7) {
                                    WebsiteIcon(domain: site.id).frame(width: 14, height: 14)
                                    Text(site.id).lineLimit(1).truncationMode(.middle)
                                    if let addWebsite {
                                        let selected = websiteRules.contains { $0.enabled && DomainRules.matches(host: site.id, rule: $0.domain) }
                                        ScopeAddButton(name: site.id, selected: selected,
                                                       help: selected ? "这个网站已加入统计范围，包含其子域名。可在设置中移除。" : "将 \(site.id) 加入统计范围，包含其子域名；与浏览器用时不会重复计算。") {
                                            addWebsite(site.id)
                                        }
                                    }
                                    Spacer(minLength: 6)
                                    Text(DurationText.format(site.seconds)).monospacedDigit().fixedSize()
                                }
                            }
                            let other = max(0, usage.seconds - usage.websites.reduce(0) { $0 + $1.seconds })
                            if other > 0 { HStack { Text("未细分到网站"); Spacer(); Text(DurationText.format(other)) } }
                        }.font(.system(size: 10)).foregroundStyle(Graphite.muted).padding(.leading, 36).padding(.vertical, 10)
                    } label: { row(usage, largest: largest) }.padding(.vertical, compact ? 8 : 10)
                } else { row(usage, largest: largest).padding(.vertical, compact ? 8 : 10) }
                Divider().opacity(0.4)
            }
        }
    }
    private func row(_ usage: ApplicationUsage, largest: Double) -> some View {
        HStack(spacing: 10) {
            AppIcon(bundleID: usage.id).frame(width: compact ? 25 : 29, height: compact ? 25 : 29)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Text(usage.name).font(.system(size: compact ? 11 : 12)).lineLimit(1)
                    if let addApplication {
                        let selected = selectedApps.contains(usage.id)
                        ScopeAddButton(name: usage.name, selected: selected,
                                       help: selected ? "这个应用已加入统计范围，可在设置中取消。" : BrowserReader.supported[usage.id] != nil ? "将整个 \(usage.name) 加入统计范围，包含其中的所有网站。只统计指定网站时，请使用网址后的加号。" : "将 \(usage.name) 加入统计范围，用时将计入每日合计。") {
                            addApplication(usage)
                        }
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                SmoothQuotaBar(fraction: usage.seconds / max(1, largest), color: Graphite.accent).frame(maxWidth: compact ? 150 : 250)
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            Text(DurationText.format(usage.seconds)).font(.system(size: compact ? 10 : 12)).monospacedDigit().foregroundStyle(Graphite.muted).fixedSize()
        }
    }
}

private struct ScopeAddButton: View {
    let name: String
    let selected: Bool
    let help: String
    let action: () -> Void
    @State private var isHovering = false
    @State private var showsTooltip = false

    var body: some View {
        Group {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Graphite.muted)
                    .accessibilityLabel("\(name)已添加到统计范围")
            } else {
                Button {
                    showsTooltip = false
                    action()
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Graphite.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加\(name)到统计范围")
            }
        }
        .font(.system(size: 12))
        .frame(width: 20, height: 20)
        .fixedSize()
        .accessibilityHint(help)
        .onHover { inside in
            isHovering = inside
            if !inside { showsTooltip = false }
        }
        .task(id: isHovering) {
            guard isHovering else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                showsTooltip = true
            } catch { }
        }
        .background(ScopeTooltip(text: help, isPresented: showsTooltip).frame(width: 20, height: 20))
    }
}

private struct ScopeTooltip: NSViewRepresentable {
    let text: String
    let isPresented: Bool

    func makeNSView(context: Context) -> ScopeTooltipAnchor { ScopeTooltipAnchor() }
    func updateNSView(_ view: ScopeTooltipAnchor, context: Context) {
        view.text = text
        if isPresented { view.present() } else { view.dismiss() }
    }
    static func dismantleNSView(_ view: ScopeTooltipAnchor, coordinator: ()) { view.dismiss() }
}

private final class ScopeTooltipAnchor: NSView {
    var text = "" {
        didSet { if text != oldValue { dismiss() } }
    }
    private var tooltip: ScopeTooltipPanel?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismiss() }
    }

    func dismiss() {
        if let tooltip {
            tooltip.parent?.removeChildWindow(tooltip)
            tooltip.orderOut(nil)
        }
        tooltip = nil
    }

    func present() {
        guard tooltip == nil else { return }
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor, NSEvent.pressedMouseButtons == 0 else { return }
        let mouse = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard visibleRect.contains(mouse) else { return }

        let panel = ScopeTooltipPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        let content = NSHostingView(rootView: Text(text)
            .font(.system(size: 11)).foregroundStyle(Graphite.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(width: 260, alignment: .leading)
            .background(GraphiteSurface(radius: 7)))
        panel.contentView = content
        let size = content.fittingSize
        panel.setContentSize(size)
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? anchor.insetBy(dx: -500, dy: -500)
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        let below = anchor.minY - size.height - 6
        let y = below >= screen.minY + 8 ? below : anchor.maxY + 6
        panel.setFrameOrigin(.init(x: x, y: y))
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        tooltip = panel
    }
}

private final class ScopeTooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct AppIcon: View {
    let bundleID: String
    var body: some View { Image(nsImage: ApplicationIconCache.shared.image(for: bundleID)).resizable().scaledToFit() }
}

@MainActor
final class ApplicationIconCache {
    static let shared = ApplicationIconCache()
    private let cache = NSCache<NSString, NSImage>()
    init() {
        cache.countLimit = 128
        cache.totalCostLimit = 2 * 1024 * 1024
    }

    func image(for bundleID: String) -> NSImage {
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
        // All call sites display at <=29pt: 64px preserves Retina detail.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let thumbnail = NSImage(size: NSSize(width: 32, height: 32))
        thumbnail.addRepresentation(bitmap)
        cache.setObject(thumbnail, forKey: bundleID as NSString, cost: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return thumbnail
    }
}
