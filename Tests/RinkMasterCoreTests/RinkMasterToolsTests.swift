import XCTest
@testable import RinkMasterCore

/// Routes cabinet service requests for the tool tests and remembers what was asked.
final class FakeCabinets: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var requests: [String] { lock.withLock { log } }
    let shell = RecordingShell()
    var emulatorsInstalled = true

    func install() {
        StubURLProtocol.handler = { [self] req in
            let url = req.url!
            lock.withLock { log.append("\(req.httpMethod ?? "GET") \(url.host ?? "")\(url.path)\(url.query.map { "?\($0)" } ?? "")") }
            let host = url.host ?? ""
            let body: String
            switch (req.httpMethod ?? "GET", url.path) {
            case ("GET", "/v1/inventory"):
                body = host == "a2.lan" ? #"{"machine":"arcade2","totalGames":2,"systems":[{"name":"mame-libretro","defaultEmulator":"lr-mame2010","emulators":["lr-mame2010"],"games":[{"system":"mame-libretro","name":"galaga","file":"galaga.zip","emulator":"lr-mame2010","isPinned":false,"size":1,"mtime":1},{"system":"mame-libretro","name":"pacman","file":"pacman.zip","emulator":"lr-mame2003","isPinned":true,"size":1,"mtime":1}]}]}"#
                    : #"{"machine":"xarcade","totalGames":1,"systems":[{"name":"mame-libretro","defaultEmulator":"lr-mame2016","emulators":["lr-mame2016"],"games":[{"system":"mame-libretro","name":"galaga","file":"galaga.zip","emulator":"lr-mame2016","isPinned":false,"size":1,"mtime":1}]}]}"#
            case ("GET", "/v1/emulators"):
                body = #"{"machine":"x","systems":[{"name":"mame-libretro","defaultEmulator":"lr-mame2010","hasInstalledEmulator":\#(emulatorsInstalled),"emulators":[{"id":"lr-mame2003","installed":\#(emulatorsInstalled),"command":"a"},{"id":"lr-mame2010","installed":\#(emulatorsInstalled),"command":"b"}]},{"name":"atari2600","defaultEmulator":"lr-stella2014","hasInstalledEmulator":\#(emulatorsInstalled),"emulators":[{"id":"lr-stella2014","installed":\#(emulatorsInstalled),"command":"c"}]}]}"#
            case ("POST", "/v1/frontend/refresh"): body = #"{"frontend":"attract-mode","refreshed":["Multiple Arcade Machine Emulator"],"errors":[]}"#
            case ("POST", "/v1/emulators/default"):
                body = #"{"system":"mame-libretro","emulator":"lr-mame2003","previous":"lr-mame2010","changed":true,"dryRun":\#(url.query?.contains("dryRun=1") == true),"file":"/opt/retropie/configs/mame-libretro/emulators.cfg","backup":null,"machine":"x"}"#
            case ("POST", "/v1/emulators/pin"):
                body = #"{"system":"mame-libretro","game":"galaga","key":"mame-libretro_galaga","emulator":null,"previous":"lr-mame2003","changed":true,"dryRun":false,"file":"/f","backup":"/f.bak","machine":"x"}"#
            case ("POST", "/v1/gamelist"): body = #"{"added":1,"updated":1,"changed":true,"file":"/f"}"#
            case ("POST", "/v1/frontend/restart"):
                if url.query?.contains("force=1") != true && host == "x.lan" { return (HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil)!, Data(#"{"error":"busy"}"#.utf8)) }
                body = #"{"frontend":"emulationstation","restarted":true,"refreshed":[],"errors":[],"message":"restarting"}"#
            case ("POST", "/v1/refresh"): body = #"{"totalGames":2,"etag":"e"}"#
            case ("DELETE", _):
                let dry = url.query?.contains("dryRun=1") == true
                body = dry ? #"{"dryRun":true,"name":"galaga","pin":false,"remove":["mame-libretro/galaga.zip","mame-libretro/snap/galaga.png"],"system":"mame-libretro"}"#
                    : #"{"dryRun":false,"name":"galaga","pin":false,"remove":["mame-libretro/galaga.zip"],"removed":["mame-libretro/galaga.zip"],"frontend":{"frontend":"attract-mode","refreshed":["X"],"errors":[]},"system":"mame-libretro"}"#
            case ("GET", "/v1/scores"):
                body = host == "a2.lan" ? #"{"files":[{"core":"c","kind":"hi","game":"galaga","size":1,"mtime":5,"md5":"a1"}]}"# : #"{"files":[{"core":"c","kind":"hi","game":"galaga","size":1,"mtime":5,"md5":"x1"}]}"#
            case ("GET", "/v1/scores/file"): body = host == "a2.lan" ? "BIG" : "SMALL"
            case ("PUT", "/v1/scores/file"): body = #"{"written":true,"backup":"galaga.hi.bak-1","size":3}"#
            case ("GET", "/health"): body = #"{"ok":true,"version":"0.1.0","machine":"x"}"#
            case ("GET", "/v1/theme"):
                body = #"{"frontend":"emulationstation","activeTheme":"dll-arcade","installedThemes":["carbon","dll-arcade"],"themesDir":"/opt/themes","machine":"x"}"#
            case ("POST", "/v1/theme/install"):
                body = #"{"frontend":"emulationstation","theme":"dll-arcade","destDir":"/opt/themes/dll-arcade","files":["theme.xml"],"activated":true,"machine":"x"}"#
            case ("POST", "/v1/theme/activate"):
                body = #"{"frontend":"emulationstation","theme":"dll-arcade","activeTheme":"dll-arcade","changed":true,"machine":"x"}"#
            default: return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }
}

/// Decodes "BIG" as 900 and anything else as 100, so the sync direction is predictable.
struct SizeDecoder: ScoreDecoder {
    func decode(game: String, data: Data) async throws -> ScoreTable {
        ScoreTable(columns: ["RANK", "SCORE", "NAME"], rows: [["1", String(String(decoding: data, as: UTF8.self) == "BIG" ? 900 : 100), "JON"]])
    }
}

final class RinkMasterToolsTests: XCTestCase {
    private var dir: URL!
    private var master: URL!
    private let cabinets = FakeCabinets()
    private var server: MCPServer!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rm-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        master = try makeMasterTree([
            "roms/sets/0.172/galaga.zip", "roms/sets/0.172/namco51.zip", "roms/sets/0.172/namco54.zip", "roms/sets/0.172/pacman.zip",
            "roms/sets/0.172/puckman.zip", "roms/sets/0.172/neogeo.zip", "roms/sets/0.172/mslug.zip",
            "artwork/best/snap/galaga.png", "artwork/best/wheel/galaga.png", "data/mame2016.xml", "data/history.dat",
        ])
        try Data(sampleHistory.utf8).write(to: master.appendingPathComponent("data/history.dat"))
        let settings = AppSettings(machines: [
            Machine(name: "arcade2", user: "pi", host: "a2.lan", frontend: .attractMode),
            Machine(name: "xarcade", user: "pi", host: "x.lan", frontend: .emulationStation),
        ], masterPath: master.path)
        try MachineStore.save(settings, to: dir.appendingPathComponent("settings.json"))
        cabinets.install()
        server = makeServer(shell: cabinets.shell)
    }

    private func makeServer(shell: RemoteShell) -> MCPServer {
        let workspace = Workspace(
            paths: .init(settings: dir.appendingPathComponent("settings.json"), catalogCache: dir.appendingPathComponent("catalog.json"), scoreCache: dir.appendingPathComponent("scores.json")),
            hooks: .init(service: { ServiceClient(host: $0.host, port: $0.servicePort, session: StubURLProtocol.session) }, shell: { _ in shell },
                         decoder: { _ in SizeDecoder() }, loadDatabase: { _ in try MameDatabase.parse(Data(sampleMameXML.utf8)) }))
        return MCPServer(name: "rinkmaster", version: "test", instructions: "", tools: RinkMasterTools.make(workspace))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: master) }

    /// Calls a tool and returns (isError, parsed JSON result or the error text).
    private func call(_ name: String, _ args: JSONValue = [:]) async throws -> (error: Bool, json: JSONValue, text: String) {
        let req = JSONValue.object(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": .object(["name": .string(name), "arguments": args])]).compactString
        let raw = await server.handle(line: req)
        let out = try XCTUnwrap(raw)
        let r = try JSONDecoder().decode(JSONValue.self, from: Data(out.utf8))
        let text = try XCTUnwrap(r["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let json = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
        return (r["result"]?["isError"]?.boolValue ?? true, json, text)
    }

    func testEveryAppFeatureHasATool() async throws {
        let raw = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let r = try XCTUnwrap(raw)
        let names = Set(try JSONDecoder().decode(JSONValue.self, from: Data(r.utf8))["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
        let expected: Set<String> = ["overview", "list_machines", "test_connection", "get_inventory", "list_emulators", "refresh_inventory", "refresh_frontend", "restart_frontend", "repair_roms", "sync_game_list", "set_default_emulator", "pin_game_emulator",
            "install_theme", "theme_status",
            "search_games", "get_game", "random_game", "catalog_facets", "refresh_catalog", "master_status", "add_game", "remove_game",
            "get_scores", "refresh_scores", "player_rankings", "plan_score_sync", "apply_score_sync",
            "add_machine", "update_machine", "remove_machine", "set_master_path", "set_branding"]
        XCTAssertEqual(names, expected)
    }

    func testListMachines() async throws {
        let r = try await call("list_machines")
        XCTAssertFalse(r.error)
        XCTAssertEqual(r.json["machines"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["arcade2", "xarcade"])
        XCTAssertEqual(r.json["machines"]?.arrayValue?[0]["host"]?.stringValue, "a2.lan")
        XCTAssertEqual(r.json["master"]?.stringValue, master.path)
    }

    func testOverviewSummarisesEveryCabinetAndTheMaster() async throws {
        let r = try await call("overview")
        XCTAssertFalse(r.error)
        let machines = try XCTUnwrap(r.json["machines"]?.arrayValue)
        XCTAssertEqual(machines.count, 2)
        let a2 = machines[0]
        XCTAssertEqual(a2["name"]?.stringValue, "arcade2")
        XCTAssertEqual(a2["reachable"]?.boolValue, true)
        XCTAssertEqual(a2["totalGames"]?.intValue, 2)
        XCTAssertEqual(a2["systems"]?.arrayValue?[0]["emulators"]?["lr-mame2003"]?.intValue, 1)
        XCTAssertEqual(r.json["master"]?["mounted"]?.boolValue, true)
        XCTAssertEqual(r.json["master"]?["games"]?.intValue, 4)  // galaga, mslug, pacman, puckman
    }

    func testOverviewReportsAnUnreachableCabinetInsteadOfFailing() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        struct DownShell: RemoteShell {
            func run(_ command: String) async throws -> CommandResult { throw RemoteError.commandFailed(status: 255, stderr: "ssh: connect to host a2.lan port 22: Host is down") }
            func fetch(remotePath: String, to localPath: String) async throws -> CommandResult { throw RemoteError.commandFailed(status: 255, stderr: "down") }
            func push(localPath: String, toRemotePath remotePath: String) async throws -> CommandResult { throw RemoteError.commandFailed(status: 255, stderr: "down") }
        }
        server = makeServer(shell: DownShell())
        let r = try await call("overview")
        XCTAssertFalse(r.error)
        XCTAssertEqual(r.json["machines"]?.arrayValue?[0]["reachable"]?.boolValue, false)
        XCTAssertNotNil(r.json["machines"]?.arrayValue?[0]["error"]?.stringValue)
    }

    func testGetInventoryListsGamesWithTitlesAndFilters() async throws {
        let r = try await call("get_inventory", ["machine": "ARCADE2"])  // names are case-insensitive
        XCTAssertEqual(r.json["total"]?.intValue, 2)
        let games = try XCTUnwrap(r.json["games"]?.arrayValue)
        XCTAssertEqual(games.map { $0["name"]?.stringValue }, ["galaga", "pacman"])
        XCTAssertEqual(games[0]["title"]?.stringValue, "Galaga (Namco rev. B)")
        XCTAssertEqual(games[1]["pinned"]?.boolValue, true)
        let filtered = try await call("get_inventory", ["machine": "arcade2", "search": "pac"])
        XCTAssertEqual(filtered.json["games"]?.arrayValue?.count, 1)
        let limited = try await call("get_inventory", ["machine": "arcade2", "limit": 1])
        XCTAssertEqual(limited.json["games"]?.arrayValue?.count, 1)
        XCTAssertEqual(limited.json["total"]?.intValue, 2)
        let bad = try await call("get_inventory", ["machine": "nope"])
        XCTAssertTrue(bad.error); XCTAssertEqual(bad.text, "unknown machine 'nope'; known machines: arcade2, xarcade")
    }

    func testSearchGamesFiltersPagesAndReportsWhereGamesAre() async throws {
        let all = try await call("search_games")
        XCTAssertEqual(all.json["total"]?.intValue, 4)
        let q = try await call("search_games", ["text": "pac", "installed": "arcade2"])
        XCTAssertEqual(q.json["games"]?.arrayValue?.map { $0["name"]?.stringValue }, ["pacman"])
        XCTAssertEqual(q.json["games"]?.arrayValue?[0]["installedOn"]?.arrayValue?.compactMap(\.stringValue), ["arcade2"])
        let missing = try await call("search_games", ["installed": "none"])
        XCTAssertEqual(missing.json["games"]?.arrayValue?.map { $0["name"]?.stringValue }, ["mslug", "puckman"])
        let paged = try await call("search_games", ["page": 2, "page_size": 3])
        XCTAssertEqual(paged.json["pageCount"]?.intValue, 2)
        XCTAssertEqual(paged.json["games"]?.arrayValue?.count, 1)
        let decade = try await call("search_games", ["decade": 1990])
        XCTAssertEqual(decade.json["games"]?.arrayValue?.map { $0["name"]?.stringValue }, ["mslug"])
        let clones = try await call("search_games", ["hide_clones": true])
        XCTAssertEqual(clones.json["total"]?.intValue, 3)
        let badFilter = try await call("search_games", ["installed": "nowhere"])
        XCTAssertTrue(badFilter.error)
    }

    func testSearchAndFacetsKnowTheSystems() async throws {
        for rel in ["roms/other-systems/atari2600/Pitfall.bin", "roms/other-systems/daphne/ace.daphne/a.txt"] {
            let url = master.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        _ = try await call("refresh_catalog")
        let atari = try await call("search_games", ["system": "atari2600"])
        XCTAssertEqual(atari.json["total"]?.intValue, 1)
        let game = try XCTUnwrap(atari.json["games"]?.arrayValue?.first)
        XCTAssertEqual(game["name"]?.stringValue, "Pitfall"); XCTAssertEqual(game["system"]?.stringValue, "atari2600")
        XCTAssertEqual(game["sourcePath"]?.stringValue, "roms/other-systems/atari2600/Pitfall.bin")
        let mame = try await call("search_games", ["system": "mame"])
        XCTAssertEqual(mame.json["total"]?.intValue, 4)
        XCTAssertEqual(mame.json["games"]?.arrayValue?.first?["system"]?.stringValue, "mame")
        XCTAssertEqual(mame.json["games"]?.arrayValue?.first?["sourcePath"], JSONValue.null)
        let random = try await call("random_game", ["system": "daphne"])
        XCTAssertEqual(random.json["name"]?.stringValue, "ace")
        let f = try await call("catalog_facets")
        XCTAssertEqual(f.json["total"]?.intValue, 6)
        XCTAssertEqual(f.json["systems"]?.arrayValue?.map { "\($0["name"]?.stringValue ?? ""):\($0["count"]?.intValue ?? -1)" }, ["mame:4", "atari2600:1", "daphne:1"])
        let detail = try await call("get_game", ["game": "atari2600/Pitfall"])
        XCTAssertEqual(detail.json["system"]?.stringValue, "atari2600")
    }

    func testGetGameReturnsDetailsArtHistoryLocationsAndScores() async throws {
        _ = try await call("refresh_scores")
        let r = try await call("get_game", ["game": "galaga"])
        XCTAssertFalse(r.error)
        XCTAssertEqual(r.json["title"]?.stringValue, "Galaga (Namco rev. B)")
        XCTAssertEqual(r.json["romSets"]?.arrayValue?.compactMap(\.stringValue), ["galaga", "namco51", "namco54"])
        XCTAssertTrue(r.json["art"]?["snap"]?.stringValue?.hasSuffix("artwork/best/snap/galaga.png") == true)
        XCTAssertTrue(r.json["history"]?.stringValue?.contains("Galaga is a shoot-em-up") == true)
        XCTAssertEqual(r.json["installedOn"]?.arrayValue?.compactMap { $0["machine"]?.stringValue }, ["arcade2", "xarcade"])
        XCTAssertEqual(r.json["scores"]?.arrayValue?.count, 2)
        XCTAssertEqual(r.json["scores"]?.arrayValue?[0]["table"]?["rows"]?.arrayValue?[0].arrayValue?[1].stringValue, "900")
        let missing = try await call("get_game", ["game": "zzz"])
        XCTAssertTrue(missing.error); XCTAssertEqual(missing.text, "no game named 'zzz' in the master catalog")
    }

    func testRandomGameAndFacets() async throws {
        let pick = try await call("random_game", ["maker": "Namco"])
        XCTAssertTrue(["galaga", "pacman", "puckman"].contains(pick.json["name"]?.stringValue ?? ""))
        let none = try await call("random_game", ["text": "zzz"])
        XCTAssertTrue(none.error)
        let f = try await call("catalog_facets")
        XCTAssertEqual(f.json["total"]?.intValue, 4)
        XCTAssertEqual(f.json["decades"]?.arrayValue?.first?["decade"]?.intValue, 1980)
        XCTAssertEqual(f.json["makers"]?.arrayValue?.first?["name"]?.stringValue, "Namco")
        XCTAssertTrue(f.json["letters"]?.arrayValue?.contains(.string("G")) == true)
    }

    func testAddGameDryRunPlansWithoutCopying() async throws {
        let r = try await call("add_game", ["machine": "arcade2", "game": "galaga", "dry_run": true])
        XCTAssertFalse(r.error)
        XCTAssertEqual(r.json["dryRun"]?.boolValue, true)
        XCTAssertEqual(r.json["plan"]?["romSets"]?.arrayValue?.count, 3)
        XCTAssertEqual(r.json["plan"]?["emulator"]?.stringValue, "lr-mame2010")
        XCTAssertTrue(cabinets.shell.pushes.isEmpty)
    }

    func testAddGameCopiesAndRefreshes() async throws {
        let r = try await call("add_game", ["machine": "arcade2", "game": "galaga", "emulator": "lr-mame2003"])
        XCTAssertFalse(r.error)
        XCTAssertEqual(r.json["added"]?.boolValue, true)
        XCTAssertEqual(r.json["emulator"]?.stringValue, "lr-mame2003")
        XCTAssertEqual(cabinets.shell.pushes.filter { $0.remote.hasSuffix("/mame-libretro/") }.count, 3)
        XCTAssertTrue(cabinets.requests.contains("POST a2.lan/v1/frontend/refresh?system=mame-libretro"))
    }

    func testAddGameIsRefusedWithAClearReasonWhenThereIsNoEmulator() async throws {
        cabinets.emulatorsInstalled = false
        let r = try await call("add_game", ["machine": "arcade2", "game": "galaga"])
        XCTAssertTrue(r.error)
        XCTAssertEqual(r.text, "arcade2 has no emulator installed for mame-libretro")
        XCTAssertTrue(cabinets.shell.pushes.isEmpty)
        let unknown = try await call("add_game", ["machine": "arcade2", "game": "nosuchgame"])
        XCTAssertTrue(unknown.error); XCTAssertEqual(unknown.text, "no game named 'nosuchgame' in the master catalog")
    }

    func testRemoveGameIsADryRunUnlessToldOtherwise() async throws {
        let r = try await call("remove_game", ["machine": "arcade2", "game": "galaga"])
        XCTAssertFalse(r.error)
        XCTAssertEqual(r.json["dryRun"]?.boolValue, true)
        XCTAssertEqual(r.json["wouldRemove"]?.arrayValue?.count, 2)
        XCTAssertFalse(cabinets.requests.contains { $0.hasPrefix("DELETE") && !$0.contains("dryRun=1") })
    }

    func testRemoveGameForRealWhenAsked() async throws {
        let r = try await call("remove_game", ["machine": "arcade2", "game": "galaga", "dry_run": false, "remove_art": true])
        XCTAssertEqual(r.json["dryRun"]?.boolValue, false)
        XCTAssertEqual(r.json["removed"]?.arrayValue?.compactMap(\.stringValue), ["mame-libretro/galaga.zip"])
        XCTAssertTrue(cabinets.requests.contains("DELETE a2.lan/v1/games/mame-libretro/galaga?withArt=1"))
    }

    func testRemoveGameNeedsToBeInstalled() async throws {
        let r = try await call("remove_game", ["machine": "xarcade", "game": "pacman"])
        XCTAssertTrue(r.error); XCTAssertEqual(r.text, "'pacman' is not installed on xarcade")
    }

    func testScoresRankingsAndSync() async throws {
        let refreshed = try await call("refresh_scores")
        XCTAssertEqual(refreshed.json["files"]?.intValue, 2)
        let scores = try await call("get_scores", ["game": "galaga", "machine": "xarcade"])
        XCTAssertEqual(scores.json["scores"]?.arrayValue?.count, 1)
        let players = try await call("player_rankings")
        XCTAssertEqual(players.json["players"]?.arrayValue?.first?["name"]?.stringValue, "JON")
        XCTAssertEqual(players.json["players"]?.arrayValue?.first?["points"]?.intValue, 10)
        let plan = try await call("plan_score_sync")
        XCTAssertEqual(plan.json["writes"]?.arrayValue?.count, 1)
        XCTAssertEqual(plan.json["writes"]?.arrayValue?[0]["from"]?.stringValue, "arcade2")
        XCTAssertEqual(plan.json["writes"]?.arrayValue?[0]["to"]?.stringValue, "xarcade")
        XCTAssertFalse(cabinets.requests.contains { $0.hasPrefix("PUT") })
    }

    func testApplyingTheSyncNeedsExplicitConfirmation() async throws {
        _ = try await call("refresh_scores")
        let refused = try await call("apply_score_sync")
        XCTAssertTrue(refused.error)
        XCTAssertTrue(refused.text.contains("confirm"))
        XCTAssertFalse(cabinets.requests.contains { $0.hasPrefix("PUT") })
        let done = try await call("apply_score_sync", ["confirm": true])
        XCTAssertFalse(done.error)
        XCTAssertEqual(done.json["synced"]?.intValue, 1)
        XCTAssertTrue(cabinets.requests.contains("PUT x.lan/v1/scores/file?core=c&kind=hi&game=galaga"))
    }

    func testRefreshToolsTalkToTheCabinet() async throws {
        _ = try await call("refresh_inventory", ["machine": "arcade2"])
        XCTAssertTrue(cabinets.requests.contains("POST a2.lan/v1/refresh"))
        let fe = try await call("refresh_frontend", ["machine": "arcade2"])
        XCTAssertEqual(fe.json["refreshed"]?.arrayValue?.first?.stringValue, "Multiple Arcade Machine Emulator")
        let em = try await call("list_emulators", ["machine": "arcade2", "system": "mame-libretro"])
        XCTAssertEqual(em.json["installed"]?.arrayValue?.compactMap(\.stringValue), ["lr-mame2003", "lr-mame2010"])
        XCTAssertEqual(em.json["canAdd"]?.boolValue, true)
        let conn = try await call("test_connection", ["machine": "arcade2"])
        XCTAssertEqual(conn.json["service"]?["ok"]?.boolValue, true)
    }

    func testEmulatorManagementTools() async throws {
        let dry = try await call("set_default_emulator", ["machine": "arcade2", "system": "mame-libretro", "emulator": "lr-mame2003"])
        XCTAssertFalse(dry.error)
        XCTAssertEqual(dry.json["dryRun"]?.boolValue, true)  // dry run unless told otherwise
        XCTAssertEqual(dry.json["previous"]?.stringValue, "lr-mame2010")
        XCTAssertTrue(cabinets.requests.contains("POST a2.lan/v1/emulators/default?dryRun=1"))
        let real = try await call("set_default_emulator", ["machine": "arcade2", "system": "mame-libretro", "emulator": "lr-mame2003", "dry_run": false])
        XCTAssertEqual(real.json["dryRun"]?.boolValue, false)
        XCTAssertTrue(cabinets.requests.contains("POST a2.lan/v1/emulators/default"))
        let clear = try await call("pin_game_emulator", ["machine": "arcade2", "system": "mame-libretro", "game": "galaga", "dry_run": false])
        XCTAssertFalse(clear.error)
        XCTAssertEqual(clear.json["game"]?.stringValue, "galaga")
        XCTAssertEqual(clear.json["emulator"], JSONValue.null)
        XCTAssertEqual(clear.json["backup"]?.stringValue, "/f.bak")
    }

    func testAddAnAtariGameCopiesTheFileToItsOwnSystem() async throws {
        let url = master.appendingPathComponent("roms/other-systems/atari2600/Pitfall.bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        _ = try await call("refresh_catalog")
        let dry = try await call("add_game", ["machine": "arcade2", "game": "atari2600/Pitfall", "dry_run": true])
        XCTAssertFalse(dry.error)
        XCTAssertEqual(dry.json["plan"]?["system"]?.stringValue, "atari2600")
        XCTAssertEqual(dry.json["plan"]?["romFiles"]?.arrayValue?.compactMap(\.stringValue), [url.path])
        XCTAssertTrue(cabinets.shell.pushes.isEmpty)
        let r = try await call("add_game", ["machine": "arcade2", "game": "Pitfall"])
        XCTAssertFalse(r.error)
        XCTAssertEqual(cabinets.shell.pushes.map(\.remote), ["/home/pi/RetroPie/roms/atari2600/"])
        let wrong = try await call("add_game", ["machine": "arcade2", "game": "atari2600/Pitfall", "system": "mame-libretro"])
        XCTAssertTrue(wrong.error)
        XCTAssertEqual(wrong.text, "atari2600/Pitfall is a atari2600 game; it can only be added to the atari2600 system")
    }

    func testSyncGameListIsForEmulationStationCabinetsOnly() async throws {
        let r = try await call("sync_game_list", ["machine": "xarcade"])
        XCTAssertFalse(r.error)
        XCTAssertEqual(r.json["added"]?.intValue, 1); XCTAssertEqual(r.json["updated"]?.intValue, 1)
        XCTAssertEqual(r.json["systems"]?["mame-libretro"]?["games"]?.intValue, 1)
        XCTAssertTrue(cabinets.requests.contains("POST x.lan/v1/gamelist"))
        let attract = try await call("sync_game_list", ["machine": "arcade2"])
        XCTAssertTrue(attract.error)
        XCTAssertEqual(attract.text, "arcade2 runs Attract-Mode, which has no EmulationStation game list; use refresh_frontend")
    }

    func testAddingAMameGameToAnEmulationStationCabinetAlsoListsIt() async throws {
        let r = try await call("add_game", ["machine": "xarcade", "game": "galaga"])
        XCTAssertFalse(r.error)
        XCTAssertTrue(cabinets.requests.contains("POST x.lan/v1/gamelist"))
    }

    func testRepairRomsReportsMissingSupportSetsAndCopiesOnlyWhenAsked() async throws {
        let dry = try await call("repair_roms", ["machine": "arcade2"])
        XCTAssertFalse(dry.error)
        XCTAssertEqual(dry.json["dryRun"]?.boolValue, true)
        let missing = dry.json["missing"]?.arrayValue?.compactMap { $0["set"]?.stringValue } ?? []
        XCTAssertFalse(missing.isEmpty)
        XCTAssertTrue(cabinets.shell.pushes.isEmpty)
        let real = try await call("repair_roms", ["machine": "arcade2", "dry_run": false])
        XCTAssertFalse(real.error)
        let copied = real.json["copied"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(Set(copied).union(real.json["notInMaster"]?.arrayValue?.compactMap(\.stringValue) ?? []), Set(missing))
        XCTAssertEqual(cabinets.shell.pushes.count, copied.count)
        XCTAssertTrue(cabinets.shell.pushes.allSatisfy { $0.remote.hasSuffix("/mame-libretro/") })
    }

    func testRestartFrontendTool() async throws {
        let ok = try await call("restart_frontend", ["machine": "arcade2"])
        XCTAssertFalse(ok.error)
        XCTAssertEqual(ok.json["restarted"]?.boolValue, true)
        let busy = try await call("restart_frontend", ["machine": "xarcade"])
        XCTAssertTrue(busy.error)
        XCTAssertEqual(busy.text, "a game is running on xarcade; pass force: true to restart anyway")
        let forced = try await call("restart_frontend", ["machine": "xarcade", "force": true])
        XCTAssertFalse(forced.error)
    }

    func testMasterStatusAndCatalogRefresh() async throws {
        let refreshed = try await call("refresh_catalog")
        XCTAssertEqual(refreshed.json["games"]?.intValue, 4)
        let status = try await call("master_status")
        XCTAssertEqual(status.json["mounted"]?.boolValue, true)
        XCTAssertEqual(status.json["catalogGames"]?.intValue, 4)
    }

    func testSettingsToolsEditTheMachineList() async throws {
        let added = try await call("add_machine", ["name": "pi3", "user": "pi", "host": "pi3.lan", "frontend": "emulationstation"])
        XCTAssertFalse(added.error)
        let list = try await call("list_machines")
        XCTAssertEqual(list.json["machines"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["arcade2", "xarcade", "pi3"])
        let updated = try await call("update_machine", ["name": "pi3", "host": "pi3-new.lan", "roms_path": "/data/roms"])
        XCTAssertEqual(updated.json["machine"]?["host"]?.stringValue, "pi3-new.lan")
        XCTAssertEqual(updated.json["machine"]?["romsPath"]?.stringValue, "/data/roms")
        let dup = try await call("add_machine", ["name": "PI3", "user": "pi", "host": "x.lan", "frontend": "attract-mode"])
        XCTAssertTrue(dup.error)
        let badHost = try await call("add_machine", ["name": "bad", "user": "pi", "host": "x; rm", "frontend": "attract-mode"])
        XCTAssertTrue(badHost.error)
        let removed = try await call("remove_machine", ["name": "pi3"])
        XCTAssertFalse(removed.error)
        let after = try await call("list_machines")
        XCTAssertEqual(after.json["machines"]?.arrayValue?.count, 2)
        let path = try await call("set_master_path", ["path": "/Volumes/Other"])
        XCTAssertEqual(path.json["master"]?.stringValue, "/Volumes/Other")

        let branding = try await call("set_branding", ["title": "CUSTOM ARCADE", "subtitle": "MY CITY", "year": "1989"])
        XCTAssertEqual(branding.json["title"]?.stringValue, "CUSTOM ARCADE")
        XCTAssertEqual(branding.json["subtitle"]?.stringValue, "MY CITY")
        XCTAssertEqual(branding.json["year"]?.stringValue, "1989")
        let list2 = try await call("list_machines")
        XCTAssertEqual(list2.json["branding"]?["title"]?.stringValue, "CUSTOM ARCADE")
    }

    // MARK: more behavior: filters, errors and edge cases

    func testInventoryFiltersBySystemAndRefreshesOnRequest() async throws {
        let r = try await call("get_inventory", ["machine": "xarcade", "system": "mame-libretro", "refresh": true])
        XCTAssertEqual(r.json["total"]?.intValue, 1)
        XCTAssertTrue(cabinets.requests.contains("POST x.lan/v1/refresh"))
        let none = try await call("get_inventory", ["machine": "xarcade", "system": "atari2600"])
        XCTAssertEqual(none.json["total"]?.intValue, 0)
    }

    func testListEmulatorsForAllSystemsAndWhenNoneIsInstalled() async throws {
        let all = try await call("list_emulators", ["machine": "arcade2"])
        XCTAssertEqual(all.json["systems"]?.arrayValue?.first?["name"]?.stringValue, "mame-libretro")
        XCTAssertEqual(all.json["systems"]?.arrayValue?.first?["canAdd"]?.boolValue, true)
        cabinets.emulatorsInstalled = false
        let one = try await call("list_emulators", ["machine": "arcade2", "system": "mame-libretro"])
        XCTAssertEqual(one.json["canAdd"]?.boolValue, false)
        XCTAssertEqual(one.json["reason"]?.stringValue, "arcade2 has no emulator installed for mame-libretro")
    }

    func testSearchWarnsWhenACabinetCannotBeRead() async throws {
        struct DownShell: RemoteShell {
            func run(_ command: String) async throws -> CommandResult { throw RemoteError.commandFailed(status: 255, stderr: "Host is down") }
            func fetch(remotePath: String, to localPath: String) async throws -> CommandResult { throw RemoteError.commandFailed(status: 255, stderr: "down") }
            func push(localPath: String, toRemotePath remotePath: String) async throws -> CommandResult { throw RemoteError.commandFailed(status: 255, stderr: "down") }
        }
        _ = try await call("refresh_catalog")  // builds the catalog while the cabinets are still up
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        server = makeServer(shell: DownShell())
        let r = try await call("search_games", ["text": "galaga"])
        XCTAssertFalse(r.error)
        XCTAssertEqual(r.json["total"]?.intValue, 1)
        XCTAssertNotNil(r.json["warnings"]?["arcade2"]?.stringValue)
        XCTAssertTrue(r.json["warnings"]?["arcade2"]?.stringValue?.contains("Host is down") == true, "the SSH fallback explains why the cabinet is unreadable")
    }

    func testSearchByLetterSortAndVisibilityFilters() async throws {
        let letter = try await call("search_games", ["letter": "g"])
        XCTAssertEqual(letter.json["games"]?.arrayValue?.map { $0["name"]?.stringValue }, ["galaga"])
        let sorted = try await call("search_games", ["sort": "year"])
        XCTAssertEqual(sorted.json["games"]?.arrayValue?.first?["name"]?.stringValue, "pacman")
        let art = try await call("search_games", ["require_art": true])
        XCTAssertEqual(art.json["games"]?.arrayValue?.map { $0["name"]?.stringValue }, ["galaga"])
        let hist = try await call("search_games", ["require_history": true])
        XCTAssertEqual(hist.json["games"]?.arrayValue?.map { $0["name"]?.stringValue }, ["galaga", "pacman"])
        let onAny = try await call("search_games", ["installed": "on_any"])
        XCTAssertEqual(onAny.json["games"]?.arrayValue?.map { $0["name"]?.stringValue }, ["galaga", "pacman"])
        let digit = try await call("search_games", ["letter": "1"])
        XCTAssertEqual(digit.json["total"]?.intValue, 0)
    }

    func testFacetsRespectTheMakerLimit() async throws {
        let f = try await call("catalog_facets", ["maker_limit": 1])
        XCTAssertEqual(f.json["makers"]?.arrayValue?.count, 1)
    }

    func testScoreToolsFilterAndReportProblems() async throws {
        let none = try await call("get_scores", ["game": "galaga"])
        XCTAssertEqual(none.json["scores"]?.arrayValue?.count, 0, "nothing cached yet")
        let refreshed = try await call("refresh_scores")
        XCTAssertEqual(refreshed.json["decoderAvailable"]?.boolValue, true)
        XCTAssertEqual(refreshed.json["decoded"]?.intValue, 2)
        let one = try await call("get_scores", ["game": "galaga", "machine": "ARCADE2"])
        XCTAssertEqual(one.json["scores"]?.arrayValue?.count, 1)
        let player = try await call("player_rankings", ["player": "jon"])
        XCTAssertEqual(player.json["name"]?.stringValue, "JON")
        XCTAssertEqual(player.json["results"]?.arrayValue?.first?["game"]?.stringValue, "galaga")
        let nobody = try await call("player_rankings", ["player": "ZZQ"])
        XCTAssertTrue(nobody.error); XCTAssertEqual(nobody.text, "no scores for player 'ZZQ'")
        let onMachine = try await call("player_rankings", ["machine": "xarcade", "limit": 1])
        XCTAssertEqual(onMachine.json["players"]?.arrayValue?.count, 1)
    }

    func testUnreachableCabinetsKeepTheirLastScoresAndAreReported() async throws {
        _ = try await call("refresh_scores")
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let r = try await call("refresh_scores")
        XCTAssertEqual(r.json["files"]?.intValue, 2, "last known scores are kept")
        XCTAssertNotNil(r.json["unreachable"]?["arcade2"]?.stringValue)
        XCTAssertNotNil(r.json["unreachable"]?["xarcade"]?.stringValue)
    }

    func testSyncPlanIsEmptyWithoutScores() async throws {
        let plan = try await call("plan_score_sync")
        XCTAssertEqual(plan.json["writes"]?.arrayValue?.count, 0)
    }

    func testRemoveGameWithAmbiguousSystemsAndOptions() async throws {
        StubURLProtocol.handler = { req in
            let body = req.url!.path == "/v1/inventory"
                ? #"{"machine":"x","totalGames":2,"systems":[{"name":"mame-libretro","defaultEmulator":null,"emulators":[],"games":[{"system":"mame-libretro","name":"dup","file":"dup.zip","emulator":null,"isPinned":false,"size":1,"mtime":1}]},{"name":"arcade","defaultEmulator":null,"emulators":[],"games":[{"system":"arcade","name":"dup","file":"dup.zip","emulator":null,"isPinned":false,"size":1,"mtime":1}]}]}"#
                : #"{"dryRun":true,"name":"dup","pin":true,"remove":["a"],"system":"arcade"}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let ambiguous = try await call("remove_game", ["machine": "arcade2", "game": "dup"])
        XCTAssertTrue(ambiguous.error)
        XCTAssertTrue(ambiguous.text.contains("pass 'system'"))
        let chosen = try await call("remove_game", ["machine": "arcade2", "game": "dup", "system": "arcade", "remove_saves": true, "remove_scores": true])
        XCTAssertFalse(chosen.error)
        XCTAssertEqual(chosen.json["pinRemoved"]?.boolValue, true)
        XCTAssertTrue(StubURLProtocol.lastRequest?.url?.query?.contains("withSaves=1") == true)
        XCTAssertTrue(StubURLProtocol.lastRequest?.url?.query?.contains("withScores=1") == true)
    }

    func testTestConnectionReportsServiceAndSSHFailures() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        struct DownShell: RemoteShell {
            func run(_ command: String) async throws -> CommandResult { throw RemoteError.commandFailed(status: 255, stderr: "") }
            func fetch(remotePath: String, to localPath: String) async throws -> CommandResult { throw RemoteError.commandFailed(status: 255, stderr: "down") }
            func push(localPath: String, toRemotePath remotePath: String) async throws -> CommandResult { throw RemoteError.commandFailed(status: 255, stderr: "down") }
        }
        server = makeServer(shell: DownShell())
        let r = try await call("test_connection", ["machine": "xarcade"])
        XCTAssertEqual(r.json["service"]?["ok"]?.boolValue, false)
        XCTAssertEqual(r.json["ssh"]?["ok"]?.boolValue, false)
        XCTAssertEqual(r.json["ssh"]?["error"]?.stringValue, "remote command failed")
    }

    func testUpdateMachineChangesEveryField() async throws {
        let r = try await call("update_machine", ["name": "xarcade", "user": "tester", "host": "x2.lan", "frontend": "attract-mode", "roms_path": "/r", "service_port": 9000])
        let m = try XCTUnwrap(r.json["machine"])
        XCTAssertEqual(m["user"]?.stringValue, "tester"); XCTAssertEqual(m["host"]?.stringValue, "x2.lan"); XCTAssertEqual(m["frontend"]?.stringValue, "attract-mode")
        XCTAssertEqual(m["romsPath"]?.stringValue, "/r"); XCTAssertEqual(m["servicePort"]?.intValue, 9000)
        let r1 = try await call("update_machine", ["name": "nope"])
        XCTAssertTrue(r1.error)
        let r2 = try await call("update_machine", ["name": "xarcade", "frontend": "beos"])
        XCTAssertTrue(r2.error)
        let r3 = try await call("update_machine", ["name": "xarcade", "host": "bad host"])
        XCTAssertTrue(r3.error, "invalid settings are refused and not saved")
        let q6 = try await call("list_machines")
        XCTAssertEqual(q6.json["machines"]?.arrayValue?[1]["host"]?.stringValue, "x2.lan")
        let r4 = try await call("remove_machine", ["name": "nope"])
        XCTAssertTrue(r4.error)
        let r5 = try await call("add_machine", ["name": "m", "user": "pi", "host": "h.lan", "frontend": "beos"])
        XCTAssertTrue(r5.error)
    }

    func testMasterToolsWhenTheMasterIsGone() async throws {
        _ = try await call("set_master_path", ["path": "/Volumes/DoesNotExist"])
        let status = try await call("master_status")
        XCTAssertEqual(status.json["mounted"]?.boolValue, false)
        let refresh = try await call("refresh_catalog")
        XCTAssertTrue(refresh.error)
        XCTAssertTrue(refresh.text.contains("not mounted"))
    }

    func testTheCatalogIsReloadedWhenTheAppRewritesItsCache() async throws {
        _ = try await call("refresh_catalog")
        let q7 = try await call("master_status")
        XCTAssertEqual(q7.json["catalogGames"]?.intValue, 4)
        var cache = try XCTUnwrap(CatalogCache.load(from: dir.appendingPathComponent("catalog.json")))
        cache.games = Array(cache.games.prefix(2))
        try await Task.sleep(nanoseconds: 1_100_000_000)  // file modification times have one-second resolution
        try CatalogCache.save(cache, to: dir.appendingPathComponent("catalog.json"))
        let q8 = try await call("master_status")
        XCTAssertEqual(q8.json["catalogGames"]?.intValue, 2)
    }

    func testThemeStatusAndInstallThemeTools() async throws {
        let status = try await call("theme_status", ["machine": "xarcade"])
        XCTAssertFalse(status.error)
        XCTAssertEqual(status.json["frontend"]?.stringValue, "emulationstation")
        XCTAssertEqual(status.json["activeTheme"]?.stringValue, "dll-arcade")
        XCTAssertEqual(status.json["installedThemes"]?.arrayValue?.map(\.stringValue), ["carbon", "dll-arcade"])

        let install = try await call("install_theme", ["machine": "xarcade"])
        XCTAssertFalse(install.error)
        XCTAssertEqual(install.json["theme"]?.stringValue, "dll-arcade")
        XCTAssertEqual(install.json["method"]?.stringValue, "service")
        XCTAssertEqual(install.json["activated"]?.boolValue, true)
    }
}
