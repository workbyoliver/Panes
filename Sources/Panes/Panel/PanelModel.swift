import AppKit
import Observation

/// What the panel shows and does. Refreshed each time it opens; the layouts also refresh
/// while it's open (a layout picked with ⌃⌥L, or an edit to layouts.json).
@Observable
final class PanelModel {
    struct Warning: Identifiable {
        let id: String
        let title: String
        let detail: String
        let action: (() -> Void)?
    }

    private(set) var layouts: [Layout] = []
    private(set) var activeID = ""
    /// Width ÷ height of the area zones fill, so the zone board has the screen's shape.
    private(set) var aspect: CGFloat = 16.0 / 9
    /// The app and title of the window the move controls act on: the one that had focus
    /// when the panel opened.
    private(set) var frontApp: NSRunningApplication?
    private(set) var windowTitle = ""
    var canMoveWindow: Bool { target != nil }
    private var target: AXWindow?
    private(set) var gap = Settings.gap
    private(set) var snapAtEdges = Settings.snapAtEdges
    private(set) var leaveRoomForStageManager = Settings.leaveRoomForStageManager
    private(set) var rememberLayoutPerStage = Settings.rememberLayoutPerStage
    private(set) var stageManagerOn = false
    private(set) var opensAtLogin = false
    private(set) var warnings: [Warning] = []

    // The layout grid's Edit mode: each layout's shortcut (click to change), delete, and a
    // click on a layout opens it in the layout editor.
    private(set) var isEditing = false
    /// The layout whose delete badge was clicked once; a second click deletes it.
    private(set) var pendingDeleteID: String?
    /// Layouts that can go (a display always keeps at least one).
    private(set) var deletable: Set<String> = []
    /// Whether Restore Defaults has anything to do, and whether it's been clicked once.
    private(set) var canRestoreDefaults = false
    private(set) var isRestorePending = false
    /// The layout being dragged to a new place in Edit mode.
    private(set) var draggingID: String?
    /// A display has up to nine layouts (⌃⌥⌘1–9).
    var canAddLayout: Bool { layouts.count < LayoutEditorModel.maxLayoutsPerDisplay }
    /// The layout whose new shortcut you're typing.
    private(set) var recordingID: String?
    /// Why the last keys typed weren't taken (e.g. Panes uses them to move windows).
    private(set) var recordingNote: String?
    private(set) var shortcutText: [String: String] = [:]
    private(set) var takenShortcuts: Set<String> = []

    var active: Layout? { layouts.first { $0.id == activeID } ?? layouts.first }

    @ObservationIgnored private let store: LayoutStore
    @ObservationIgnored private let commands: Commands
    @ObservationIgnored private let shortcuts: LayoutShortcuts
    /// The display the menu bar item is on.
    @ObservationIgnored var screen: () -> NSScreen = { NSScreen.main ?? NSScreen.screens[0] }
    @ObservationIgnored var close: () -> Void = {}
    /// Opens the layout editor: a new layout (nil) or an existing one, on the panel's display.
    @ObservationIgnored var openEditor: (Layout?, NSScreen) -> Void = { _, _ in }
    /// Opens "How Panes Works" on the panel's display.
    @ObservationIgnored var openTutorial: (NSScreen) -> Void = { _ in }

    init(store: LayoutStore, commands: Commands, shortcuts: LayoutShortcuts) {
        self.store = store
        self.commands = commands
        self.shortcuts = shortcuts
    }

    func refresh() {
        refreshLayouts()
        let front = NSWorkspace.shared.frontmostApplication
        frontApp = front?.processIdentifier == getpid() ? nil : front
        let focused = Permissions.hasAccessibility ? AXWindow.focused() : nil
        target = focused?.isMovable == true ? focused : nil
        windowTitle = target?.title ?? ""
        gap = Settings.gap
        snapAtEdges = Settings.snapAtEdges
        leaveRoomForStageManager = Settings.leaveRoomForStageManager
        rememberLayoutPerStage = Settings.rememberLayoutPerStage
        stageManagerOn = StageManager.isOn
        opensAtLogin = Permissions.opensAtLogin
        refreshGeometry()
        warnings = currentWarnings()
    }

