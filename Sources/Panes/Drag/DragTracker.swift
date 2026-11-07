import AppKit

/// Watches mouse drags system-wide. When one turns out to be moving a window:
/// - holding ⌥ shows the zones and drops the window into the one under the pointer
///   (add ⇧ to span from the zone where ⇧ went down to the current one);
/// - without ⌥, the pointer at a screen edge snaps to the zone on that edge, or fills the
///   screen at the top;
/// - a window Panes snapped gets its own size back as soon as it's dragged out;
/// - Tab, while the zones are showing, switches to the next layout.
final class DragTracker {
    private struct Candidate {
        let windowID: CGWindowID
        let pid: pid_t
        let startBounds: CGRect
        let down: CGPoint
        let since = Date()
    }

    private enum Phase {
        case idle
        /// Button down; we don't know yet whether a window is being dragged.
        case pending(down: CGPoint)
        /// Dragging over a window; waiting to see if it moves with the pointer.
        case watching(Candidate)
        case moving(Candidate)
        /// Not a window move (text selection, a resize, a canvas…): ignore until the button is up.
        case ignored
    }

    private let store: LayoutStore
    private let mover: WindowMover
    private let overlay: ZoneOverlay
    private var phase = Phase.idle
    private var monitor: Any?
    private var location = CGPoint.zero
    private var spanAnchor: Int?
    private var dropTarget: (frame: CGRect, area: CGRect)?
    private var dragEvents = 0
    /// This drag gave a snapped window its own size back.
    private var restoredSize = false
    private var flags: NSEvent.ModifierFlags = []
    /// ⌥Tab / ⌥⇧Tab, claimed only while the zones are showing so Tab never reaches the app.
    private var tabHotKeys: [UInt32] = []

    init(store: LayoutStore, mover: WindowMover, overlay: ZoneOverlay) {
        self.store = store
        self.mover = mover
        self.overlay = overlay
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type != .flagsChanged { location = event.cgEvent?.location ?? Coordinates.mouse }
        if event.type != .leftMouseDown { flags = event.modifierFlags }
        if event.type == .leftMouseDragged { dragEvents += 1 }
        switch (event.type, phase) {
        case (.leftMouseDown, _):
            dragEvents = 0
            claimTab(false) // in case the last drag's mouse-up went unseen
            phase = .pending(down: location)
        case (.leftMouseDragged, .pending(let down)):
            phase = Self.windowUnder(location, down: down).map(Phase.watching) ?? .ignored
        case (.leftMouseDragged, .watching(let candidate)):
            watch(candidate, flags: event.modifierFlags)
        case (.leftMouseDragged, .moving), (.flagsChanged, .moving):
            update(flags: event.modifierFlags)
        case (.leftMouseUp, .moving(let candidate)):
            Log.debug("drag: released after \(dragEvents) drag events")
            claimTab(false)
            drop(candidate)
            phase = .idle
        case (.leftMouseUp, .watching), (.leftMouseUp, .ignored):
            Log.debug("drag: released after \(dragEvents) drag events, no window move")
            phase = .idle
        case (.leftMouseUp, _):
            phase = .idle
        default:
            break
        }
    }

    /// A window drag moves the window with the pointer and keeps its size.
    private func watch(_ candidate: Candidate, flags: NSEvent.ModifierFlags) {
        guard let bounds = Self.bounds(of: candidate.windowID) else {
            Log.debug("drag: window \(candidate.windowID) is gone, ignored")
            phase = .ignored
            return
        }
        let sizeChanged = abs(bounds.width - candidate.startBounds.width) > 1 || abs(bounds.height - candidate.startBounds.height) > 1
        let moved = abs(bounds.minX - candidate.startBounds.minX) >= 1 || abs(bounds.minY - candidate.startBounds.minY) >= 1
        if sizeChanged {
            Log.debug("drag: window \(candidate.windowID) is resizing, ignored")
            phase = .ignored
        } else if moved {
            phase = .moving(candidate)
            Log.debug("drag: moving window \(candidate.windowID) of pid \(candidate.pid) from \(candidate.startBounds.short)")
            spanAnchor = nil
            dropTarget = nil
            restoredSize = restoreSizeIfSnapped(candidate, bounds: bounds)
            update(flags: flags)
        } else if Date().timeIntervalSince(candidate.since) > 0.3
                    && hypot(location.x - candidate.down.x, location.y - candidate.down.y) > 60 {
            // Not straight away: the window server can lag a few events behind a fast drag.
            Log.debug("drag: window \(candidate.windowID) didn't move with the pointer, ignored")
            phase = .ignored
        }
    }

    private func update(flags: NSEvent.ModifierFlags) {
        guard case .moving(let candidate) = phase, let screen = NSScreen.containing(location) else { return }
        let before = dropTarget?.frame
        defer {
            if dropTarget?.frame != before { Log.debug("drag: target \(dropTarget.map { $0.frame.short } ?? "none")") }
        }
        let layout = store.activeLayout(for: screen)
        let geometry = ZoneGeometry(screen: screen, gap: Settings.gap)
        let flags = flags.intersection(.deviceIndependentFlagsMask)

        claimTab(flags.contains(.option))
        if flags.contains(.option), let zone = geometry.zoneIndex(at: location, in: layout) {
            var span = [zone]
            if flags.contains(.shift) {
                let anchor = spanAnchor ?? zone
                spanAnchor = anchor
                span = [anchor, zone]
            } else {
                spanAnchor = nil
            }
            let frame = geometry.frame(spanning: span, in: layout)
            dropTarget = (frame, geometry.area)
            overlay.show(on: screen, zones: geometry.frames(layout), target: frame, below: candidate.windowID)
        } else if Settings.snapAtEdges, let frame = edgeTarget(on: screen, layout: layout, geometry: geometry) {
            spanAnchor = nil
            dropTarget = (frame, geometry.area)
            overlay.show(on: screen, zones: [], target: frame, below: candidate.windowID)
        } else {
            spanAnchor = nil
            dropTarget = nil
            overlay.hide()
        }
    }

