import AppKit

/// Accessibility and CGWindowList use a top-left origin at the primary display's top-left
/// corner; AppKit uses a bottom-left origin. Panes works in the top-left space throughout
/// and converts AppKit rects at the edges. The flip is its own inverse.
enum Coordinates {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func flip(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// The pointer, top-left coordinates.
    static var mouse: CGPoint { flip(NSEvent.mouseLocation) }
}

extension NSScreen {
    /// The whole display, top-left coordinates.
    var rect: CGRect { Coordinates.flip(frame) }

    /// The usable area (without the menu bar and Dock), top-left coordinates.
    var visibleRect: CGRect { Coordinates.flip(visibleFrame) }

    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    /// Stable across reboots and rearrangements, for per-display settings.
    var settingsKey: String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return localizedName
    }

    /// The display under a top-left point, or the nearest one.
    static func containing(_ point: CGPoint) -> NSScreen? {
        if let hit = screens.first(where: { $0.rect.contains(point) }) { return hit }
        return screens.min { $0.rect.distance(to: point) < $1.rect.distance(to: point) }
    }

    /// The display showing most of a top-left rect.
    static func best(for rect: CGRect) -> NSScreen? {
        let scored = screens.map { ($0, $0.rect.intersection(rect).area) }
        if let (screen, area) = scored.max(by: { $0.1 < $1.1 }), area > 0 { return screen }
        return containing(CGPoint(x: rect.midX, y: rect.midY))
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func distance(to point: CGPoint) -> CGFloat {
        let dx = Swift.max(minX - point.x, 0, point.x - maxX)
        let dy = Swift.max(minY - point.y, 0, point.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    /// Moves the rect (without resizing) so it lies inside `bounds` where it can.
    func clamped(to bounds: CGRect) -> CGRect {
        var r = self
        r.origin.x = Swift.min(Swift.max(r.minX, bounds.minX), Swift.max(bounds.maxX - r.width, bounds.minX))
        r.origin.y = Swift.min(Swift.max(r.minY, bounds.minY), Swift.max(bounds.maxY - r.height, bounds.minY))
        return r
    }
}
