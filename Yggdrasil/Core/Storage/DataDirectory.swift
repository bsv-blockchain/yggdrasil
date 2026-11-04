import Foundation

/// The folder holding the database and the control socket:
/// `~/Library/Application Support/Yggdrasil`, or `YGGDRASIL_DATA_DIR` when
/// set, to run a build without touching the real data. UserDefaults stay
/// where they are.
enum DataDirectory {
    static let environmentKey = "YGGDRASIL_DATA_DIR"

    static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[environmentKey], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Yggdrasil", isDirectory: true)
    }
}
