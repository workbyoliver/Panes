import AppKit
import SwiftUI

/// Shows "How Panes Works" in a glass card like the panel, centred on a display. It takes keys
/// without activating Panes: ← → change pages, esc closes. A click elsewhere closes it too.
final class TutorialWindow: NSObject, NSWindowDelegate {
    private let model = TutorialModel()
    private var panel: GlassPanel?
    private var monitors: [Any] = []

    func open(on screen: NSScreen) {
        if let panel { return panel.makeKeyAndOrderFront(nil) }
        model.page = 0
        let host = NSHostingView(rootView: TutorialView(model: model, close: { [weak self] in self?.close() }))
        host.sizingOptions = []
        let panel = GlassPanel(content: host)
        panel.delegate = self
        let size = TutorialView.size
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height),
                       display: true)
        self.panel = panel
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.refreshShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        } completionHandler: { [weak panel] in
            MainActor.assumeIsolated { panel?.refreshShadow() }
        }

        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            switch Int(event.keyCode) {
            case 53: self.close()                                   // esc
            case 124, 49: self.model.next()                         // → or space
            case 123: self.model.back()                             // ←
            case 36: if self.model.page == TutorialModel.pageCount - 1 { self.close() } else { self.model.next() } // ↩
            default: return event
            }
            return nil
        }
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        monitors = [keys, outside].compactMap { $0 }
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close() // you moved on to another app
    }
}
