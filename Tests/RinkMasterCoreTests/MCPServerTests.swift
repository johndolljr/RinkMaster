import XCTest
@testable import RinkMasterCore

final class JSONValueTests: XCTestCase {
    func testRoundTripAndAccessors() throws {
        let v: JSONValue = ["a": 1, "b": ["x", true, nil], "c": 2.5]
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), v)
        XCTAssertEqual(v["a"]?.intValue, 1)
        XCTAssertEqual(v["c"]?.doubleValue, 2.5)
        XCTAssertEqual(v["b"]?.arrayValue?.count, 3)
        XCTAssertEqual(v["b"]?.arrayValue?[0].stringValue, "x")
        XCTAssertEqual(v["b"]?.arrayValue?[1].boolValue, true)
        XCTAssertNil(v["zzz"])
    }

    func testEncodingIsStableAndPrettyPrintable() throws {
        let v: JSONValue = ["b": 1, "a": ["z": 2]]
        XCTAssertEqual(v.compactString, #"{"a":{"z":2},"b":1}"#)
        XCTAssertTrue(v.prettyString.contains("\n"))
    }

    func testIntegersStayIntegers() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"n":3,"d":3.5}"#.utf8))
        XCTAssertEqual(v["n"], .int(3)); XCTAssertEqual(v["d"], .double(3.5))
    }
}

final class MCPArgumentsTests: XCTestCase {
    func testTypedReadersAndDefaults() throws {
        let a = MCPArguments(["name": "galaga", "n": 5, "flag": true, "list": ["a", "b"]])
        XCTAssertEqual(try a.string("name"), "galaga")
        XCTAssertEqual(a.optionalString("missing"), nil)
        XCTAssertEqual(a.int("n", default: 1), 5)
        XCTAssertEqual(a.int("missing", default: 7), 7)
        XCTAssertTrue(a.bool("flag", default: false))
        XCTAssertFalse(a.bool("missing", default: false))
        XCTAssertEqual(a.stringList("list"), ["a", "b"])
    }

    func testMissingOrWrongTypeRequiredArgumentsThrowAClearError() {
        XCTAssertThrowsError(try MCPArguments([:]).string("machine")) { XCTAssertEqual(($0 as? MCPError)?.message, "missing required argument 'machine'") }
        XCTAssertThrowsError(try MCPArguments(["machine": 5]).string("machine")) { XCTAssertEqual(($0 as? MCPError)?.message, "argument 'machine' must be a string") }
        XCTAssertThrowsError(try MCPArguments(["a": ""]).string("a")) { XCTAssertEqual(($0 as? MCPError)?.message, "missing required argument 'a'") }
    }

    func testNonObjectArgumentsAreEmpty() {
        XCTAssertEqual(MCPArguments(nil).optionalString("x"), nil)
        XCTAssertEqual(MCPArguments(.string("oops")).int("n", default: 3), 3)
    }
}

final class MCPServerTests: XCTestCase {
    private func server() -> MCPServer {
        MCPServer(name: "rinkmaster", version: "1.2.3", instructions: "Use me.", tools: [
            MCPTool(name: "echo", description: "Echoes text", properties: ["text": .string("what to say")], required: ["text"], readOnly: true) { args in
                .object(["said": .string(try args.string("text"))])
            },
            MCPTool(name: "boom", description: "Always fails", properties: [:], required: []) { _ in throw MCPError("kaboom") },
        ])
    }

