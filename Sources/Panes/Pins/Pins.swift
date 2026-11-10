import AppKit
import ScreenCaptureKit

/// Pin as a live window: a small floating copy of a window, kept above everything and shown on
/// every Space and stage. macOS gives no way to keep another app's window on top, but Panes's
/// own windows can float, so the copy is a live ScreenCaptureKit stream of the window. Click it
/// to go to the real window; drag to move it; ⌃⌥P, its × or right-click to unpin.
/// Needs Screen Recording permission (asked the first time).
final class Pins {
    static let shared = Pins()

    private var pins: [CGWindowID: PinWindow] = [:]

    func isPinned(_ id: CGWindowID) -> Bool { pins[id] != nil }

    /// ⌃⌥P: pins the focused window, or unpins it.
    func toggleFocused() {
        guard let window = AXWindow.focused(), window.isMovable else { return NSSound.beep() }
        toggle(window)
    }

    func toggle(_ window: AXWindow) {
        guard let id = window.windowID else { return NSSound.beep() }
        if pins[id] != nil { return unpin(id) }
        guard CGPreflightScreenCaptureAccess() else {
            // macOS asks once; apps usually need reopening after the permission is granted.
            if !CGRequestScreenCaptureAccess() { Log.debug("pin: Screen Recording not allowed yet") }
            return
        }
        Task { await pin(window, id: id) }
    }

    func unpin(_ id: CGWindowID) {
        guard let pin = pins.removeValue(forKey: id) else { return }
        pin.stop()
        arrange()
    }

    private func pin(_ window: AXWindow, id: CGWindowID) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let captured = content.windows.first(where: { $0.windowID == id }), pins[id] == nil else { return NSSound.beep() }
            let pin = PinWindow(window: window, id: id, size: captured.frame.size) { [weak self] in self?.unpin(id) }
            pins[id] = pin
            arrange()
            try await pin.start(capturing: captured)
            Log.debug("pin: pinned window \(id)")
        } catch {
            Log.debug("pin: couldn't capture window \(id): \(error.localizedDescription)")
            unpin(id)
            NSSound.beep()
        }
    }

    /// Stacks the copies up from the bottom-right corner of the main display, newest at the bottom.
    private func arrange() {
        guard let screen = NSScreen.main else { return }
        var y = screen.visibleFrame.minY + 16
        for pin in pins.values.sorted(by: { $0.created > $1.created }) where !pin.wasMoved {
            let size = pin.frame.size
            pin.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 16, y: y))
            y += size.height + 12
        }
    }
}

/// One pinned window's floating copy.
final class PinWindow: NSPanel, SCStreamDelegate {
    let id: CGWindowID
    let created = Date()
    /// Dragged somewhere by hand: left there when the others are rearranged.
    var wasMoved = false

    private let window: AXWindow
    private let onClose: () -> Void
    private let mirror = MirrorView()
    private let receiver = FrameReceiver()
    private var stream: SCStream?

    init(window: AXWindow, id: CGWindowID, size: CGSize, onClose: @escaping () -> Void) {
        self.window = window
        self.id = id
        self.onClose = onClose
        let width = min(420, max(220, size.width * 0.3))
        let height = width * size.height / max(size.width, 1)
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentAspectRatio = NSSize(width: width, height: height)
        minSize = NSSize(width: 160, height: 160 * height / width)

        mirror.frame = NSRect(x: 0, y: 0, width: width, height: height)
        mirror.autoresizingMask = [.width, .height]
        mirror.onClick = { [weak self] in self?.window.focus() }
        mirror.onMoved = { [weak self] in self?.wasMoved = true }
        mirror.onClose = { [weak self] in self?.onClose() }
        contentView = mirror
        receiver.layer = mirror.picture
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false } // never takes the keyboard

    func start(capturing captured: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: captured)
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // About the copy's own size, sharp on Retina: no need to stream the window full size.
        configuration.width = Int(min(captured.frame.width, 900) * scale)
        configuration.height = Int(min(captured.frame.width, 900) * scale * captured.frame.height / max(captured.frame.width, 1))
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let stream = stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        orderOut(nil)
    }

    /// The window closed (or capture failed): the copy goes too.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.onClose() }
    }
}

/// Receives the stream's frames on its own queue and hands each to the copy's layer.
nonisolated final class FrameReceiver: NSObject, SCStreamOutput, @unchecked Sendable {
    weak var layer: CALayer?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
        nonisolated(unsafe) let frame = surface
        nonisolated(unsafe) let target = layer
        DispatchQueue.main.async { target?.contents = frame }
    }
}

/// The copy's content: the live picture with rounded corners, a × on hover, click to go to the
/// window, drag to move, right-click for Unpin.
final class MirrorView: NSView {
    let picture = CALayer()
    var onClick: () -> Void = {}
    var onMoved: () -> Void = {}
    var onClose: () -> Void = {}

    private let closeButton = NSButton()
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1
        picture.contentsGravity = .resizeAspect
        picture.frame = bounds
        layer?.addSublayer(picture)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Unpin")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold).applying(.init(paletteColors: [.white, .black.withAlphaComponent(0.55)])))
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.alphaValue = 0
        closeButton.toolTip = "Unpin"
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = bounds
        CATransaction.commit()
        closeButton.frame = NSRect(x: bounds.maxX - 30, y: bounds.maxY - 30, width: 24, height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { closeButton.animator().alphaValue = 0 }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.mouse.x, dy = now.y - start.mouse.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onMoved() } else { onClick() }
        dragStart = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let unpin = NSMenuItem(title: "Unpin", action: #selector(close), keyEquivalent: "")
        unpin.target = self
        menu.addItem(unpin)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func close() { onClose() }
}
