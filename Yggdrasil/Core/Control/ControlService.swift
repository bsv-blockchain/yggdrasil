import Foundation
import Observation

/// The control API as Settings → API turns it on and off. Off by default;
/// while on, it listens on a Unix socket only this user can open and on
/// 127.0.0.1, and every request needs an API key.
@MainActor
@Observable
final class ControlService {
    static let enabledKey = "control.enabled"
    static let portKey = "control.port"
    static let defaultPort: UInt16 = 47610

    /// The command-line client inside this app bundle.
    nonisolated static var yggctlPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/yggctl").path
    }

    nonisolated static var defaultSocketPath: String {
        socketPath(environment: ProcessInfo.processInfo.environment)
    }

    nonisolated static func socketPath(environment: [String: String]) -> String {
        DataDirectory.url(environment: environment).appendingPathComponent("control.sock").path
    }

    let keys: APIKeyStore
    let socketPath: String
    /// The port actually bound while running.
    private(set) var boundPort: UInt16?
    private(set) var isRunning = false
    /// Why the last start failed, for Settings to show.
    private(set) var lastError: String?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var server: ControlServer?

    init(services: AppServices, socketPath: String = ControlService.defaultSocketPath) {
        self.services = services
        self.socketPath = socketPath
        keys = APIKeyStore(database: services.database)
    }

    var isEnabled: Bool {
        get { (try? services.settingsStore.get(forKey: Self.enabledKey)) == "1" }
        set {
            try? services.settingsStore.set(newValue ? "1" : "0", forKey: Self.enabledKey)
            apply()
        }
    }

    /// Also listen on 127.0.0.1, for clients that can't use a Unix socket.
    /// Off by default: unlike the socket, the port is open to every account on
    /// this Mac (the key still guards it), and while Yggdrasil isn't listening
    /// another account could take the port and collect keys sent to it.
    var listensOnLoopback: Bool {
        get { (try? services.settingsStore.get(forKey: Self.loopbackKey)) == "1" }
        set {
            try? services.settingsStore.set(newValue ? "1" : "0", forKey: Self.loopbackKey)
            apply()
        }
    }

    static let loopbackKey = "control.loopback"

    var port: UInt16 {
        get { (try? services.settingsStore.get(forKey: Self.portKey)).flatMap { UInt16($0) } ?? Self.defaultPort }
        set {
            try? services.settingsStore.set(String(newValue), forKey: Self.portKey)
            apply()
        }
    }

    /// Starts or stops the listeners to match the settings.
    func apply() {
        stop()
        guard isEnabled else { return }
        let router = ControlRouter(keys: keys, catalogue: ActionCatalog.all, services: services)
        let server = ControlServer { request, peer in await router.handle(request, peer: peer) }
        do {
            try FileManager.default.createDirectory(
                atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            try server.listen(.unix(path: socketPath))
        } catch {
            server.stop()
            lastError = Self.describe(error)
            YggdrasilLog.control.error("Control API didn't start: \(String(describing: error), privacy: .public)")
            return
        }
        self.server = server
        isRunning = true
        YggdrasilLog.control.info("Control API on \(self.socketPath, privacy: .public)")
        // The socket works on its own; a port that's taken doesn't stop it.
        guard listensOnLoopback else { return }
        do {
            let bound = try server.listen(.loopback(port: port))
            router.loopbackPort = bound
            boundPort = bound
            YggdrasilLog.control.info("Control API also on 127.0.0.1:\(bound)")
        } catch {
            lastError = Self.describe(error)
            YggdrasilLog.control.error("Control API port didn't open: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        boundPort = nil
        isRunning = false
        lastError = nil
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case ControlServer.Failure.socket(EADDRINUSE):
            "That port is in use. Choose another."
        case let ControlServer.Failure.inUse(path):
            "Another Yggdrasil is already listening on \(path)."
        case ControlServer.Failure.pathTooLong:
            "The socket path is too long for a Unix socket."
        default:
            String(describing: error)
        }
    }
}
