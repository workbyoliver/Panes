import AppKit

/// A saved arrangement of a stage: which apps' windows were where, in which layout.
struct Workspace: Codable, Identifiable, Hashable {
    struct Entry: Codable, Hashable {
        var bundleID: String
        var appName: String
        /// Tells apart several windows of one app.
        var title: String?
        /// The zone it sat in, if any (an index into the workspace's layout).
        var zone: Int?
        /// Where it was as fractions of the display's usable area (used outside a zone).
        var unit: CGRect
    }

    var id: String
    var name: String
    var layoutID: String
    /// The display it was saved on (`NSScreen.settingsKey`).
    var display: String
    var entries: [Entry]
}

/// Saves the stage you're on as a workspace, and brings a workspace back: its layout, and its
/// apps' windows into their zones. Stage Manager lets no app group windows into a stage, so
/// restoring arranges the windows already in this stage; apps that aren't running are opened
/// (Stage Manager gives them a stage of their own) and placed once their window appears.
final class Workspaces {
    private(set) var all: [Workspace] = []
    var onChange: (() -> Void)?

    private let store: LayoutStore
    private let mover: WindowMover
    private let commands: Commands
    private let defaultsKey = "workspaces"

    init(store: LayoutStore, mover: WindowMover, commands: Commands) {
        self.store = store
        self.mover = mover
        self.commands = commands
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([Workspace].self, from: data) {
            all = saved
        }
    }

    /// "Workspace 1", or the next free number.
    func suggestedName() -> String {
        var number = all.count + 1
        while all.contains(where: { $0.name == "Workspace \(number)" }) { number += 1 }
        return "Workspace \(number)"
    }

    /// The windows on this display (the current stage), front to back.
    @discardableResult
    func saveStage(named name: String, on screen: NSScreen) -> Workspace? {
        let geometry = ZoneGeometry(screen: screen, gap: Settings.gap)
        let layout = store.activeLayout(for: screen)
        let frames = geometry.frames(layout)
        let a = geometry.area
        let entries = WindowList.appWindows(on: screen).map { window in
            Workspace.Entry(bundleID: window.bundleID, appName: window.appName,
                            title: AXWindow.find(pid: window.pid, windowID: window.id)?.title,
                            zone: frames.firstIndex { $0.isClose(to: window.bounds, tolerance: 3) },
                            unit: CGRect(x: (window.bounds.minX - a.minX) / a.width, y: (window.bounds.minY - a.minY) / a.height,
                                         width: window.bounds.width / a.width, height: window.bounds.height / a.height))
        }
        guard !entries.isEmpty else { NSSound.beep(); return nil }
        let workspace = Workspace(id: UUID().uuidString, name: name, layoutID: layout.id, display: screen.settingsKey, entries: entries)
        all.append(workspace)
        persist()
        Log.debug("workspace: saved \(name) with \(entries.count) window(s)")
        return workspace
    }

    func delete(_ workspace: Workspace) {
        all.removeAll { $0.id == workspace.id }
        persist()
    }

    func restore(_ workspace: Workspace, fallback screen: NSScreen) {
        let screen = NSScreen.screens.first { $0.settingsKey == workspace.display } ?? screen
        if let layout = store.layouts(for: screen).first(where: { $0.id == workspace.layoutID }) {
            commands.select(layout, on: screen)
        }
        let geometry = ZoneGeometry(screen: screen, gap: Settings.gap)
        let layout = store.activeLayout(for: screen)
        let sameLayout = layout.id == workspace.layoutID
        var unused = WindowList.appWindows(on: screen)
        for entry in workspace.entries {
            let target = Self.frame(for: entry, geometry: geometry, layout: layout, sameLayout: sameLayout)
            let candidates = unused.filter { $0.bundleID == entry.bundleID }
            let titled = candidates.first { candidate in
                entry.title != nil && AXWindow.find(pid: candidate.pid, windowID: candidate.id)?.title == entry.title
            }
            if let match = titled ?? candidates.first, let window = AXWindow.find(pid: match.pid, windowID: match.id) {
                unused.removeAll { $0.id == match.id }
                mover.snap(window, to: target, area: geometry.area, swap: false)
            } else if NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID).isEmpty {
                open(entry, into: target, area: geometry.area)
            }
            // A running app with no window in this stage is left where it is: bringing it here
            // would switch stages.
        }
        Log.debug("workspace: restored \(workspace.name)")
    }

    /// The entry's zone in the same layout, or its saved place on the usable area.
    static func frame(for entry: Workspace.Entry, geometry: ZoneGeometry, layout: Layout, sameLayout: Bool) -> CGRect {
        let frames = geometry.frames(layout)
        if sameLayout, let zone = entry.zone, frames.indices.contains(zone) { return frames[zone] }
        let a = geometry.area
        return CGRect(x: a.minX + entry.unit.minX * a.width, y: a.minY + entry.unit.minY * a.height,
                      width: entry.unit.width * a.width, height: entry.unit.height * a.height).integral
    }

    /// Opens an app, then places its first window once it appears (for up to 8 seconds).
    private func open(_ entry: Workspace.Entry, into target: CGRect, area: CGRect) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, _ in
            guard let pid = app?.processIdentifier else { return }
            DispatchQueue.main.async { self?.place(pid: pid, into: target, area: area, attempts: 27) }
        }
    }

    private func place(pid: pid_t, into target: CGRect, area: CGRect, attempts: Int) {
        let windows: [AXUIElement] = AXUIElementCreateApplication(pid).attribute(kAXWindowsAttribute) ?? []
        if let window = windows.lazy.map({ AXWindow(element: $0, pid: pid) }).first(where: \.isMovable) {
            mover.snap(window, to: target, area: area, swap: false)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.place(pid: pid, into: target, area: area, attempts: attempts - 1) }
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        onChange?()
    }
}
