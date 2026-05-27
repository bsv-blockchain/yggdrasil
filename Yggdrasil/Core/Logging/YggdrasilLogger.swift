import Foundation
import os

public enum YggdrasilLog {
    public static let subsystem = "com.bsvassociation.yggdrasil"

    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let pty = Logger(subsystem: subsystem, category: "pty")
    public static let git = Logger(subsystem: subsystem, category: "git")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let db = Logger(subsystem: subsystem, category: "db")
    public static let auth = Logger(subsystem: subsystem, category: "auth")

    public static let allCategories: [String] = [
        "sync", "pty", "git", "ui", "db", "auth"
    ]
}
