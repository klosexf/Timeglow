import AppKit
import SwiftUI

enum BookmarkLayout {
    static let size = NSSize(width: 48, height: 150)
    static let tickCount = 16
}

/// Shared by the live panel and the offline visual check, using the reference's
/// original status artwork rather than a newly drawn approximation.
struct BookmarkFace: View {
    let percent: Double
    let preferences: MonitoringPreferences
    let side: String
    var paused = false
    var recorded = true
    var scoped = true

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: side == "right" ? 24 : 0,
            bottomLeadingRadius: side == "right" ? 24 : 0,
            bottomTrailingRadius: side == "left" ? 24 : 0,
            topTrailingRadius: side == "left" ? 24 : 0
        )
    }

    var body: some View {
        let value = max(0, percent.isFinite ? percent : 0)
        let state = Graphite.state(percent: value, preferences: preferences)
        let status = paused ? "暂停" : !recorded ? "无记录" : !scoped ? "待选" : !preferences.notificationsEnabled ? "提醒关" : state.0
        let orb = value >= Double(preferences.spentPercent) ? "spent" : value >= Double(preferences.warningPercent) ? "warning" : "safe"
        let color = orb == "spent" ? Color(red: 241 / 255, green: 122 / 255, blue: 114 / 255)
            : orb == "warning" ? Color(red: 1, green: 178 / 255, blue: 100 / 255)
            : Color(red: 140 / 255, green: 205 / 255, blue: 154 / 255)
        let filled = Int(ceil(Double(BookmarkLayout.tickCount) * min(1, value / 100)))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !recorded || !scoped { Circle().fill(Graphite.muted.opacity(0.45)).frame(width: 9,height: 9).padding(.horizontal, 3) }
                else if paused { Image(systemName: "pause.fill").font(.system(size: 11)).frame(width: 18, height: 20) }
                else { Image(nsImage: BookmarkOrb.image(for: orb)).resizable().interpolation(.high).frame(width: status.count > 2 ? 16 : 20, height: 20) }
                Text(status).font(.system(size: status.count > 2 ? 9 : 10)).fixedSize()
            }.frame(height: 20)
            VStack(spacing: 2) {
                ForEach((0..<BookmarkLayout.tickCount).reversed(), id: \.self) { index in
                    Rectangle().fill(index < filled ? color : Color.white.opacity(0.165))
                        .frame(width: 15, height: 2)
                }
            }.padding(.top, 7)
            VStack(spacing: 0) {
                Text(!recorded || !scoped ? "—" : value >= 1000 ? ">999%" : UsageText.percent(value))
                    .font(.custom("Menlo-Regular", size: value >= 1000 ? 12 : value >= 100 ? 14 : 16))
                    .fixedSize().frame(height: 20)
                Text(recorded && scoped ? "已用" : "今日").font(.custom("PingFangSC-Regular", size: 9)).frame(height: 12)
            }.padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: BookmarkLayout.size.width, height: BookmarkLayout.size.height)
        .foregroundStyle(Graphite.ink)
        .background {
            GraphiteGlass()
                .overlay(Color(red: 37 / 255, green: 41 / 255, blue: 59 / 255).opacity(0.58))
                .overlay(LinearGradient(colors: [.white.opacity(0.03), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.28), lineWidth: 0.75))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status + "，" + (recorded ? UsageText.percent(value) : "暂无记录"))
    }
}

@MainActor
private enum BookmarkOrb {
    private static var cache: [String: NSImage] = [:]

    static func image(for state: String) -> NSImage {
        if let image = cache[state] { return image }
        let url = Bundle.main.url(forResource: state, withExtension: "webp", subdirectory: "BookmarkOrbs")
            ?? Bundle.main.url(forResource: state, withExtension: "webp")
        guard let url, let sprite = NSImage(contentsOf: url),
              let source = sprite.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let frame = source.cropping(to: .init(x: source.height * 22, y: 0, width: source.height, height: source.height)) else {
            assertionFailure("Missing original bookmark status artwork: \(state)")
            return NSImage(size: .init(width: 20, height: 20))
        }
        // Keep one original frame: restoring the artwork must not introduce a
        // perpetual animation timer into a background usage-monitoring app.
        let image = NSImage(cgImage: frame, size: .init(width: 20, height: 20))
        cache[state] = image
        return image
    }
}