    private func call(_ s: MCPServer, _ json: String) async throws -> JSONValue? {
        guard let out = await s.handle(line: json) else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: Data(out.utf8))
    }

    func testInitializeNegotiatesTheVersionAndDescribesTheServer() async throws {
        let r = try await call(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        XCTAssertEqual(r?["id"], .int(1))
        XCTAssertEqual(r?["result"]?["protocolVersion"]?.stringValue, "2025-03-26")
        XCTAssertEqual(r?["result"]?["serverInfo"]?["name"]?.stringValue, "rinkmaster")
        XCTAssertEqual(r?["result"]?["serverInfo"]?["version"]?.stringValue, "1.2.3")
        XCTAssertNotNil(r?["result"]?["capabilities"]?["tools"])
        XCTAssertEqual(r?["result"]?["instructions"]?.stringValue, "Use me.")
    }

    func testUnknownProtocolVersionFallsBackToTheLatestSupported() async throws {
        let r = try await call(server(), #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(r?["id"], .string("a"))
        XCTAssertEqual(r?["result"]?["protocolVersion"]?.stringValue, "2025-06-18")
    }

    func testNotificationsGetNoResponseAndPingIsEmpty() async throws {
        let n = try await call(server(), #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(n)
        let p = try await call(server(), #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        XCTAssertEqual(p?["result"], .object([:]))
    }

    func testToolsListDescribesInputsAndHints() async throws {
        let r = try await call(server(), #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let tools = try XCTUnwrap(r?["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, ["echo", "boom"])
        let echo = tools[0]
        XCTAssertEqual(echo["description"]?.stringValue, "Echoes text")
        XCTAssertEqual(echo["inputSchema"]?["type"]?.stringValue, "object")
        XCTAssertEqual(echo["inputSchema"]?["properties"]?["text"]?["type"]?.stringValue, "string")
        XCTAssertEqual(echo["inputSchema"]?["required"]?.arrayValue?.first?.stringValue, "text")
        XCTAssertEqual(echo["annotations"]?["readOnlyHint"]?.boolValue, true)
        XCTAssertEqual(tools[1]["annotations"]?["readOnlyHint"]?.boolValue, false)
    }

    func testCallReturnsTheResultAsJSONText() async throws {
        let r = try await call(server(), #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        XCTAssertEqual(r?["result"]?["isError"]?.boolValue, false)
        let text = try XCTUnwrap(r?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertEqual(r?["result"]?["content"]?.arrayValue?.first?["type"]?.stringValue, "text")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))["said"]?.stringValue, "hi")
    }

    func testToolFailuresAreReportedToTheModelNotAsProtocolErrors() async throws {
        let boom = try await call(server(), #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"boom"}}"#)
        XCTAssertNil(boom?["error"])
        XCTAssertEqual(boom?["result"]?["isError"]?.boolValue, true)
        XCTAssertEqual(boom?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "kaboom")
        let bad = try await call(server(), #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        XCTAssertEqual(bad?["result"]?["isError"]?.boolValue, true)
        XCTAssertEqual(bad?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "missing required argument 'text'")
    }

    func testProtocolErrors() async throws {
        let unknownTool = try await call(server(), #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"nope"}}"#)
        XCTAssertEqual(unknownTool?["error"]?["code"]?.intValue, -32602)
        let unknownMethod = try await call(server(), #"{"jsonrpc":"2.0","id":8,"method":"frobnicate"}"#)
        XCTAssertEqual(unknownMethod?["error"]?["code"]?.intValue, -32601)
        XCTAssertEqual(unknownMethod?["id"], .int(8))
        let garbage = try await call(server(), "this is not json")
        XCTAssertEqual(garbage?["error"]?["code"]?.intValue, -32700)
        XCTAssertEqual(garbage?["id"], .null)
        let noParams = try await call(server(), #"{"jsonrpc":"2.0","id":9,"method":"tools/call"}"#)
        XCTAssertEqual(noParams?["error"]?["code"]?.intValue, -32602)
    }

    func testResourcesAndPromptsAreEmptyRatherThanErrors() async throws {
        let r = try await call(server(), #"{"jsonrpc":"2.0","id":10,"method":"resources/list"}"#)
        XCTAssertEqual(r?["result"]?["resources"]?.arrayValue?.count, 0)
        let p = try await call(server(), #"{"jsonrpc":"2.0","id":11,"method":"prompts/list"}"#)
        XCTAssertEqual(p?["result"]?["prompts"]?.arrayValue?.count, 0)
    }

    func testOutputIsASingleLine() async throws {
        let out = await server().handle(line: #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"echo","arguments":{"text":"line1\nline2"}}}"#)
        XCTAssertFalse(try XCTUnwrap(out).contains("\n"), "stdio transport is newline-delimited")
    }
}
