import AppKit

/// Moves windows reliably, and remembers enough to undo moves and to give a snapped window
/// its own size back when it's dragged out of its zone.
final class WindowMover {
    private struct Memory {
        /// Frames before each move, newest last (⌃⌥⌫ steps back through them).
        var history: [CGRect] = []
        /// The frame Panes last snapped the window to.
        var snapped: CGRect?
        /// The window's own frame from before it was snapped.
        var floating: CGRect?
    }

    private var memory: [CGWindowID: Memory] = [:]

    /// Moves a window into `target` (a zone, a span or the whole screen) and remembers it as snapped.
    /// `previous` is the frame to undo to; it defaults to the current frame. `keepFloating` keeps
    /// the remembered own size (a snapped window dragged from one zone into another).
    ///
    /// Swapping: when the window leaves a zone (`vacating`, or a frame Panes snapped it to) and
    /// another window already fills `target`, that window moves into the zone this one left.
    @discardableResult
    func snap(_ window: AXWindow, to target: CGRect, area: CGRect, previous: CGRect? = nil, keepFloating: Bool = false,
              vacating: CGRect? = nil, swap: Bool = true) -> CGRect? {
        guard let id = window.windowID, let current = previous ?? window.frame else { return nil }
        var entry = memory[id] ?? Memory()
        let leaving = swap ? vacating ?? (isSnapped(entry, frame: current) ? current : nil) : nil
        let occupant = leaving.flatMap { $0.isClose(to: target, tolerance: 3) ? nil : WindowList.occupant(of: target, excluding: id) }

        if !keepFloating && !isSnapped(entry, frame: current) { entry.floating = current }
        entry.history.append(current)
        entry.history = entry.history.suffix(20)
        let actual = apply(target, to: window, area: area)
        Log.debug("snap: \(id) \(current.short) → \(actual?.short ?? "failed") (target \(target.short))")
        entry.snapped = actual
        memory[id] = entry

        if let occupant, let leaving {
            Log.debug("swap: \(occupant.windowID.map(String.init) ?? "?") → \(leaving.short)")
            snap(occupant, to: leaving, area: area, swap: false)
        }
        return actual
    }

    /// Puts the window back where it was before the last move.
    func undo(_ window: AXWindow) {
        guard let id = window.windowID, var entry = memory[id], let previous = entry.history.popLast() else {
            NSSound.beep()
            return
        }
        let area = NSScreen.best(for: previous)?.visibleRect ?? previous
        let actual = apply(previous, to: window, area: area)
        // Back to an earlier Panes placement, or (with no history left) to its own frame.
        entry.snapped = entry.history.isEmpty ? nil : actual
        memory[id] = entry
    }

    /// The window's own size, if it's sitting where Panes snapped it.
    func floatingFrame(for id: CGWindowID, current: CGRect) -> CGRect? {
        guard let entry = memory[id], isSnapped(entry, frame: current) else { return nil }
        return entry.floating
    }

    /// Whether Panes put this window where it is now.
    func isPlaced(_ id: CGWindowID, at frame: CGRect) -> Bool {
        memory[id].map { isSnapped($0, frame: frame) } ?? false
    }

    /// The window was resized together with its neighbours: still in its (reshaped) zone.
    func resnap(_ id: CGWindowID, to frame: CGRect) {
        memory[id, default: Memory()].snapped = frame
    }

    /// The window left its zone (dragged out): it's floating from here on.
    func unsnap(_ id: CGWindowID) {
        memory[id]?.snapped = nil
    }

    private func isSnapped(_ entry: Memory, frame: CGRect) -> Bool {
        entry.snapped?.isClose(to: frame, tolerance: 3) ?? false
    }

    /// Sets the frame, working around the usual reasons a move goes wrong.
    @discardableResult
    private func apply(_ target: CGRect, to window: AXWindow, area: CGRect) -> CGRect? {
        // With "enhanced user interface" on (switched on by some assistive apps), apps animate
        // every frame change and often end at the wrong size. Turn it off for the move.
        let app = AXUIElementCreateApplication(window.pid)
        let enhanced: Bool = app.attribute("AXEnhancedUserInterface") ?? false
        if enhanced { app.setBool(false, for: "AXEnhancedUserInterface") }
        defer { if enhanced { app.setBool(true, for: "AXEnhancedUserInterface") } }

        // Size first (so the move isn't limited by the old size hanging off the screen), then
        // position, then size again (moving to another display can change what size fits).
        window.setSize(target.size)
        window.setPosition(target.origin)
        window.setSize(target.size)

        guard var actual = window.frame else { return nil }
        if !actual.isClose(to: target) {
            if abs(actual.width - target.width) > 2 || abs(actual.height - target.height) > 2 {
                // The app has a minimum or stepped size (e.g. Terminal's character grid):
                // centre what it allows in the zone, keeping it on screen.
                let centred = CGRect(x: (target.midX - actual.width / 2).rounded(),
                                     y: (target.midY - actual.height / 2).rounded(),
                                     width: actual.width, height: actual.height)
                window.setPosition(centred.clamped(to: area).origin)
            } else {
                window.setPosition(target.origin)
            }
            actual = window.frame ?? actual
        }
        return actual
    }
}
