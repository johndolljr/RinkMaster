import Foundation
import RinkMasterCore

// rinkmaster-mcp: the RinkMaster app's features as MCP tools, over stdio (newline-delimited JSON-RPC).
// It uses the app's own settings and caches, so it works whether or not the app is open. stdout carries only protocol
// messages; anything for humans goes to stderr.

setvbuf(stdout, nil, _IOLBF, 0)
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    FileHandle.standardError.write(Data("""
    rinkmaster-mcp - MCP server for RinkMaster (arcade cabinet inventory, games, scores)

    Speaks the Model Context Protocol on stdin/stdout. Register it with an agent, e.g.:
      claude mcp add rinkmaster -- ~/Applications/RinkMaster.app/Contents/MacOS/rinkmaster-mcp
    Options: --list-tools   print the tool names and exit

    """.utf8))
    exit(0)
}

let workspace = Workspace()
let server = MCPServer(name: "rinkmaster", version: "1.0.0", instructions: RinkMasterTools.instructions, tools: RinkMasterTools.make(workspace))

if CommandLine.arguments.contains("--list-tools") {
    if let out = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#), let v = try? JSONDecoder().decode(JSONValue.self, from: Data(out.utf8)) {
        for t in v["result"]?["tools"]?.arrayValue ?? [] { print(t["name"]?.stringValue ?? "?") }
    }
    exit(0)
}

// Requests are answered in order, one at a time; the model waits for each answer anyway.
while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { continue }
    if let response = await server.handle(line: trimmed) { print(response) }
}
