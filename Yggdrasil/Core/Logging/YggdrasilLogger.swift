import Foundation
#if canImport(os)
import os
#endif

public enum YggdrasilLog {
    public static let subsystem = "com.bsvassociation.yggdrasil"

    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let pty = Logger(subsystem: subsystem, category: "pty")
    public static let git = Logger(subsystem: subsystem, category: "git")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let db = Logger(subsystem: subsystem, category: "db")
    public static let auth = Logger(subsystem: subsystem, category: "auth")
    public static let control = Logger(subsystem: subsystem, category: "control")

    public static let allCategories: [String] = [
        "sync", "pty", "git", "ui", "db", "auth", "control"
    ]
}

#if !canImport(os)
/// Spike: os.Logger's call-site shape (`\(value, privacy: .public)`) off
/// Apple platforms, writing to standard error.
public struct Logger: Sendable {
    let category: String

    public init(subsystem _: String, category: String) {
        self.category = category
    }

    public func debug(_ message: LogMessage) { write("debug", message) }
    public func info(_ message: LogMessage) { write("info", message) }
    public func notice(_ message: LogMessage) { write("notice", message) }
    public func warning(_ message: LogMessage) { write("warning", message) }
    public func error(_ message: LogMessage) { write("error", message) }
    public func fault(_ message: LogMessage) { write("fault", message) }

    private func write(_ level: String, _ message: LogMessage) {
        FileHandle.standardError.write(Data("[\(category)] \(level): \(message.text)\n".utf8))
    }
}

public enum LogPrivacy: Sendable {
    case auto, `public`, `private`
}

public struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    let text: String

    public init(stringLiteral value: String) {
        text = value
    }

    public init(stringInterpolation: Interpolation) {
        text = stringInterpolation.text
    }

    public struct Interpolation: StringInterpolationProtocol {
        var text = ""

        public init(literalCapacity _: Int, interpolationCount _: Int) {}

        public mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        public mutating func appendInterpolation(_ value: some Any, privacy _: LogPrivacy = .auto) {
            text += String(describing: value)
        }
    }
}
#endif
