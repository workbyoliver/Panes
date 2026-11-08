import AppKit

enum Direction {
    case left, right, up, down
}

/// Keyboard and menu moves for the focused window. They all follow the active layout of the
/// display the window is on.
final class Commands {
    private let store: LayoutStore
    private let mover: WindowMover
    private let overlay: ZoneOverlay

    init(store: LayoutStore, mover: WindowMover, overlay: ZoneOverlay) {
        self.store = store
        self.mover = mover
        self.overlay = overlay
    }

    private struct Context {
        let window: AXWindow
        let frame: CGRect
        let screen: NSScreen
        let layout: Layout
        let geometry: ZoneGeometry
        var frames: [CGRect] { geometry.frames(layout) }
    }

    /// `target` is a window picked earlier (the panel's); otherwise the focused window.
    private func context(for target: AXWindow? = nil) -> Context? {
        guard AXIsProcessTrusted() else {
            Permissions.promptForAccessibility()
            return nil
        }
        guard let window = target ?? AXWindow.focused(), window.isMovable, let frame = window.frame,
              let screen = NSScreen.best(for: frame) else {
            Log.debug("command: no movable focused window (front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"))")
            NSSound.beep()
            return nil
        }
        return Context(window: window, frame: frame, screen: screen, layout: store.activeLayout(for: screen),
                       geometry: ZoneGeometry(screen: screen, gap: Settings.gap))
    }

    /// The zone the window is leaving, if it's in one: a window already in the zone it moves
    /// to swaps into it.
    private func vacating(_ c: Context) -> CGRect? {
        c.geometry.placement(of: c.frame, in: c.layout)
    }

    /// ⌃⌥1–9
    func moveToZone(_ number: Int, window: AXWindow? = nil) {
        guard let c = context(for: window) else { return }
        guard c.layout.zones.indices.contains(number - 1) else { NSSound.beep(); return }
        mover.snap(c.window, to: c.frames[number - 1], area: c.geometry.area, vacating: vacating(c))
    }

    /// ⌃⌥ arrows: the next zone in that direction. Left and right wrap around the screen.
    func move(_ direction: Direction) {
        guard let c = context() else { return }
        guard let index = Self.neighbour(of: c.frame, in: c.frames, direction, wrap: direction == .left || direction == .right) else { return }
        mover.snap(c.window, to: c.frames[index], area: c.geometry.area, vacating: vacating(c))
    }

    /// ⌃⌥⇧ arrows: grow the window across the next zone in that direction.
    func grow(_ direction: Direction) {
        guard let c = context() else { return }
        let frames = c.frames
        // The zones the window covers now: mostly-inside zones, or else the zone at its centre.
        var covered = frames.indices.filter { frames[$0].intersection(c.frame).area > frames[$0].area * 0.6 }
        if covered.isEmpty, let zone = c.geometry.zoneIndex(at: c.frame.center, in: c.layout) { covered = [zone] }
        let current = covered.map { frames[$0] }.reduce(CGRect.null) { $0.union($1) }
        guard !current.isNull,
              let next = Self.neighbour(of: current, in: frames, direction, wrap: false, excluding: Set(covered)) else {
            NSSound.beep()
            return
        }
        // Growing over a neighbour never swaps it away.
        mover.snap(c.window, to: c.geometry.frame(spanning: covered + [next], in: c.layout), area: c.geometry.area, swap: false)
    }

    /// ⌃⌥↩
    func fill(window: AXWindow? = nil) {
        guard let c = context(for: window) else { return }
        mover.snap(c.window, to: c.geometry.fill, area: c.geometry.area, vacating: vacating(c))
    }

    /// ⌃⌥C: centred, 80% of the screen's usable width and height.
    func centre(window: AXWindow? = nil) {
        guard let c = context(for: window) else { return }
        let area = c.geometry.area
        let size = CGSize(width: (area.width * 0.8).rounded(), height: (area.height * 0.8).rounded())
        let centred = CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                             width: size.width, height: size.height)
        // Snapped like a zone, so dragging it away gives the window its own size back.
        mover.snap(c.window, to: centred, area: area, swap: false)
    }

    /// ⌃⌥⌫
    func undo(window: AXWindow? = nil) {
        guard let c = context(for: window) else { return }
        mover.undo(c.window)
    }

    /// ⌃⌥L: the next layout on the focused window's display (or the pointer's), shown briefly.
    func nextLayout() {
        guard let screen = currentScreen else { return }
        let layout = store.cycleLayout(on: screen)
        showLayout(layout, on: screen)
    }

    /// Makes a layout active on a display and flashes its zones (layout shortcuts).
    func select(_ layout: Layout, on screen: NSScreen) {
        store.setActive(layout, for: screen)
        showLayout(layout, on: screen)
    }

    /// The display you're using: the focused window's, or the pointer's.
    var currentScreen: NSScreen? {
        let frame = AXIsProcessTrusted() ? AXWindow.focused()?.frame : nil
        return frame.flatMap(NSScreen.best(for:)) ?? NSScreen.containing(Coordinates.mouse)
    }

    func showLayout(_ layout: Layout, on screen: NSScreen) {
        overlay.flash(on: screen, zones: ZoneGeometry(screen: screen, gap: Settings.gap).frames(layout))
    }

    /// The nearest zone whose centre lies in `direction` from `rect`'s centre, preferring zones
    /// in the same row (or column). With `wrap`, falls back to the far side of the screen.
    static func neighbour(of rect: CGRect, in frames: [CGRect], _ direction: Direction, wrap: Bool, excluding: Set<Int> = []) -> Int? {
        let horizontal = direction == .left || direction == .right
        let sign: CGFloat = direction == .right || direction == .down ? 1 : -1
        func along(_ r: CGRect) -> CGFloat { horizontal ? r.midX : r.midY }
        func overlap(_ r: CGRect) -> Bool {
            horizontal ? min(r.maxY, rect.maxY) - max(r.minY, rect.minY) > 1 : min(r.maxX, rect.maxX) - max(r.minX, rect.minX) > 1
        }
        func across(_ r: CGRect) -> CGFloat { horizontal ? abs(r.midY - rect.midY) : abs(r.midX - rect.midX) }

        let candidates = frames.indices.filter { !excluding.contains($0) }
        let ahead = candidates.filter { (along(frames[$0]) - along(rect)) * sign > 2 }
        let pick = { (pool: [Int], key: (Int) -> CGFloat) -> Int? in
            let sameLine = pool.filter { overlap(frames[$0]) }
            return (sameLine.isEmpty ? pool : sameLine).min { key($0) < key($1) }
        }
        if let index = pick(ahead, { abs(along(frames[$0]) - along(rect)) + across(frames[$0]) * 2 }) { return index }
        guard wrap else { return nil }
        // Wrap: the zone furthest the other way, in the same row.
        return pick(candidates, { along(frames[$0]) * sign + across(frames[$0]) * 2 })
    }
}
