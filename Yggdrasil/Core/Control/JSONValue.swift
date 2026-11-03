import Foundation

/// Any JSON value, for the control API's requests and results.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            // Whole numbers as integers: ids and counts read better that way.
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    static func int(_ value: some BinaryInteger) -> JSONValue {
        .number(Double(value))
    }

    /// `.null` for nil.
    static func optional(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }

    static func optional(_ value: Int64?) -> JSONValue {
        value.map { .int($0) } ?? .null
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// Nil for fractions and for numbers no Int64 holds.
    var intValue: Int64? {
        if case let .number(value) = self { return Int64(exactly: value) }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    enum DecodeError: Error {
        case tooDeep
        case invalid
    }

    static let maxDepth = 64

    /// Parses a request body. Nesting beyond `maxDepth` is refused before
    /// parsing, so a pathological body costs a scan, not a deep parse.
    static func decode(_ data: Data) throws -> JSONValue {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > maxDepth { throw DecodeError.tooDeep }
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            default: break
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            throw DecodeError.invalid
        }
        return JSONValue(any: object)
    }

    private init(any value: Any) {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    var jsonText: String {
        String(bytes: encoded(), encoding: .utf8) ?? "null"
    }
}