    private func drop(_ candidate: Candidate) {
        overlay.hide()
        guard let target = dropTarget else { return }
        dropTarget = nil
        let keepFloating = restoredSize
        // The zone the window was dragged out of, if any: a window already in the drop zone swaps into it.
        let vacating = restoredSize ? candidate.startBounds : NSScreen.best(for: candidate.startBounds).flatMap { screen in
            ZoneGeometry(screen: screen, gap: Settings.gap).placement(of: candidate.startBounds, in: store.activeLayout(for: screen))
        }
        // Let the window server finish the drag first, then place the window.
        DispatchQueue.main.async { [mover] in
            guard let window = AXWindow.find(pid: candidate.pid, windowID: candidate.windowID), window.isMovable else { return }
            let actual = mover.snap(window, to: target.frame, area: target.area, previous: candidate.startBounds,
                                    keepFloating: keepFloating, vacating: vacating)
            Log.debug("drop: window \(candidate.windowID) → \(actual?.short ?? "failed") (target \(target.frame.short))")
        }
    }

    private func claimTab(_ claim: Bool) {
        if claim, tabHotKeys.isEmpty {
            tabHotKeys = [HotKeys.Shortcut.dragTab, .dragShiftTab].compactMap {
                HotKeys.shared.register($0, reportFailure: false) { [weak self] in self?.nextLayout() }
            }
        } else if !claim, !tabHotKeys.isEmpty {
            tabHotKeys.forEach(HotKeys.shared.unregister)
            tabHotKeys = []
        }
    }

    /// Tab during a ⌥-drag: the next layout on this display, with the zones and target redrawn.
    private func nextLayout() {
        guard case .moving = phase, let screen = NSScreen.containing(location) else { return }
        let layout = store.cycleLayout(on: screen)
        Log.debug("drag: tab → \(layout.name)")
        spanAnchor = nil
        update(flags: flags)
    }

    /// The pointer pressed against a screen edge (one with no other display beyond it).
    private func edgeTarget(on screen: NSScreen, layout: Layout, geometry: ZoneGeometry) -> CGRect? {
        let s = screen.rect
        let reach: CGFloat = 4
        func open(_ beyond: CGPoint) -> Bool { !NSScreen.screens.contains { $0.rect.contains(beyond) } }
        let left = location.x <= s.minX + reach && open(CGPoint(x: s.minX - 2, y: location.y))
        let right = location.x >= s.maxX - 1 - reach && open(CGPoint(x: s.maxX + 2, y: location.y))
        let top = location.y <= s.minY + reach && open(CGPoint(x: location.x, y: s.minY - 2))

        if left || right {
            // The zone on that side at the pointer's height (top or bottom zone near a corner).
            let frames = geometry.frames(layout)
            let side = layout.zones.indices.filter { left ? layout.zones[$0].x < 0.001 : layout.zones[$0].x + layout.zones[$0].w > 0.999 }
            let best = side.min { abs(frames[$0].midY - location.y) - frames[$0].height / 2 < abs(frames[$1].midY - location.y) - frames[$1].height / 2 }
            return best.map { frames[$0] }
        }
        return top ? geometry.fill : nil
    }

    /// Dragging a snapped window out of its zone gives it its own size back, keeping the
    /// pointer at the same place along the title bar.
    private func restoreSizeIfSnapped(_ candidate: Candidate, bounds: CGRect) -> Bool {
        guard let floating = mover.floatingFrame(for: candidate.windowID, current: candidate.startBounds),
              let window = AXWindow.find(pid: candidate.pid, windowID: candidate.windowID) else { return false }
        mover.unsnap(candidate.windowID)
        let along = (location.x - bounds.minX) / max(bounds.width, 1)
        let origin = CGPoint(x: (location.x - along * floating.width).rounded(), y: bounds.minY)
        window.setSize(floating.size)
        window.setPosition(origin)
        Log.debug("drag: restored own size \(floating.size) at \(origin)")
        return true
    }

    // MARK: Window server queries (no Accessibility round trip to the app)

    private static func windowUnder(_ point: CGPoint, down: CGPoint) -> Candidate? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        // Front to back: the first app window under the pointer is the one being dragged, if any.
        // Skip the system's own overlays (Stage Manager, macOS tiling previews, the Dock): they
        // belong to background processes, not regular apps.
        let hit = list.first { info in
            guard let bounds = bounds(in: info), bounds.contains(point),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid() else { return false }
            return NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        }
        guard let info = hit, info[kCGWindowLayer as String] as? Int == 0,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let bounds = bounds(in: info) else {
            Log.debug("drag: no app window under \(point) (\(hit?[kCGWindowOwnerName as String] as? String ?? "nothing"))")
            return nil
        }
        Log.debug("drag: watching window \(id) of \(info[kCGWindowOwnerName as String] as? String ?? "?") at \(bounds.short)")
        return Candidate(windowID: id, pid: pid, startBounds: bounds, down: down)
    }

    private static func bounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let info = list.first else { return nil }
        return bounds(in: info)
    }

    private static func bounds(in info: [String: Any]) -> CGRect? {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }
}
