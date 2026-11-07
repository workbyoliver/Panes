import AppKit
import SwiftUI

/// The menu bar item: an icon drawn from the active layout. A click opens the Panes panel,
/// which hangs just under the menu bar. Escape, a click elsewhere or switching apps closes it.
final class StatusItemController: NSObject, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: LayoutStore
    private let model: PanelModel
    private var host: NSHostingView<PanesPanelView>!
    private var panel: GlassPanel!
    private var panelSize = CGSize.zero
    private var isOpen = false
    private var panelClosedAt = Date.distantPast
    private var monitors: [Any] = []

    init(store: LayoutStore, commands: Commands, shortcuts: LayoutShortcuts) {
        self.store = store
        model = PanelModel(store: store, commands: commands, shortcuts: shortcuts)
        super.init()
        model.screen = { [weak self] in self?.screen ?? NSScreen.main ?? NSScreen.screens[0] }
        model.close = { [weak self] in self?.closePanel() }
        model.refresh()

        if let button = item.button {
            button.setAccessibilityLabel("Panes")
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        host = NSHostingView(rootView: PanesPanelView(model: model) { [weak self] size in self?.panelSizeChanged(size) })
        host.sizingOptions = [] // sized by positionPanel
        panel = GlassPanel(content: host)
        panel.delegate = self
        setUpMonitors()
        refreshIcon()
    }

    private var screen: NSScreen {
        item.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The active layout or the layouts file changed.
    func layoutsChanged() {
        refreshIcon()
        if isOpen { model.refreshLayouts() }
    }

    /// Only changes when the layout does (each menu bar change costs a re-render).
    private func refreshIcon() {
        item.button?.image = LayoutIcon.image(for: store.activeLayout(for: screen), size: NSSize(width: 22, height: 14))
    }

    private func setUpMonitors() {
        // A click anywhere else closes the panel (a click on the item toggles it instead).
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isOpen, !self.isPointerOverItem else { return }
            self.closePanel()
        }
        // Escape closes; Tab picks the next layout, as it does during a ⌥-drag. Keys for a
        // layout shortcut being typed go to that first.
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            if self.model.handleKey(event) { return nil }
            switch Int(event.keyCode) {
            case 53: self.closePanel()
            case 48: self.model.selectNextLayout()
            default: return event
            }
            return nil
        }
        monitors = [outside, keys].compactMap { $0 }
    }

    /// The item's on-screen rect, padded to the full menu bar height.
    private var itemRect: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: 0, dy: -4)
    }

    private var isPointerOverItem: Bool {
        itemRect?.contains(NSEvent.mouseLocation) ?? false
    }

    // MARK: - Panel

    @objc private func handleClick() {
        if isOpen {
            closePanel()
        } else if Date().timeIntervalSince(panelClosedAt) > 0.3 {
            // (Otherwise this click on the item is what just closed it.)
            showPanel()
        }
    }

    private func showPanel() {
        isOpen = true
        model.refresh()
        panel.attachContent()
        positionPanel()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.refreshShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.refreshShadow() } // AppKit calls this on the main thread
        }
        item.button?.highlight(true)
    }

    private func closePanel() {
        guard isOpen else { return }
        isOpen = false
        model.endEditing()
        panelClosedAt = Date()
        item.button?.highlight(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { // AppKit calls this on the main thread
                guard let self, !self.isOpen else { return } // reopened meanwhile
                self.panel.orderOut(nil)
                self.panel.detachContent()
            }
        }
    }

    /// The SwiftUI content reports its size whenever it changes (open or not).
    private func panelSizeChanged(_ size: CGSize) {
        panelSize = size
        if isOpen {
            positionPanel(keepingHorizontalPosition: true)
        } else {
            // First layout at launch: now that the size is known, detach until opened.
            DispatchQueue.main.async { [weak self] in self?.panel.detachContent() }
        }
    }

    /// Hangs the panel 6 pt below the menu bar, its left edge lined up with the item's and
    /// kept on screen. While open it only grows or shrinks downwards, never sideways.
    private func positionPanel(keepingHorizontalPosition: Bool = false) {
        guard panelSize.width > 0, panelSize.height > 0, let itemRect else { return }
        let visible = screen.visibleFrame
        let preferredX = keepingHorizontalPosition ? panel.frame.minX : itemRect.minX
        let x = min(max(preferredX, visible.minX + 8), visible.maxX - panelSize.width - 8)
        let top = visible.maxY - 6
        panel.setFrame(NSRect(x: x, y: top - panelSize.height, width: panelSize.width, height: panelSize.height), display: true)
        panel.refreshShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel() // you moved on to another app or window
    }
}

/// A layout drawn as small rounded tiles, as a template image (it adapts to the menu bar).
enum LayoutIcon {
    static func image(for layout: Layout, size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            let gap: CGFloat = 1.5
            let bounds = rect.insetBy(dx: 0.5, dy: 0.5)
            NSColor.black.setFill()
            for zone in layout.zones {
                let tile = CGRect(x: bounds.minX + zone.x * bounds.width, y: bounds.minY + zone.y * bounds.height,
                                  width: zone.w * bounds.width, height: zone.h * bounds.height)
                    .insetBy(dx: gap / 2, dy: gap / 2)
                NSBezierPath(roundedRect: tile, xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = layout.name
        return image
    }
}
