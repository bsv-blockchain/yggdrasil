import Darwin
import Foundation

// yggctl — run Yggdrasil control API actions from a shell. The app must be
// running with Settings → API on; the key comes from YGGDRASIL_API_KEY.

let environment = ProcessInfo.processInfo.environment
let socketPath = environment["YGGDRASIL_SOCKET"] ?? FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Yggdrasil/control.sock").path

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// One request over the socket; nil when nothing listens there.
func exchange(_ request: Data) -> Data? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = socketPath.utf8CString
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }
    // The app answers an oversized request and closes before reading it all;
    // a write after that must fail, not kill the relay.
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var sent = 0
    request.withUnsafeBytes { raw in
        while sent < request.count {
            let count = write(fd, raw.baseAddress! + sent, request.count - sent)
            if count <= 0 { break }
            sent += count
        }
    }
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        received.append(contentsOf: buffer[0 ..< count])
    }
    return received
}

/// Runs `method`; exits on anything but a result.
func call(_ method: String, _ params: [String: Any], key: String) -> Any {
    let request = Yggctl.httpRequest(body: Yggctl.rpcBody(method: method, params: params), key: key)
    guard let raw = exchange(request) else {
        fail("Yggdrasil isn't running, or Settings → API is off (no socket at \(socketPath)).", Yggctl.Exit.unreachable)
    }
    guard let response = try? Yggctl.parseResponse(raw) else { fail("Unreadable reply.", Yggctl.Exit.failed) }
    let message = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
    guard message != nil || response.status >= 400 else { fail("Unreadable reply.", Yggctl.Exit.failed) }
    let error = message?["error"] as? [String: Any]
    let code = Yggctl.exitCode(status: response.status, hasError: error != nil)
    guard code == Yggctl.Exit.ok else {
        fail(error?["message"] as? String ?? "HTTP \(response.status)", code)
    }
    return message?["result"] ?? NSNull()
}

func printJSON(_ value: Any) {
    print(Yggctl.render(value))
}

let command: Yggctl.Command
do {
    command = try Yggctl.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail(String(describing: error), Yggctl.Exit.usage)
}

guard let key = environment["YGGDRASIL_API_KEY"], !key.isEmpty else {
    fail("Set YGGDRASIL_API_KEY to a key from Settings → API.", Yggctl.Exit.unauthorized)
}

if command == .mcp {
    // MCP's stdio transport: one JSON-RPC message per line each way. Each is
    // relayed to the app's MCP endpoint over the socket.
    setvbuf(stdout, nil, _IOLBF, 0)
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        let body = Data(line.utf8)
        let response = exchange(Yggctl.httpRequest(body: body, key: key, path: "/mcp"))
            .flatMap { try? Yggctl.parseResponse($0) }
        if let reply = Yggctl.mcpReply(status: response?.status, body: response?.body ?? Data(), request: body) {
            print(reply)
        }
    }
    exit(Yggctl.Exit.ok)
}

let catalogue = call("actions.list", [:], key: key) as? [[String: Any]] ?? []
switch command {
case .mcp:
    break
case .actions:
    for action in catalogue {
        let name = action["name"] as? String ?? ""
        print(name.padding(toLength: 22, withPad: " ", startingAt: 0) + (action["summary"] as? String ?? ""))
    }
case let .help(name):
    guard let action = catalogue.first(where: { $0["name"] as? String == name }) else {
        fail("No action \(name). See `yggctl actions`.", Yggctl.Exit.usage)
    }
    printJSON(action)
case let .run(name, pairs, json):
    guard let action = catalogue.first(where: { $0["name"] as? String == name }) else {
        fail("No action \(name). See `yggctl actions`.", Yggctl.Exit.usage)
    }
    let params: [String: Any]
    do {
        params = try Yggctl.params(pairs: pairs, json: json, schema: action["params"] as? [String: Any])
    } catch {
        fail(String(describing: error), Yggctl.Exit.usage)
    }
    printJSON(call(name, params, key: key))
}
