import AppKit

/// Brings back each Stage Manager stage's layout when you switch to it (and each Space's,
/// which works the same way).
///
/// macOS has no stage IDs, but only the current stage's windows are on screen. So a stage is
/// recognised by its windows: picking a layout remembers it for every app window on that
/// display, and when other windows come forward, the layout most of them were remembered with
/// wins. Window IDs don't survive an app or Mac restart, so each app's last layout is the
/// fallback for windows Panes hasn't seen.
final class StageMemory {
    struct Visible: Equatable {
        let id: CGWindowID
        let app: String
    }

    private let store: LayoutStore
    private var byWindow: [CGWindowID: String] = [:]
    private var byApp: [String: String]
    /// The windows on each display at the last look.
    private var lastSeen: [String: Set<CGWindowID>] = [:]
    private var pending: [DispatchWorkItem] = []
    private let appKey = "appLayouts"

    init(store: LayoutStore) {
        self.store = store
        byApp = UserDefaults.standard.dictionary(forKey: appKey) as? [String: String] ?? [:]
    }

    func start() {
        // A stage switch activates an app; Spaces and hiding apps also change what's on screen.
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleCheck() }
            }
        }
        for screen in NSScreen.screens {
            lastSeen[screen.settingsKey] = Set(Self.visibleWindows(on: screen).map(\.id))
        }
    }

    /// You picked a layout: remember it for the windows on that display and their apps.
    func picked(_ layout: Layout, on screen: NSScreen) {
        let visible = Self.visibleWindows(on: screen)
        for window in visible {
            byWindow[window.id] = layout.id
            byApp[window.app] = layout.id
        }
        UserDefaults.standard.set(byApp, forKey: appKey)
        lastSeen[screen.settingsKey] = Set(visible.map(\.id))
        Log.debug("stage: \(layout.name) remembered for \(visible.count) windows")
    }

    private func scheduleCheck() {
        pending.forEach { $0.cancel() }
        // Stage Manager animates the switch: look once it has settled, and again a little later.
        pending = [0.4, 1.2].map { delay in
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.check() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func check() {
        guard Settings.rememberLayoutPerStage else { return }
        for screen in NSScreen.screens {
            let key = screen.settingsKey
            let visible = Self.visibleWindows(on: screen)
            let ids = Set(visible.map(\.id))
            let previous = lastSeen[key] ?? []
            guard ids != previous else { continue }
            lastSeen[key] = ids

            // The windows you were looking at keep the layout they were shown with, even if you
            // never picked one for them.
            let active = store.activeLayout(for: screen)
            for id in previous where byWindow[id] == nil { byWindow[id] = active.id }

            let apps = Set(visible.map { $0.app.split(separator: ".").last.map(String.init) ?? $0.app }).sorted()
            let known = visible.filter { byWindow[$0.id] != nil }.count
            guard let id = Self.decide(visible: visible, byWindow: byWindow, byApp: byApp, current: active.id),
                  id != active.id, let layout = store.layouts(for: screen).first(where: { $0.id == id }) else {
                Log.debug("stage: now \(apps) (\(known)/\(visible.count) windows remembered), keeping \(active.name)")
                continue
            }
            Log.debug("stage: now \(apps) (\(known)/\(visible.count) windows remembered) → \(layout.name)")
            store.setActive(layout, for: screen, picked: false)
        }
        if byWindow.count > 1000 { prune() }
    }

    /// The layout most of these windows were remembered with (a tie keeps the current layout,
    /// else goes to the frontmost window's). With no window remembered, their apps' layouts.
    static func decide(visible: [Visible], byWindow: [CGWindowID: String], byApp: [String: String], current: String) -> String? {
        var votes = visible.compactMap { byWindow[$0.id] }
        if votes.isEmpty { votes = visible.compactMap { byApp[$0.app] } }
        let counts = Dictionary(votes.map { ($0, 1) }, uniquingKeysWith: +)
        guard let best = counts.values.max() else { return nil }
        if counts[current] == best { return current }
        return votes.first { counts[$0] == best }
    }

    /// Forgets windows that have closed.
    private func prune() {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let alive = Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        byWindow = byWindow.filter { alive.contains($0.key) }
    }

    /// App windows on screen on this display, front to back. Under Stage Manager that's the
    /// current stage: other stages' windows aren't on screen.
    static func visibleWindows(on screen: NSScreen) -> [Visible] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let display = screen.rect
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width >= 120, bounds.height >= 80, // not palettes or popovers
                  bounds.intersection(display).area >= bounds.area * 0.5,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bundle = app.bundleIdentifier else { return nil }
            return Visible(id: id, app: bundle)
        }
    }
}
