import AppKit

/// A borderless, arrowless Liquid Glass panel that hangs under the menu bar item, like
/// macOS 26's own menu bar panels (and Player's). It can become key without activating
/// Panes, so the app you were using stays frontmost: its window is the one Panes moves.
final class GlassPanel: NSPanel {
    /// Concentric with the content: 16 pt padding around the 16 pt-radius zone board.
    static let cornerRadius: CGFloat = 32

    private let glass = NSGlassEffectView()
    private let content: NSView

    init(content: NSView, cornerRadius: CGFloat = GlassPanel.cornerRadius) {
        self.content = content
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua) // dark glass keeps text legible on any wallpaper

        // AppKit glass blurs what's behind the window; SwiftUI's .glassEffect only samples
        // what's inside it, which in an otherwise empty panel looks opaque.
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        content.frame = glass.bounds
        content.autoresizingMask = [.width, .height]
        glass.contentView = content

        // Clip to the rounded shape so the corners are truly empty and the shadow follows the curve.
        let rounded = NSView()
        rounded.wantsLayer = true
        rounded.layer?.cornerRadius = cornerRadius
        rounded.layer?.cornerCurve = .continuous
        rounded.layer?.masksToBounds = true
        glass.frame = rounded.bounds
        glass.autoresizingMask = [.width, .height]
        rounded.addSubview(glass)
        contentView = rounded
    }

    override var canBecomeKey: Bool { true }

    /// Takes the content out of the window while the panel is closed, so SwiftUI does no
    /// work for something nobody can see.
    func detachContent() {
        guard !isVisible, glass.contentView != nil else { return }
        glass.contentView = nil
    }

    func attachContent() {
        guard glass.contentView == nil else { return }
        content.frame = glass.bounds
        glass.contentView = content
        content.layoutSubtreeIfNeeded() // reports its current size before the panel is placed
    }

    /// A borderless window's shadow comes from what's drawn, so redo it once the content has rendered.
    func refreshShadow() {
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }
}
