import AppKit
import SwiftUI

/// Opens the layout editor in its own window, one at a time. Panes comes forward while it's
/// open, so the name field takes typing, and gives focus back to your app when it closes.
final class LayoutEditorWindow: NSObject, NSWindowDelegate {
    private let store: LayoutStore
    private let commands: Commands
    private var window: NSWindow?
    private var previousApp: NSRunningApplication?

    init(store: LayoutStore, commands: Commands) {
        self.store = store
        self.commands = commands
    }

    /// A new layout (nil) or an existing one, starting on `screen` (or the layout's display).
    func open(_ layout: Layout?, on screen: NSScreen) {
        if let window { return bringForward(window) }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == getpid() ? nil : front

        let full = NSScreen.screens.filter { store.layouts(for: $0).count >= LayoutEditorModel.maxLayoutsPerDisplay }
        let model = LayoutEditorModel(displays: NSScreen.screens.map(EditorDisplay.init(screen:)),
                                      startOn: layout?.display ?? screen.settingsKey, editing: layout,
                                      name: LayoutEditorModel.suggestedName(avoiding: store.layouts.map(\.name)),
                                      fullDisplays: Set(full.map(\.settingsKey)))
        let view = LayoutEditorView(model: model,
                                    onCancel: { [weak self] in self?.window?.close() },
                                    onSave: { [weak self, weak model] in
                                        guard let self, let model else { return }
                                        self.save(model)
                                    })
        // Sized once from the content; the window never resizes itself.
        let host = NSHostingView(rootView: view)
        host.sceneBridgingOptions = []
        let size = host.fittingSize // measured before turning sizing off (it reads zero after)
        host.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = layout.map { "Edit \($0.name)" } ?? "New Layout"
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.delegate = self
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        self.window = window
        bringForward(window)
    }

    /// macOS 14+ can refuse to activate a background app like Panes (no Dock icon), which left
    /// the editor behind your window, unable to take clicks or typing. Order it to the front
    /// regardless and ask to be activated; a click on it then activates Panes anyway.
    private func bringForward(_ window: NSWindow) {
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKey()
    }

    private func save(_ model: LayoutEditorModel) {
        guard model.canSave else { return NSSound.beep() }
        let layout = model.layout()
        store.save(layout)
        // Show it straight away on the display it was drawn on.
        if let id = model.display?.id, let screen = NSScreen.screens.first(where: { $0.settingsKey == id }),
           layout.belongs(on: screen) {
            commands.select(layout, on: screen)
        }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        previousApp?.activate()
        previousApp = nil
    }
}
