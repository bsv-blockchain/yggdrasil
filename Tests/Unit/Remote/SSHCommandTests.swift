import XCTest
@testable import Yggdrasil

final class SSHCommandTests: XCTestCase {
    private let control = "/tmp/ygg-ssh"

    func testOptionsShareOneConnectionWithKeepalive() {
        XCTAssertEqual(SSHCommand.options(controlDirectory: control), [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=/tmp/ygg-ssh/%C",
            "-o", "ControlPersist=600",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3"
        ])
    }

    func testInteractiveForcesTTYAndEndsOptionsBeforeTarget() {
        let argv = SSHCommand.interactive(target: "devbox", remoteCommand: "ygg version", controlDirectory: control)
        XCTAssertEqual(Array(argv.suffix(4)), ["-tt", "--", "devbox", "ygg version"])
        XCTAssertEqual(Array(argv.prefix(10)), SSHCommand.options(controlDirectory: control))
    }

    func testExecIsBatchModeWithoutTTY() {
        let argv = SSHCommand.exec(target: "me@devbox", remoteCommand: "true", controlDirectory: control)
        XCTAssertEqual(Array(argv.suffix(6)), ["-T", "-o", "BatchMode=yes", "--", "me@devbox", "true"])
    }

    func testControlPathFitsUnixSocketLimitIncludingTempSuffix() {
        // sun_path is 104 bytes on macOS. %C expands to 40 hex chars, and ssh
        // first binds "<path>.<16 random chars>" before renaming it.
        let path = SSHCommand.defaultControlDirectory + "/" + String(repeating: "f", count: 40) + "."
            + String(repeating: "x", count: 16)
        XCTAssertLessThan(path.utf8.count, 104, path)
        XCTAssertFalse(SSHCommand.defaultControlDirectory.contains(" "))
    }

    func testPosixRemoteIsInertToEveryLoginShell() {
        // The login shell (sh, zsh, bash, fish…) only ever sees one single-
        // quoted word of base64, so it has nothing to reinterpret.
        let wrapped = SSHCommand.posixRemote(#"printf '%s|%s' "a b" 'c\d' "$0""#)
        let pattern = #"^/bin/sh -c 'eval "\$\(printf %s [A-Za-z0-9+/=]+ \| base64 -d\)"'$"#
        XCTAssertNotNil(wrapped.range(of: pattern, options: .regularExpression), wrapped)
    }

    func testPosixRemoteRunsTheScriptUnderShAndZsh() throws {
        let script = #"printf '%s|%s' "a b" 'it'\''s \n'"#
        for shell in ["/bin/sh", "/bin/zsh"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", SSHCommand.posixRemote(script)]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            process.waitUntilExit()
            let text = String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            XCTAssertEqual(text, #"a b|it's \n"#, shell)
        }
    }

    func testDecodedPosixRemoteRoundTrips() {
        XCTAssertEqual(SSHCommand.decodePosixRemote(SSHCommand.posixRemote("echo 'hi'")), "echo 'hi'")
    }
}
