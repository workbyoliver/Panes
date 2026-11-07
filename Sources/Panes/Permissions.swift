import AppKit
import ServiceManagement

enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows macOS's prompt (once), which leads to Privacy & Security → Accessibility.
    static func promptForAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// macOS 15+ tiles windows itself when you drag them to an edge or hold ⌥, which would
    /// fight Panes. These are on unless they've been switched off in Desktop & Dock.
    static var systemTilingOn: Bool {
        ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTilingOptionAccelerator"].contains { key in
            let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.WindowManager" as CFString)
            return (value as? Bool) ?? true
        }
    }

    static func openDesktopAndDockSettings() {
        open("x-apple.systempreferences:com.apple.Desktop-Settings.extension")
    }

    static var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSSound.beep()
            }
        }
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
