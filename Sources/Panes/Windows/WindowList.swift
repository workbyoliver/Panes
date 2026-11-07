import AppKit

/// Questions about other windows on screen, answered by the window server.
enum WindowList {
    /// The frontmost app window already filling `zone` (other than `excluding`), if any.
    /// Only on-screen windows count, so other Stage Manager stages and Spaces are left alone.
    static func occupant(of zone: CGRect, excluding: CGWindowID) -> AXWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
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
            return window
        }
        return nil
    }
}
