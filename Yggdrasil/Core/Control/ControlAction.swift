import Foundation

/// One thing the control API can do: a JSON-RPC method, an MCP tool and a
/// `yggctl` command at once.
struct ControlAction {
    struct Param {
        enum Kind: String {
            case string, integer, boolean
            case strings = "array"
            /// String values only, like an agent's environment.
            case dictionary = "object"
        }

        let name: String
        let kind: Kind
        let summary: String
        let required: Bool
        let choices: [String]?

        init(_ name: String, _ kind: Kind, _ summary: String, required: Bool = true, choices: [String]? = nil) {
            self.name = name
            self.kind = kind
            self.summary = summary
            self.required = required
            self.choices = choices
        }
    }

    struct Context {
        let services: AppServices
        let key: APIKey?
    }

    typealias Run = @MainActor (ActionParams, Context) async throws -> JSONValue

    let name: String
    let summary: String
    let scope: APIKey.Scope
    let params: [Param]
    let run: Run

    /// MCP tool names can't have dots.
    var toolName: String {
        name.replacingOccurrences(of: ".", with: "_")
    }

    var inputSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for param in params {
            var schema: [String: JSONValue] = [
                "type": .string(param.kind.rawValue), "description": .string(param.summary)
            ]
            if param.kind == .strings { schema["items"] = .object(["type": .string("string")]) }
            if param.kind == .dictionary { schema["additionalProperties"] = .object(["type": .string("string")]) }
            if let choices = param.choices { schema["enum"] = .array(choices.map(JSONValue.string)) }
            properties[param.name] = .object(schema)
        }
        var schema: [String: JSONValue] = [
            "type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false)
        ]
        let required = params.filter(\.required).map { JSONValue.string($0.name) }
        if !required.isEmpty { schema["required"] = .array(required) }
        return .object(schema)
    }

    /// Checks `raw` against the declared params before the action runs.
    func validate(_ raw: [String: JSONValue]) throws -> ActionParams {
        for param in params {
            guard let value = raw[param.name], value != .null else {
                if param.required { throw ActionError.invalidArgument(param.name) }
                continue
            }
            let fits = switch param.kind {
            case .string: value.stringValue.map { param.choices?.contains($0) ?? true } ?? false
            case .integer: value.intValue != nil
            case .boolean: value.boolValue != nil
            case .strings:
                if case let .array(items) = value { items.allSatisfy { $0.stringValue != nil } } else { false }
            case .dictionary:
                if case let .object(fields) = value {
                    fields.values.allSatisfy { $0.stringValue != nil }
                } else {
                    false
                }
            }
            guard fits else { throw ActionError.invalidArgument(param.name) }
        }
        if let unknown = raw.keys.first(where: { key in !params.contains { $0.name == key } }) {
            throw ActionError.invalidArgument(unknown)
        }
        return ActionParams(values: raw)
    }
}

/// An action's validated arguments.
struct ActionParams {
    let values: [String: JSONValue]

    func string(_ name: String) throws -> String {
        guard let value = values[name]?.stringValue else { throw ActionError.invalidArgument(name) }
        return value
    }

    func optionalString(_ name: String) -> String? {
        values[name]?.stringValue
    }

    func int(_ name: String) throws -> Int64 {
        guard let value = values[name]?.intValue else { throw ActionError.invalidArgument(name) }
        return value
    }

    func optionalInt(_ name: String) -> Int64? {
        values[name]?.intValue
    }

    func bool(_ name: String, default fallback: Bool) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    func optionalBool(_ name: String) -> Bool? {
        values[name]?.boolValue
    }

    func strings(_ name: String) -> [String]? {
        guard case let .array(items)? = values[name] else { return nil }
        return items.compactMap(\.stringValue)
    }

    func dictionary(_ name: String) -> [String: String]? {
        guard case let .object(fields)? = values[name] else { return nil }
        return fields.compactMapValues(\.stringValue)
    }
}

extension ActionError {
    /// Stable, for programs to branch on.
    var reason: String {
        switch self {
        case .unknownTab: "unknown_tab"
        case .unknownRepo: "unknown_repo"
        case .unknownAgent: "unknown_agent"
        case .unknownHost: "unknown_host"
        case .repoNotCloned: "repo_not_cloned"
        case .notInTrackedRepo: "not_in_tracked_repo"
        case .repoNotTracked: "repo_not_tracked"
        case .noStatusYet: "no_status_yet"
        case .tabNotReady: "tab_not_ready"
        case .cannotRemoveDefaultAgent: "cannot_remove_default_agent"
        case .folderExists: "folder_exists"
        case .moveInProgress: "move_in_progress"
        case .notRunning: "not_running"
        case .agentPaneHidden: "agent_pane_hidden"
        case .noMainWindow: "no_main_window"
        case .promptNeedsClaude: "prompt_needs_claude"
        case .invalidArgument: "invalid_argument"
        }
    }
}
