import AppKit

/// A monochrome adaptation of the approved G-and-orb product mark.
@MainActor
enum TimeglowMenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()

            let center = NSPoint(x: 8.8, y: 8.8)
            let radius: CGFloat = 6
            let endAngle: CGFloat = 342
            let barY = center.y + radius * sin(endAngle * .pi / 180)
            let ring = NSBezierPath()
            ring.lineWidth = 1.8
            ring.lineCapStyle = .round
            ring.lineJoinStyle = .round
            ring.appendArc(withCenter: center, radius: radius,
                           startAngle: 67, endAngle: endAngle, clockwise: false)
            ring.line(to: NSPoint(x: 11.9, y: barY))
            ring.stroke()

            NSBezierPath(ovalIn: NSRect(x: 12.65, y: 11.45, width: 2, height: 2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
