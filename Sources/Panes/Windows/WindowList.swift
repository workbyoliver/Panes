import AppKit

/// Questions about other windows on screen, answered by the window server.
enum WindowList {
    /// The frontmost app window already filling `zone` (other than `excluding`), if any.
    /// Only on-screen windows count, so other Stage Manager stages and Spaces are left alone.
    static func occupant(of zone: CGRect, excluding: CGWindowID) -> AXWindow? {
        windows(filling: zone, excluding: excluding, first: true).first
    }

    /// Every app window filling `zone`, front to back: the zone's stack.
    static func windows(filling zone: CGRect, excluding: CGWindowID? = nil, first: Bool = false) -> [AXWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var found: [AXWindow] = []
        for info in list { // front to back
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID, id != excluding,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            // Mostly the same rectangle both ways: fills the zone, and isn't much bigger than it
            // (apps with a minimum or stepped size never fit a zone exactly).
            let overlap = bounds.intersection(zone)
            guard !overlap.isNull, overlap.area >= zone.area * 0.7, overlap.area >= bounds.area * 0.7 else { continue }
            guard let window = AXWindow.find(pid: pid, windowID: id), window.isMovable else { continue }
            found.append(window)
            if first { break }
        }
        return found
    }

    struct AppWindow {
        let id: CGWindowID
        let pid: pid_t
        let bundleID: String
        let appName: String
        let bounds: CGRect
    }

    /// App windows on screen on this display, front to back: under Stage Manager, the current
    /// stage's windows.
    static func appWindows(on screen: NSScreen) -> [AppWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let display = screen.rect
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width >= 120, bounds.height >= 80,
                  bounds.intersection(display).area >= bounds.area * 0.5,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bundle = app.bundleIdentifier else { return nil }
            return AppWindow(id: id, pid: pid, bundleID: bundle, appName: app.localizedName ?? bundle, bounds: bounds)
        }
    }
}
