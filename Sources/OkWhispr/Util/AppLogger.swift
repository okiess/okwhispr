import Foundation

/// A tiny file logger so a menu-bar app (no stdout) can be inspected.
/// Writes to ~/Library/Logs/OkWhispr.log.
enum AppLogger {
    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return dir.appendingPathComponent("OkWhispr.log")
    }()

    private static let queue = DispatchQueue(label: "com.inceedo.okwhispr.log")

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        queue.async {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                try? handle.close()
            }
        }
    }

    static func error(_ message: String) {
        AppLogger.log("ERROR \(message)")
    }
}
