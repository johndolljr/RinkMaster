import Foundation

/// Any JSON value, for the MCP wire format and tool results.
public enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? { switch self { case .int(let i): return i; case .double(let d): return Int(exactly: d); default: return nil } }
    public var doubleValue: Double? { switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    private func encoded(_ formatting: JSONEncoder.OutputFormatting) -> String {
        let e = JSONEncoder()
        e.outputFormatting = formatting.union([.sortedKeys, .withoutEscapingSlashes])
        return (try? String(decoding: e.encode(self), as: UTF8.self)) ?? "null"
    }
    public var compactString: String { encoded([]) }
    public var prettyString: String { encoded([.prettyPrinted]) }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b })) }
    public init(nilLiteral: ()) { self = .null }
}

/// A tool failure that is reported to the model as the tool's result (not as a protocol error).
public struct MCPError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// The arguments of one tool call, with typed readers that give the model a clear message when something is missing.
public struct MCPArguments: Sendable {
    private let object: [String: JSONValue]

    public init(_ value: JSONValue?) {
        if case .object(let o)? = value { object = o } else { object = [:] }
    }

    public func string(_ key: String) throws -> String {
        guard let v = object[key], v != .null else { throw MCPError("missing required argument '\(key)'") }
        guard let s = v.stringValue else { throw MCPError("argument '\(key)' must be a string") }
        guard !s.isEmpty else { throw MCPError("missing required argument '\(key)'") }
        return s
    }

    public func optionalString(_ key: String) -> String? {
        guard let s = object[key]?.stringValue, !s.isEmpty else { return nil }
        return s
    }

    public func int(_ key: String, default value: Int) -> Int { object[key]?.intValue ?? value }
    public func bool(_ key: String, default value: Bool) -> Bool { object[key]?.boolValue ?? value }
    public func stringList(_ key: String) -> [String] { object[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    public func has(_ key: String) -> Bool { object[key] != nil && object[key] != JSONValue.null }
}

/// One property in a tool's input schema.
public struct MCPProperty: Sendable {
    let schema: JSONValue
    private init(_ type: String, _ description: String, extra: [String: JSONValue] = [:]) {
        var s: [String: JSONValue] = ["type": .string(type), "description": .string(description)]
        for (k, v) in extra { s[k] = v }
        schema = .object(s)
    }
    public static func string(_ description: String) -> MCPProperty { MCPProperty("string", description) }
    public static func integer(_ description: String) -> MCPProperty { MCPProperty("integer", description) }
    public static func boolean(_ description: String) -> MCPProperty { MCPProperty("boolean", description) }
    public static func stringArray(_ description: String) -> MCPProperty { MCPProperty("array", description, extra: ["items": ["type": "string"]]) }
    public static func choice(_ description: String, _ values: [String]) -> MCPProperty {
        MCPProperty("string", description, extra: ["enum": .array(values.map { .string($0) })])
    }
}

public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    let properties: [String: MCPProperty]
    let required: [String]
    let readOnly: Bool
    let destructive: Bool
    let handler: @Sendable (MCPArguments) async throws -> JSONValue

    public init(name: String, description: String, properties: [String: MCPProperty], required: [String], readOnly: Bool = false,
                destructive: Bool = false, handler: @escaping @Sendable (MCPArguments) async throws -> JSONValue) {
        self.name = name; self.description = description; self.properties = properties; self.required = required
        self.readOnly = readOnly; self.destructive = destructive; self.handler = handler
    }

    var descriptor: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object(["type": "object", "properties": .object(properties.mapValues(\.schema)), "required": .array(required.map { .string($0) })]),
            "annotations": .object(["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive)]),
        ])
    }
}

/// A Model Context Protocol server over newline-delimited JSON-RPC (the stdio transport): initialize, ping, tools/list, tools/call.
public struct MCPServer: Sendable {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let name: String
    public let version: String
    public let instructions: String
    public let tools: [MCPTool]

    public init(name: String, version: String, instructions: String, tools: [MCPTool]) {
        self.name = name; self.version = version; self.instructions = instructions; self.tools = tools
    }

    /// One request line in, one response line out; nil for notifications (which get no answer).
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8), let request = try? JSONDecoder().decode(JSONValue.self, from: data), request["method"] != nil || request["id"] != nil else {
            return reply(id: .null, error: -32700, "parse error")
        }
        guard let method = request["method"]?.stringValue else { return nil }  // a response to us: ignore
        guard let id = request["id"] else { return nil }  // notification
        return await dispatch(method: method, params: request["params"], id: id)
    }

    private func dispatch(method: String, params: JSONValue?, id: JSONValue) async -> String? {
        switch method {
        case "initialize":
            let asked = params?["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0]
            return reply(id: id, result: .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(name), "version": .string(self.version)]),
                "instructions": .string(instructions),
            ]))
        case "ping": return reply(id: id, result: .object([:]))
        case "tools/list": return reply(id: id, result: .object(["tools": .array(tools.map(\.descriptor))]))
        case "resources/list": return reply(id: id, result: .object(["resources": .array([])]))
        case "prompts/list": return reply(id: id, result: .object(["prompts": .array([])]))
        case "tools/call":
            guard let toolName = params?["name"]?.stringValue, let tool = tools.first(where: { $0.name == toolName }) else {
                return reply(id: id, error: -32602, "unknown tool '\(params?["name"]?.stringValue ?? "")'")
            }
            do {
                let result = try await tool.handler(MCPArguments(params?["arguments"]))
                return reply(id: id, result: toolResult(result.stringValue ?? result.prettyString, isError: false))
            } catch let e as MCPError {
                return reply(id: id, result: toolResult(e.message, isError: true))
            } catch {
                return reply(id: id, result: toolResult("\(error)", isError: true))
            }
        default:
            return reply(id: id, error: -32601, "method not found: \(method)")
        }
    }

    private func toolResult(_ text: String, isError: Bool) -> JSONValue {
        .object(["content": .array([.object(["type": "text", "text": .string(text)])]), "isError": .bool(isError)])
    }

    private func reply(id: JSONValue, result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).compactString
    }

    private func reply(id: JSONValue, error code: Int, _ message: String) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "error": .object(["code": .int(code), "message": .string(message)])]).compactString
    }
}