    /// Cheap (no Accessibility calls): safe to run on every layout change.
    func refreshLayouts() {
        let screen = screen()
        layouts = Array(store.layouts(for: screen).prefix(LayoutEditorModel.maxLayoutsPerDisplay)) // reloads layouts.json if it changed
        activeID = store.activeLayout(for: screen).id
        deletable = Set(layouts.filter(store.canDelete).map(\.id))
        canRestoreDefaults = store.defaultsDiffer
        if let pending = pendingDeleteID, !layouts.contains(where: { $0.id == pending }) { pendingDeleteID = nil }
        refreshShortcuts()
    }

    private func refreshShortcuts() {
        let screen = screen()
        shortcutText = Dictionary(uniqueKeysWithValues: layouts.compactMap { layout in
            shortcuts.shortcut(for: layout, on: screen).map { (layout.id, $0.display) }
        })
        takenShortcuts = Set(layouts.filter { shortcuts.isTaken($0, on: screen) }.map(\.id))
    }

    private func refreshGeometry() {
        let area = ZoneGeometry(screen: screen(), gap: 0).area
        aspect = area.height > 0 ? area.width / area.height : 16.0 / 9
    }

    // MARK: - Actions

    /// A click on a layout tile: picks it, or in Edit mode opens it in the layout editor.
    func tap(_ layout: Layout) {
        guard isEditing else { return select(layout) }
        let screen = screen()
        close()
        openEditor(layout, screen)
    }

    func showTutorial() {
        let screen = screen()
        close()
        openTutorial(screen)
    }

    func newLayout() {
        guard canAddLayout else { return NSSound.beep() }
        let screen = screen()
        close()
        openEditor(nil, screen)
    }

    /// A click on a tile's shortcut in Edit mode: type a new one (or click again to stop).
    func recordShortcut(_ layout: Layout) {
        pendingDeleteID = nil
        if recordingID == layout.id {
            stopRecording()
        } else {
            startRecording(layout)
        }
    }

    /// First click arms it (the badge says Delete), the second deletes.
    func requestDelete(_ layout: Layout) {
        stopRecording()
        isRestorePending = false
        guard pendingDeleteID == layout.id else {
            pendingDeleteID = layout.id
            return
        }
        pendingDeleteID = nil
        store.delete(layout) // the store's change refreshes the grid
    }

    /// First click arms it, the second restores the built-in layouts.
    func restoreDefaults() {
        stopRecording()
        pendingDeleteID = nil
        guard isRestorePending else {
            isRestorePending = true
            return
        }
        isRestorePending = false
        store.restoreDefaults() // the store's change refreshes the grid
    }

    // MARK: Reordering (Edit mode)

    func beginReorder(_ layout: Layout) {
        stopRecording()
        pendingDeleteID = nil
        draggingID = layout.id
    }

