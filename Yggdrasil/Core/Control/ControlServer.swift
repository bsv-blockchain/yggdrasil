import Darwin
import Foundation

/// Accepts control API connections on a Unix socket and on 127.0.0.1, reads
/// one HTTP request from each, and writes back what `handler` returns.
/// Nothing listens on any other interface.
final class ControlServer: @unchecked Sendable {
    enum Endpoint: Equatable {
        /// Created 0600; a connection from another uid is dropped.
        case unix(path: String)
        /// Port 0 picks a free one.
        case loopback(port: UInt16)
    }

    struct Peer: Equatable {
        /// True over TCP, where a browser could be the client.
        let viaLoopbackTCP: Bool
    }

    enum Failure: Error, Equatable {
        case socket(Int32)
        case pathTooLong
        /// Another Yggdrasil already serves this socket.
        case inUse(String)
    }

    typealias Handler = @Sendable (HTTPRequest, Peer) async -> HTTPResponse

    static let maxBody = 1_000_000
    /// Connections being read or answered at once; more are closed straight
    /// away, so a client holding many open can't use up the app's file
    /// descriptors or threads.
    static let maxConnections = 32
    /// For the whole request, not each read: trickling a byte at a time
    /// doesn't keep a connection.
    static let requestDeadline: TimeInterval = 10

    private struct Listener {
        let source: DispatchSourceRead
        let descriptor: Int32
    }

    private let handler: Handler
    private let queue = DispatchQueue(label: "yggdrasil.control.accept")
    private let ioQueue = DispatchQueue(label: "yggdrasil.control.io", attributes: .concurrent)
    private let lock = NSLock()
    private var listeners: [Listener] = []
    private var connections = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// The listening sockets, for tests.
    var descriptors: [Int32] {
        lock.withLock { listeners.map(\.descriptor) }
    }

    /// Starts listening; returns the bound port (0 for a Unix socket).
    @discardableResult
    func listen(_ endpoint: Endpoint) throws -> UInt16 {
        let descriptor: Int32
        var port: UInt16 = 0
        var path: String?
        switch endpoint {
        case let .unix(socketPath):
            descriptor = try Self.bindUnix(socketPath)
            path = socketPath
        case let .loopback(requested):
            (descriptor, port) = try Self.bindLoopback(requested)
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.socket(code)
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        // The file we bound, so stopping removes only that one and not a
        // socket another instance has since put at the path.
        var bound = stat()
        let identity = path.flatMap { lstat($0, &bound) == 0 ? (bound.st_dev, bound.st_ino) : nil }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let viaTCP = path == nil
        source.setEventHandler { [weak self] in self?.acceptAll(descriptor, viaLoopbackTCP: viaTCP) }
        source.setCancelHandler {
            close(descriptor)
            var current = stat()
            if let path, let identity, lstat(path, &current) == 0,
               current.st_dev == identity.0, current.st_ino == identity.1 {
                unlink(path)
            }
        }
        source.resume()
        lock.withLock { listeners.append(Listener(source: source, descriptor: descriptor)) }
        return port
    }

    /// Stops listening. Returns once the sockets are closed and the socket
    /// file is gone, so the same path can be bound again straight away.
    func stop() {
        let stopping = lock.withLock {
            defer { listeners = [] }
            return listeners
        }
        guard !stopping.isEmpty else { return }
        stopping.forEach { $0.source.cancel() }
        // Cancel handlers run on the accept queue, after any in-flight accept.
        queue.sync {}
    }

    // MARK: - Sockets

    /// A socket that isn't passed on to the agents the app spawns.
    private static func makeSocket(_ domain: Int32) throws -> Int32 {
        let descriptor = socket(domain, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket(errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        return descriptor
    }

    private static func bindUnix(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            bytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        // A socket file left by a crash is stale; one that answers isn't ours
        // to take.
        if FileManager.default.fileExists(atPath: path) {
            guard !answers(&address) else { throw Failure.inUse(path) }
            unlink(path)
        }
        let descriptor = try makeSocket(AF_UNIX)
        // Created without group/other access, then pinned to 0600.
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard bound == 0, chmod(path, 0o600) == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.socket(code)
        }
        return descriptor
    }

    private static func answers(_ address: inout sockaddr_un) -> Bool {
        guard let probe = try? makeSocket(AF_UNIX) else { return false }
        defer { close(probe) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private static func bindLoopback(_ port: UInt16) throws -> (Int32, UInt16) {
        let descriptor = try makeSocket(AF_INET)
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.socket(code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return (descriptor, UInt16(bigEndian: actual.sin_port))
    }

    // MARK: - Connections

    private func acceptAll(_ listener: Int32, viaLoopbackTCP: Bool) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            // Only this user's processes may use the socket.
            if !viaLoopbackTCP {
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                    close(client)
                    continue
                }
            }
            let admitted = lock.withLock {
                guard connections < Self.maxConnections else { return false }
                connections += 1
                return true
            }
            guard admitted else {
                close(client)
                continue
            }
            var enabled: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: Int(Self.requestDeadline), tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            let peer = Peer(viaLoopbackTCP: viaLoopbackTCP)
            ioQueue.async { [self] in serve(client, peer: peer) }
        }
    }

    private func serve(_ client: Int32, peer: Peer) {
        guard let request = read(client) else { return }
        let handler = handler
        Task {
            let response = await handler(request, peer)
            // The write blocks until the client reads; not on the shared
            // concurrency threads.
            ioQueue.async { [self] in finish(client, response) }
        }
    }

    /// The request, or nil after answering a bad one or giving up on it.
    private func read(_ client: Int32) -> HTTPRequest? {
        let deadline = Date().addingTimeInterval(Self.requestDeadline)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        do {
            while true {
                if let request = try HTTPParser.parse(received, maxBody: Self.maxBody) { return request }
                let count = Darwin.read(client, &buffer, buffer.count)
                guard count > 0, Date() < deadline else {
                    done(client)
                    return nil
                }
                received.append(contentsOf: buffer[0 ..< count])
            }
        } catch HTTPParser.Failure.tooLarge {
            finish(client, .empty(413))
        } catch {
            finish(client, .empty(400))
        }
        return nil
    }

    private func finish(_ client: Int32, _ response: HTTPResponse) {
        let bytes = response.serialized()
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                let written = write(client, raw.baseAddress! + offset, bytes.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        done(client)
    }

    private func done(_ client: Int32) {
        close(client)
        lock.withLock { connections -= 1 }
    }
}
