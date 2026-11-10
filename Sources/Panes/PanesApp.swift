import AppKit

@main
enum PanesApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = LayoutStore()
    private let mover = WindowMover()
    private let overlay = ZoneOverlay()
    private lazy var commands = Commands(store: store, mover: mover, overlay: overlay)
    private lazy var drag = DragTracker(store: store, mover: mover, overlay: overlay)
    private lazy var layoutShortcuts = LayoutShortcuts(store: store, commands: commands)
    private lazy var stageMemory = StageMemory(store: store)
    private lazy var editor = LayoutEditorWindow(store: store, commands: commands)
    private let tutorial = TutorialWindow()
    private lazy var workspaces = Workspaces(store: store, mover: mover, commands: commands)
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A hung app mustn't freeze Panes: give up on any AX call after a second.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        if !Permissions.hasAccessibility { Permissions.promptForAccessibility() }

        registerShortcuts()
        layoutShortcuts.register()
        drag.start()
        stageMemory.start()
        store.onPick = { [weak self] layout, screen in self?.stageMemory.picked(layout, on: screen) }
        statusItem = StatusItemController(store: store, commands: commands, shortcuts: layoutShortcuts, workspaces: workspaces,
                                          editor: editor, tutorial: tutorial)
        store.onChange = { [weak self] in
            self?.layoutShortcuts.layoutsChanged()
            self?.statusItem?.layoutsChanged()
        }
    }

    private func registerShortcuts() {
        let keys = HotKeys.shared
        let commands = commands
        for direction in [Direction.left, .right, .up, .down] {
            keys.register(.move(direction)) { commands.move(direction) }
            keys.register(.grow(direction)) { commands.grow(direction) }
        }
        for number in 1...9 {
            keys.register(.zone(number)) { commands.moveToZone(number) }
        }
        keys.register(.fill) { commands.fill() }
        keys.register(.centre) { commands.centre() }
        keys.register(.undo) { commands.undo() }
        keys.register(.nextLayout) { commands.nextLayout() }
        keys.register(.display(.left)) { commands.moveToDisplay(.left) }
        keys.register(.display(.right)) { commands.moveToDisplay(.right) }
        keys.register(.cycleStack) { commands.cycleStack() }
        keys.register(.pin) { Pins.shared.toggleFocused() }
        for shortcut in keys.failed { Log.debug("hotkey taken: keyCode \(shortcut.keyCode) \(shortcut.modifiers)") }
        Log.debug("hotkeys: \(keys.failed.isEmpty ? "all registered" : "\(keys.failed.count) failed"); accessibility \(Permissions.hasAccessibility); layouts \(store.layouts.map(\.name)) \(store.loadError ?? "")")
    }
}
