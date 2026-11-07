import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts through Carbon's hot keys: they need no permission and the key
/// press never reaches the frontmost app.
final class HotKeys {
    struct Shortcut: Hashable {
        let keyCode: Int
        let modifiers: NSEvent.ModifierFlags
        /// The key's character, for showing the shortcut (e.g. "1" or "c").
        let keyEquivalent: String

        /// Two shortcuts are the same if they're the same keys, whatever they're labelled.
        static func == (a: Self, b: Self) -> Bool { a.keyCode == b.keyCode && a.modifiers == b.modifiers }

        func hash(into hasher: inout Hasher) {
            hasher.combine(keyCode)
            hasher.combine(modifiers.rawValue)
        }
    }

    static let shared = HotKeys()

    private var actions: [UInt32: () -> Void] = [:]
    private var shortcuts: [UInt32: Shortcut] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var isSuspended = false
    private var nextID: UInt32 = 1
    /// Shortcuts another app already owns.
    private(set) var failed: [Shortcut] = []
    private var installed = false

    /// Returns an ID for `unregister`, or nil when another app owns the shortcut.
    @discardableResult
    func register(_ shortcut: Shortcut, reportFailure: Bool = true, action: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        guard let ref = Self.carbonRegister(shortcut, id: id) else {
            if reportFailure { failed.append(shortcut) }
            return nil
        }
        actions[id] = action
        shortcuts[id] = shortcut
        refs[id] = ref
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
        shortcuts[id] = nil
    }

    /// Switches every shortcut off while you type a new one in the panel, so the keys reach it
    /// instead of moving a window.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs = [:]
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for (id, shortcut) in shortcuts {
            refs[id] = Self.carbonRegister(shortcut, id: id)
        }
    }

    private static func carbonRegister(_ shortcut: Shortcut, id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), carbonModifiers(shortcut.modifiers),
                                         EventHotKeyID(signature: OSType(0x504E_4553), id: id), // "PNES"
                                         GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    fileprivate func fire(_ id: UInt32) {
        Log.debug("hotkey: \(id)")
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }
}

/// Carbon calls this on the main thread.
nonisolated private func hotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let key = id.id
    MainActor.assumeIsolated { HotKeys.shared.fire(key) }
    return noErr
}

extension HotKeys.Shortcut {
    private static let base: NSEvent.ModifierFlags = [.control, .option]

    static func key(_ keyCode: Int, _ equivalent: String) -> Self {
        Self(keyCode: keyCode, modifiers: base, keyEquivalent: equivalent)
    }

    private static func arrow(_ code: Int, _ functionKey: Int) -> Self {
        key(code, String(Character(UnicodeScalar(UInt16(functionKey))!)))
    }

    static func move(_ direction: Direction) -> Self {
        switch direction {
        case .left: arrow(kVK_LeftArrow, NSLeftArrowFunctionKey)
        case .right: arrow(kVK_RightArrow, NSRightArrowFunctionKey)
        case .up: arrow(kVK_UpArrow, NSUpArrowFunctionKey)
        case .down: arrow(kVK_DownArrow, NSDownArrowFunctionKey)
        }
    }

    static func grow(_ direction: Direction) -> Self {
        let plain = move(direction)
        return Self(keyCode: plain.keyCode, modifiers: plain.modifiers.union(.shift), keyEquivalent: plain.keyEquivalent)
    }

    static let zoneKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    static func zone(_ number: Int) -> Self { key(zoneKeys[number - 1], "\(number)") }
    static let fill = key(kVK_Return, "\r")
    static let centre = key(kVK_ANSI_C, "c")
    static let undo = key(kVK_Delete, "\u{8}")
    static let nextLayout = key(kVK_ANSI_L, "l")
    /// Only registered while a ⌥-drag is showing the zones.
    static let dragTab = Self(keyCode: kVK_Tab, modifiers: .option, keyEquivalent: "\t")
    static let dragShiftTab = Self(keyCode: kVK_Tab, modifiers: [.option, .shift], keyEquivalent: "\t")

    /// A layout's default: ⌃⌥⌘ and its place in the panel's grid.
    static func layout(_ number: Int) -> Self {
        Self(keyCode: zoneKeys[number - 1], modifiers: [.control, .option, .command], keyEquivalent: "\(number)")
    }

    /// Panes's own window shortcuts, which a layout can't take.
    static var reserved: [Self] {
        let directions = [Direction.left, .right, .up, .down]
        return directions.map(move) + directions.map(grow) + (1...9).map(zone)
            + [fill, centre, undo, nextLayout, dragTab, dragShiftTab]
    }

    /// A shortcut typed in the panel: needs ⌃, ⌥ or ⌘ (⇧ alone would take over typing).
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !modifiers.isDisjoint(with: [.control, .option, .command]) else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers,
                  keyEquivalent: event.charactersIgnoringModifiers?.lowercased() ?? "")
    }
}

extension HotKeys.Shortcut {
    /// How the shortcut reads in tooltips, e.g. "⌃⌥↩".
    var display: String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let modifierText = symbols.filter { modifiers.contains($0.0) }.map(\.1).joined()
        let keyText = switch keyCode {
        case kVK_Return: "↩"
        case kVK_Delete: "⌫"
        case kVK_Tab: "⇥"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Space: "Space"
        case kVK_ForwardDelete: "⌦"
        case kVK_Home: "↖"
        case kVK_End: "↘"
        case kVK_PageUp: "⇞"
        case kVK_PageDown: "⇟"
        default: Self.functionKeys[keyCode] ?? keyEquivalent.uppercased()
        }
        return modifierText + keyText
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
