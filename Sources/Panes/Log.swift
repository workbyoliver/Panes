import Foundation

/// Diagnostics, off by default. Launched with PANES_DEBUG set they go to stderr; with
/// `defaults write com.workbyoliver.Panes debugLog -bool true` (read at launch) they go to
/// ~/Library/Logs/Panes.log, so the installed app can be watched while it's used.
enum Log {
    private static let toStderr = ProcessInfo.processInfo.environment["PANES_DEBUG"] != nil
    private static let file: FileHandle? = {
        guard UserDefaults.standard.bool(forKey: "debugLog") else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Panes.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()
    static var enabled: Bool { toStderr || file != nil }

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = Data((Date().formatted(.dateTime.hour().minute().second()) + " " + message() + "\n").utf8)
        if toStderr { FileHandle.standardError.write(line) }
        file?.write(line)
    }
}

extension CGRect {
    var short: String { "(\(Int(minX)),\(Int(minY)) \(Int(width))×\(Int(height)))" }
}
