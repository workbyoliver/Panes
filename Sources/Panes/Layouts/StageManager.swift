import Foundation

/// Stage Manager keeps a strip of recent apps along the left edge. While it's showing,
/// zones start to its right so the thumbnails stay visible (a choice in the menu).
enum StageManager {
    /// Thumbnails reach ~195 pt from the left edge (measured on a 3840 pt wide display).
    static let stripWidth: CGFloat = 200

    private static let domain = "com.apple.WindowManager" as CFString
    private static var cached: (date: Date, on: Bool, stripShown: Bool)?

    static var isOn: Bool { read().on }

    /// The space zones leave on the left of each display.
    static var leftInset: CGFloat {
        let state = read()
        return Settings.leaveRoomForStageManager && state.on && state.stripShown ? stripWidth : 0
    }

    /// Read at most every couple of seconds: zone geometry is rebuilt on every drag event.
    private static func read() -> (date: Date, on: Bool, stripShown: Bool) {
        if let cached, Date().timeIntervalSince(cached.date) < 2 { return cached }
        CFPreferencesAppSynchronize(domain)
        let on = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, domain) as? Bool ?? false
        let hidesStrip = CFPreferencesCopyAppValue("AutoHide" as CFString, domain) as? Bool ?? false
        let state = (date: Date(), on: on, stripShown: !hidesStrip)
        cached = state
        return state
    }
}
