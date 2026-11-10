import AppKit
import ApplicationServices

/// The window server's ID for an accessibility window element. Private, but long-standing
/// and used by every Mac window manager: AX has no public way to match a window element to
/// the window CGWindowList reports.
@_silgen_name("_AXUIElementGetWindow")
nonisolated private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Another app's window, reached through the Accessibility API.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// The frontmost app's focused window.
    static func focused() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = appElement.attribute(kAXFocusedWindowAttribute)
                ?? appElement.attribute(kAXMainWindowAttribute) else { return nil }
        return AXWindow(element: window, pid: app.processIdentifier)
    }

    /// The AX element for a window the window server reported.
    static func find(pid: pid_t, windowID: CGWindowID) -> AXWindow? {
        let appElement = AXUIElementCreateApplication(pid)
        let windows: [AXUIElement] = appElement.attribute(kAXWindowsAttribute) ?? []
        return windows.lazy.map { AXWindow(element: $0, pid: pid) }.first { $0.windowID == windowID }
    }

    var title: String? { element.attribute(kAXTitleAttribute) }

    /// Brings the window to the front, and its app with it (through Accessibility, which
    /// macOS honours where a background app's activation request may be refused).
    func focus() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        element.setBool(true, for: kAXMainAttribute)
        AXUIElementCreateApplication(pid).setBool(true, for: kAXFrontmostAttribute)
    }

    /// Top-left coordinates.
    var frame: CGRect? {
        guard let position: CGPoint = element.value(kAXPositionAttribute),
              let size: CGSize = element.value(kAXSizeAttribute) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Ordinary document/app windows, not sheets, popovers or panels-in-disguise.
    var isMovable: Bool {
        let subrole: String? = element.attribute(kAXSubroleAttribute)
        guard subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { return false }
        let fullScreen: Bool = element.attribute("AXFullScreen") ?? false
        return !fullScreen && element.isSettable(kAXPositionAttribute)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        element.setValue(point, for: kAXPositionAttribute)
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        element.setValue(size, for: kAXSizeAttribute)
    }
}

extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func value<T>(_ name: String) -> T? {
        guard let raw: CFTypeRef = attribute(name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue // checked by type ID above
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return AXValueGetValue(axValue, AXValueGetType(axValue), pointer) ? pointer.pointee : nil
    }

    func setValue(_ point: CGPoint, for name: String) -> Bool {
        var copy = point
        guard let axValue = AXValueCreate(.cgPoint, &copy) else { return false }
        return AXUIElementSetAttributeValue(self, name as CFString, axValue) == .success
    }

    func setValue(_ size: CGSize, for name: String) -> Bool {
        var copy = size
        guard let axValue = AXValueCreate(.cgSize, &copy) else { return false }
        return AXUIElementSetAttributeValue(self, name as CFString, axValue) == .success
    }

    @discardableResult
    func setBool(_ value: Bool, for name: String) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse)!) == .success
    }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success && settable.boolValue
    }
}
