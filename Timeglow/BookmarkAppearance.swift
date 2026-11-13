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
        let orb = value >= Double(preferences.spentPercent) ? "spent" : value >= Double(preferences.warningPercent) ? "warning" : "safe"
        let color = orb == "spent" ? Color(red: 241 / 255, green: 122 / 255, blue: 114 / 255)
            : orb == "warning" ? Color(red: 1, green: 178 / 255, blue: 100 / 255)
            : Color(red: 140 / 255, green: 205 / 255, blue: 154 / 255)
        let filled = Int(ceil(Double(BookmarkLayout.tickCount) * min(1, floor(value) / 100)))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(nsImage: BookmarkOrb.image(for: orb))
                    .resizable().interpolation(.high).frame(width: 20, height: 20)
                Text(state.0).font(.custom("PingFangSC-Regular", size: 10)).fixedSize()
            }.frame(height: 20)
            VStack(spacing: 2) {
                ForEach((0..<BookmarkLayout.tickCount).reversed(), id: \.self) { index in
                    Rectangle().fill(index < filled ? color : Color.white.opacity(0.165))
                        .frame(width: 15, height: 2)
                }
            }.padding(.top, 7)
            VStack(spacing: 0) {
                Text("\(Int(value))%")
                    .font(.custom("Menlo-Regular", size: 16))
                    .fixedSize().frame(height: 20)
                Text("已用").font(.custom("PingFangSC-Regular", size: 9)).frame(height: 12)
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
        .accessibilityLabel("\(state.0)，所选应用和网站今天合计已用每日限额的 \(Int(value))%")
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
