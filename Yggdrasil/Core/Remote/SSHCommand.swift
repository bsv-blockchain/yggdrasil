import Foundation

/// argv builders for `/usr/bin/ssh`. The system ssh is used on purpose: it
/// reads the user's `~/.ssh/config`, agent (incl. 1Password and the like) and
/// ProxyJump, none of which we want to reimplement.
enum SSHCommand {
    static let executable = "/usr/bin/ssh"

    /// A ControlPath must fit the 104-byte `sun_path` limit including the
    /// ".<16 chars>" temp suffix ssh binds first, and ssh splits `-o` values
    /// on whitespace, so no "Application Support" (or long temp dir) here.
    static var defaultControlDirectory: String {
        NSHomeDirectory() + "/.ssh/ygg"
    }

    /// Wraps a POSIX sh script so the remote login shell (sh, zsh, bash,
    /// fish, whatever it is) only sees one single-quoted word of base64 and
    /// can't reinterpret any of it. The tty (for `-tt`) passes through.
    static func posixRemote(_ script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return "/bin/sh -c 'eval \"$(printf %s \(encoded) | base64 -d)\"'"
    }

    /// Inverse of `posixRemote`, for tests and logs.
    static func decodePosixRemote(_ command: String) -> String? {
        guard let start = command.range(of: "printf %s "),
              let end = command.range(of: " | base64 -d", range: start.upperBound ..< command.endIndex),
              let data = Data(base64Encoded: String(command[start.upperBound ..< end.lowerBound]))
        else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    /// Every call shares one master connection per host (one handshake, one
    /// auth prompt), and a dead link is detected in ~45s rather than at the
    /// next TCP timeout.
    static func options(controlDirectory: String) -> [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDirectory)/%C",
            "-o", "ControlPersist=600",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3"
        ]
    }

    /// For a terminal: forces a tty and leaves auth prompts interactive.
    /// `--` ends option parsing so the target can never be read as an option.
    static func interactive(target: String, remoteCommand: String, controlDirectory: String) -> [String] {
        options(controlDirectory: controlDirectory) + ["-tt", "--", target, remoteCommand]
    }

    /// For background calls: no tty, and BatchMode so a missing key fails fast
    /// instead of hanging on a prompt nobody sees.
    static func exec(target: String, remoteCommand: String, controlDirectory: String) -> [String] {
        options(controlDirectory: controlDirectory) + ["-T", "-o", "BatchMode=yes", "--", target, remoteCommand]
    }
}

extension SSHCommand {
    /// ssh won't create the ControlPath directory itself. 0700: the sockets
    /// grant use of an authenticated connection.
    static func prepareControlDirectory(_ path: String = defaultControlDirectory) {
        try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }
}
