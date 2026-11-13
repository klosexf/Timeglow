import SwiftUI
import AppKit

enum Graphite {
    static let ink = Color(red: 0.93, green: 0.94, blue: 0.95)
    static let muted = Color(red: 0.68, green: 0.70, blue: 0.74)
    static let line = Color.white.opacity(0.10)
    static let accent = Color(red: 0.77, green: 0.79, blue: 0.84)
    static let safe = Color(red: 0.55, green: 0.80, blue: 0.60)
    static let warning = Color(red: 1, green: 0.70, blue: 0.39)
    static let spent = Color(red: 0.95, green: 0.48, blue: 0.45)

    static func categoryColor(_ category: String) -> Color {
        switch category {
        case "创作与开发": return accent
        case "网页浏览": return Color(red: 0.55, green: 0.69, blue: 0.77)
        case "沟通": return Color(red: 0.81, green: 0.71, blue: 0.59)
        case "影音": return Color(red: 0.69, green: 0.61, blue: 0.76)
        default: return Color(red: 0.44, green: 0.47, blue: 0.53)
        }
    }

    static func state(percent: Double, preferences: MonitoringPreferences) -> (String, Color) {
        if percent >= Double(preferences.spentPercent) { return ("用尽", spent) }
        if percent >= Double(preferences.warningPercent) { return ("留意", warning) }
        return ("充足", safe)
    }
}

struct GraphiteGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct GraphiteSurface: View {
    var radius: CGFloat = 16
    var body: some View {
        GraphiteGlass()
            .overlay(Color(red: 0.08, green: 0.085, blue: 0.10).opacity(0.80))
            .overlay(LinearGradient(colors: [.white.opacity(0.055), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

struct SmoothQuotaBar: View {
    var fraction: Double
    var color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule().fill(color).frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }.frame(height: 4)
    }
}

extension View {
    func graphiteCard() -> some View {
        self.padding(18)
            .background(.white.opacity(0.028), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Graphite.line, lineWidth: 1))
    }
}
