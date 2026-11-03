import Foundation

/// `yggctl`: run a control API action from a shell. The parts that don't
/// touch the socket, so they can be tested.
enum Yggctl {
    enum Command: Equatable {
        /// List every action.
        case actions
        /// Show one action's parameters.
        case help(String)
        /// MCP over stdio, relayed to the app's socket: for MCP clients.
        case mcp
        /// `key=value` pairs and/or a JSON object of arguments.
        case run(action: String, pairs: [String: String], json: String?)
    }

    enum UsageError: Error, Equatable, CustomStringConvertible {
        case noCommand
        case badArgument(String)
        case badJSON

        var description: String {
            switch self {
            case .noCommand: "Usage: yggctl actions | help <action> | mcp | <action> [key=value …] [--json '{…}']"
            case let .badArgument(argument): "Can't read “\(argument)”: use key=value."
            case .badJSON: "--json takes a JSON object."
            }
        }
    }

    enum Exit {
        static let ok: Int32 = 0
        /// The app ran the action and it failed.
        static let failed: Int32 = 1
        static let usage: Int32 = 2
        /// Yggdrasil isn't running, or its API is off.
        static let unreachable: Int32 = 3
        static let unauthorized: Int32 = 4
    }

    static func parse(_ argv: [String]) throws -> Command {
        guard let first = argv.first else { throw UsageError.noCommand }
        switch first {
        case "actions": return .actions
        case "mcp": return .mcp
        case "help":
            guard argv.count == 2 else { throw UsageError.noCommand }
            return .help(argv[1])
        default:
            var pairs: [String: String] = [:]
            var json: String?
            var rest = argv.dropFirst()
            while let argument = rest.popFirst() {
                if argument == "--json" {
                    guard let value = rest.popFirst() else { throw UsageError.badJSON }
                    json = value
                    continue
                }
                guard let equals = argument.firstIndex(of: "="), equals != argument.startIndex else {
                    throw UsageError.badArgument(argument)
                }
                pairs[String(argument[..<equals])] = String(argument[argument.index(after: equals)...])
            }
            return .run(action: first, pairs: pairs, json: json)
        }
    }

    /// The action's arguments: `json` first, then the pairs, each converted
    /// to the type the action's schema gives it.
    static func params(pairs: [String: String], json: String?, schema: [String: Any]?) throws -> [String: Any] {
        var params: [String: Any] = [:]
        if let json {
            guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw UsageError.badJSON
            }
            params = object
        }
        let properties = schema?["properties"] as? [String: Any] ?? [:]
        for (key, raw) in pairs {
            let type = (properties[key] as? [String: Any])?["type"] as? String
            switch type {
            case "integer":
                guard let value = Int(raw) else { throw UsageError.badArgument("\(key)=\(raw)") }
                params[key] = value
            case "boolean":
                switch raw.lowercased() {
                case "true", "yes", "1": params[key] = true
                case "false", "no", "0": params[key] = false
                default: throw UsageError.badArgument("\(key)=\(raw)")
                }
            case "array":
                // `a,b`, or a JSON list when an item has a comma in it.
                if raw.hasPrefix("[") {
                    guard let list = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String] else {
                        throw UsageError.badArgument("\(key)=\(raw)")
                    }
                    params[key] = list
                } else {
                    params[key] = raw.isEmpty ? [] : raw.split(separator: ",").map(String.init)
                }
            case "object":
                guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                    throw UsageError.badArgument("\(key)=\(raw)")
                }
                params[key] = object
            default:
                params[key] = raw
            }
        }
        return params
    }

    static func rpcBody(method: String, params: [String: Any]) -> Data {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        return (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
    }

    static func httpRequest(body: Data, key: String, path: String = "/rpc") -> Data {
        let head = """
        POST \(path) HTTP/1.1\r
        Host: localhost\r
        Content-Type: application/json\r
        Accept: application/json, text/event-stream\r
        Authorization: Bearer \(key)\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        return Data(head.utf8) + body
    }

    /// What to write to stdout for one MCP message: nothing for a
    /// notification, and for a request always one line carrying its id. The
    /// app's own reply when it sent one; otherwise an error the client can
    /// show (`status` nil: the app couldn't be reached).
    static func mcpReply(status: Int?, body: Data, request: Data) -> String? {
        guard let message = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any] else {
            return line([
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": ["code": -32700, "message": "Not a JSON-RPC message."]
            ])
        }
        guard let id = message["id"] else { return nil }
        // A refused request comes back with a null id: the app didn't read it.
        if status != nil, var reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           reply["result"] != nil || reply["error"] != nil {
            reply["id"] = id
            return line(reply)
        }
        let text = status.map { "Yggdrasil answered HTTP \($0) without a reply." }
            ?? "Yggdrasil isn't running, or Settings → API is off."
        return line(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": text]])
    }

    private static func line(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(bytes: $0, encoding: .utf8) }
    }

    static func parseResponse(_ data: Data) throws -> (status: Int, body: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(bytes: data[data.startIndex ..< end.lowerBound], encoding: .utf8),
              let status = head.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
        else { throw UsageError.badJSON }
        return (status, Data(data[end.upperBound...]))
    }

    /// `value` as indented JSON. Empty lists and objects stay on one line;
    /// Foundation prints them over three. Only structural brackets can have
    /// a raw newline inside, so string values are left alone.
    static func render(_ value: Any) -> String {
        let options: JSONSerialization.WritingOptions = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options),
              let text = String(bytes: data, encoding: .utf8)
        else { return "null" }
        return text
            .replacingOccurrences(of: #"\[\n\s*\]"#, with: "[]", options: .regularExpression)
            .replacingOccurrences(of: #"\{\n\s*\}"#, with: "{}", options: .regularExpression)
    }

    static func exitCode(status: Int, hasError: Bool) -> Int32 {
        if status == 401 || status == 403 { return Exit.unauthorized }
        return hasError || status >= 400 ? Exit.failed : Exit.ok
    }
}