    /// Moves the dragged layout to another place while the drag goes on (saved on release).
    func moveDragged(to index: Int) {
        guard let id = draggingID, let from = layouts.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), layouts.count - 1)
        guard to != from else { return }
        layouts.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func endReorder() {
        guard draggingID != nil else { return }
        draggingID = nil
        store.reorder(layouts.map(\.id)) // the store's change refreshes the grid and shortcuts
    }

    func toggleEditing() {
        if isEditing { endEditing() } else { isEditing = true }
    }

    /// Leaves Edit mode (Done, or the panel closing) and switches the shortcuts back on.
    func endEditing() {
        stopRecording()
        endReorder()
        pendingDeleteID = nil
        isRestorePending = false
        isEditing = false
    }

    private func startRecording(_ layout: Layout) {
        recordingID = layout.id
        recordingNote = nil
        HotKeys.shared.suspend() // so typing ⌃⌥⌘1 reaches the panel instead of switching layouts
    }

    private func stopRecording() {
        guard recordingID != nil else { return }
        recordingID = nil
        HotKeys.shared.resume()
    }

    /// Keys typed into the panel. Returns true if they were for the shortcut being recorded.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let id = recordingID, let layout = layouts.first(where: { $0.id == id }) else { return false }
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        switch Int(event.keyCode) {
        case 53: // Escape: keep the shortcut it had
            stopRecording()
        case 51 where modifiers.isEmpty, 117 where modifiers.isEmpty: // Delete: no shortcut
            stopRecording()
            shortcuts.set(nil, for: layout, on: screen())
        default:
            guard let shortcut = HotKeys.Shortcut(event: event) else {
                recordingNote = "Use ⌃, ⌥ or ⌘ with a key."
                NSSound.beep()
                return true
            }
            guard !HotKeys.Shortcut.reserved.contains(shortcut) else {
                recordingNote = "\(shortcut.display) already moves windows."
                NSSound.beep()
                return true
            }
            stopRecording()
            shortcuts.set(shortcut, for: layout, on: screen())
        }
        recordingNote = nil
        refreshShortcuts()
        return true
    }

    func select(_ layout: Layout) {
        let screen = screen()
        store.setActive(layout, for: screen)
        activeID = layout.id
        commands.showLayout(layout, on: screen)
    }

    func selectNextLayout() {
        guard let active, let index = layouts.firstIndex(of: active) else { return }
        select(layouts[(index + 1) % layouts.count])
    }

    func moveToZone(_ number: Int) {
        guard let target else { return NSSound.beep() } // never fall back to whatever has focus now
        commands.moveToZone(number, window: target)
        close()
    }

    func fill() {
        guard let target else { return NSSound.beep() }
        commands.fill(window: target)
        close()
    }

    func centre() {
        guard let target else { return NSSound.beep() }
        commands.centre(window: target)
        close()
    }

    /// Stays open, so you can step back through several moves.
    func undo() {
        guard let target else { return NSSound.beep() }
        commands.undo(window: target)
    }

    func setGap(_ value: CGFloat) {
        Settings.gap = value
        gap = value
        previewActiveLayout()
    }

    func setSnapAtEdges(_ on: Bool) {
        Settings.snapAtEdges = on
        snapAtEdges = on
    }

    func setLeaveRoomForStageManager(_ on: Bool) {
        Settings.leaveRoomForStageManager = on
        leaveRoomForStageManager = on
        refreshGeometry()
        previewActiveLayout()
    }

    func setRememberLayoutPerStage(_ on: Bool) {
        Settings.rememberLayoutPerStage = on
        rememberLayoutPerStage = on
    }

    func setOpensAtLogin(_ on: Bool) {
        Permissions.opensAtLogin = on
        opensAtLogin = Permissions.opensAtLogin // what macOS actually did
    }

    func repairLayoutsFile() {
        store.repairFile() // the store's change refreshes the panel
        warnings = currentWarnings()
    }

    /// Flashes the zones on screen, so a gap or margin change shows straight away.
    private func previewActiveLayout() {
        guard let active else { return }
        commands.showLayout(active, on: screen())
    }

    private func currentWarnings() -> [Warning] {
        var warnings: [Warning] = []
        if !Permissions.hasAccessibility {
            warnings.append(Warning(id: "accessibility", title: "Allow Accessibility Access",
                                    detail: "Panes needs it to move windows.",
                                    action: { [weak self] in self?.close(); Permissions.openAccessibilitySettings() }))
        }
        if Permissions.systemTilingOn {
            warnings.append(Warning(id: "tiling", title: "Turn Off macOS Tiling",
                                    detail: "Desktop & Dock → Windows: switch off the three tiling options.",
                                    action: { [weak self] in self?.close(); Permissions.openDesktopAndDockSettings() }))
        }
        if let error = store.loadError {
            warnings.append(Warning(id: "layouts", title: "Layouts File Has an Error",
                                    detail: "\(error). Click to rewrite it from the layouts Panes is using.",
                                    action: { [weak self] in self?.repairLayoutsFile() }))
        }
        let taken = HotKeys.shared.failed.count
        if taken > 0 {
            warnings.append(Warning(id: "shortcuts", title: "\(taken) Shortcut\(taken == 1 ? "" : "s") Taken by Another App",
                                    detail: "Remove clashing ⌃⌥ shortcuts (e.g. in Raycast), then relaunch Panes.",
                                    action: nil))
        }
        return warnings
    }
}
