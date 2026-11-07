import AppKit

/// Shows the active layout's zones as Liquid Glass panes, and a tinted pane where the window
/// will land. Click-through, and ordered just below the window being dragged so that window
/// stays crisp on top while everything else sits under the glass.
final class ZoneOverlay {
    static let cornerRadius: CGFloat = 16

    private let panel: NSPanel
    private let root = NSView()
    private let target = NSGlassEffectView()
    private var zoneViews: [NSView] = []
    private var shownZones: [CGRect] = []
    private var screenRect: CGRect = .zero
    private var targetFrame: CGRect?
    private var generation = 0

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        root.wantsLayer = true
        panel.contentView = root

        target.style = .regular
        target.cornerRadius = Self.cornerRadius
        target.tintColor = NSColor.controlAccentColor.withAlphaComponent(0.55)
        target.isHidden = true
    }

    /// `zones` and `target` are top-left frames on `screen`; `windowID` is the dragged window.
    func show(on screen: NSScreen, zones: [CGRect], target targetRect: CGRect?, below windowID: CGWindowID? = nil) {
        generation += 1
        let screenChanged = screen.rect != screenRect
        if screenChanged {
            screenRect = screen.rect
            panel.setFrame(screen.frame, display: false)
        }
        if screenChanged || zones != shownZones { rebuildZones(zones) }
        place(targetRect)

        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        if !panel.isVisible {
            panel.alphaValue = 0
            if let windowID {
                panel.level = .normal
                panel.order(.below, relativeTo: Int(windowID))
                Log.debug("overlay: window \(panel.windowNumber) ordered below \(windowID)")
            } else {
                panel.level = .floating
                panel.orderFrontRegardless()
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        generation += 1
        let token = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.panel.orderOut(nil)
                self.place(nil)
            }
        }
    }

    /// Shows the zones for a moment, e.g. after switching layouts.
    func flash(on screen: NSScreen, zones: [CGRect]) {
        if panel.isVisible { panel.orderOut(nil) } // re-show above everything
        show(on: screen, zones: zones, target: nil)
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.generation == token else { return }
            self.hide()
        }
    }

    private func local(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - screenRect.minX, y: screenRect.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func rebuildZones(_ zones: [CGRect]) {
        zoneViews.forEach { $0.removeFromSuperview() }
        target.removeFromSuperview()
        zoneViews = zones.enumerated().map { index, frame in
            let view = ZonePane(number: index + 1)
            view.frame = local(frame)
            root.addSubview(view)
            return view
        }
        root.addSubview(target)
        shownZones = zones
        if let targetFrame { target.frame = local(targetFrame) }
    }

    private func place(_ rect: CGRect?) {
        guard let rect else {
            target.isHidden = true
            targetFrame = nil
            return
        }
        let frame = local(rect)
        if targetFrame == nil || target.isHidden {
            target.frame = frame
            target.isHidden = false
        } else if rect != targetFrame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                target.animator().frame = frame
            }
        }
        targetFrame = rect
    }
}

/// One zone: a clear glass pane with its number.
private final class ZonePane: NSView {
    init(number: Int) {
        super.init(frame: .zero)
        let glass = NSGlassEffectView()
        glass.style = .clear
        glass.cornerRadius = ZoneOverlay.cornerRadius
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "\(number)")
        let base = NSFont.systemFont(ofSize: 64, weight: .semibold)
        label.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 64) } ?? base
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        glass.contentView = content
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
