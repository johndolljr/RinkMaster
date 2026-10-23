import XCTest
@testable import RinkMasterCore

let sampleEmulatorsJSON = """
{"machine":"arcade2","systems":[
 {"name":"mame-libretro","defaultEmulator":"lr-mame2010","hasInstalledEmulator":true,
  "emulators":[{"id":"lr-mame2003","installed":false,"command":"x"},{"id":"lr-mame2010","installed":true,"command":"y"},{"id":"lr-mame2016","installed":true,"command":"z"}]},
 {"name":"atari2600","defaultEmulator":"stella","hasInstalledEmulator":false,
  "emulators":[{"id":"stella","installed":false,"command":"s"}]},
 {"name":"daphne","defaultEmulator":null,"hasInstalledEmulator":true,
  "emulators":[{"id":"daphne","installed":true,"command":"d"}]}]}
"""

final class MachineEmulatorsTests: XCTestCase {
    private func emulators() throws -> MachineEmulators {
        try JSONDecoder().decode(MachineEmulators.self, from: Data(sampleEmulatorsJSON.utf8))
    }

    func testInstalledEmulatorsPerSystem() throws {
        let e = try emulators()
        XCTAssertEqual(e.installedEmulators(for: "mame-libretro"), ["lr-mame2010", "lr-mame2016"])
        XCTAssertEqual(e.installedEmulators(for: "atari2600"), [])
        XCTAssertEqual(e.installedEmulators(for: "nes"), [])  // unknown system
    }

    func testCanInstallOnlyWhenAnEmulatorIsInstalled() throws {
        let e = try emulators()
        XCTAssertTrue(e.canInstall(system: "mame-libretro"))
        XCTAssertTrue(e.canInstall(system: "daphne"))
        XCTAssertFalse(e.canInstall(system: "atari2600"))
        XCTAssertFalse(e.canInstall(system: "nes"))
    }

    func testReasonExplainsWhyAddIsUnavailable() throws {
        let e = try emulators()
        XCTAssertNil(e.cannotInstallReason(system: "mame-libretro", machine: "arcade2"))
        XCTAssertEqual(e.cannotInstallReason(system: "atari2600", machine: "arcade2"),
                       "arcade2 has no emulator installed for atari2600")
        XCTAssertEqual(e.cannotInstallReason(system: "nes", machine: "xarcade"),
                       "xarcade has no emulator installed for nes")
    }

    func testDefaultChoiceIsTheSystemDefaultIfInstalledElseFirstInstalled() throws {
        let e = try emulators()
        XCTAssertEqual(e.preferredEmulator(for: "mame-libretro"), "lr-mame2010")
        XCTAssertEqual(e.preferredEmulator(for: "daphne"), "daphne")  // no default configured, first installed
        XCTAssertNil(e.preferredEmulator(for: "atari2600"))
        let json = sampleEmulatorsJSON.replacingOccurrences(of: #""defaultEmulator":"lr-mame2010""#, with: #""defaultEmulator":"lr-mame2003""#)
        let e2 = try JSONDecoder().decode(MachineEmulators.self, from: Data(json.utf8))
        XCTAssertEqual(e2.preferredEmulator(for: "mame-libretro"), "lr-mame2010")  // default not installed
    }
}

final class ServiceActionsClientTests: XCTestCase {
    private func client() -> ServiceClient { ServiceClient(host: "cabinet1.lan", port: 8472, session: StubURLProtocol.session) }

    func testEmulatorsEndpoint() async throws {
        StubURLProtocol.respond(200, body: sampleEmulatorsJSON)
        let e = try await client().emulators()
        XCTAssertTrue(e.canInstall(system: "mame-libretro"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/emulators")
    }

    func testRemovalDryRunBuildsTheQueryAndDecodesThePlan() async throws {
        StubURLProtocol.respond(200, body: #"{"dryRun":true,"name":"galaga","pin":true,"remove":["mame-libretro/galaga.zip","mame-libretro/snap/galaga.png"],"system":"mame-libretro"}"#)
        let plan = try await client().removeGame(system: "mame-libretro", name: "galaga",
                                                 options: RemovalOptions(art: true, saves: false, scores: false), dryRun: true)
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "DELETE")
        XCTAssertEqual(req.url?.path, "/v1/games/mame-libretro/galaga")
        let query = Set((req.url?.query ?? "").split(separator: "&").map(String.init))
        XCTAssertEqual(query, ["dryRun=1", "withArt=1"])
        XCTAssertTrue(plan.dryRun)
        XCTAssertEqual(plan.remove, ["mame-libretro/galaga.zip", "mame-libretro/snap/galaga.png"])
        XCTAssertTrue(plan.pin)
        XCTAssertNil(plan.removed)
    }

    func testRealRemovalReportsWhatWasRemovedAndTheFrontend() async throws {
        StubURLProtocol.respond(200, body: #"{"dryRun":false,"name":"galaga","pin":false,"remove":["mame-libretro/galaga.zip"],"removed":["mame-libretro/galaga.zip"],"frontend":{"frontend":"attract-mode","refreshed":["Multiple Arcade Machine Emulator"],"errors":[]},"system":"mame-libretro"}"#)
        let plan = try await client().removeGame(system: "mame-libretro", name: "galaga",
                                                 options: RemovalOptions(art: true, saves: true, scores: true), dryRun: false)
        let query = Set((StubURLProtocol.lastRequest?.url?.query ?? "").split(separator: "&").map(String.init))
        XCTAssertEqual(query, ["withArt=1", "withSaves=1", "withScores=1"])
        XCTAssertEqual(plan.removed, ["mame-libretro/galaga.zip"])
        XCTAssertEqual(plan.frontend?.refreshed, ["Multiple Arcade Machine Emulator"])
    }

    func testRemovalErrorsMapToServiceErrors() async {
        StubURLProtocol.respond(404, body: #"{"error":"game not installed"}"#)
        do { _ = try await client().removeGame(system: "mame-libretro", name: "nope", options: RemovalOptions(), dryRun: true); XCTFail("expected") }
        catch let e as ServiceError { XCTAssertEqual(e, .http(404)) }
        catch { XCTFail("wrong \(error)") }
    }

    func testEmulatorChangesPostJSONAndHonourDryRun() async throws {
        StubURLProtocol.respond(200, body: #"{"system":"atari2600","emulator":"stella","previous":"lr-stella2014","changed":true,"dryRun":true,"file":"/f","backup":null}"#)
        let r = try await client().setDefaultEmulator(system: "atari2600", emulator: "stella", dryRun: true)
        XCTAssertEqual(r.previous, "lr-stella2014"); XCTAssertTrue(r.dryRun)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "http://cabinet1.lan:8472/v1/emulators/default?dryRun=1")
        StubURLProtocol.respond(200, body: #"{"system":"atari2600","game":"Pitfall","emulator":null,"previous":"stella","changed":true,"dryRun":false,"file":"/f","backup":"/f.bak"}"#)
        let p = try await client().pinEmulator(system: "atari2600", game: "Pitfall", emulator: nil, dryRun: false)
        XCTAssertNil(p.emulator); XCTAssertEqual(p.backup, "/f.bak")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "http://cabinet1.lan:8472/v1/emulators/pin")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
    }

    func testRestartFrontendIsAPostAndForceIsOptIn() async throws {
        StubURLProtocol.respond(200, body: #"{"frontend":"emulationstation","restarted":true,"refreshed":[],"errors":[],"message":"restarting"}"#)
        let r = try await client().restartFrontend()
        XCTAssertTrue(r.restarted)
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "http://cabinet1.lan:8472/v1/frontend/restart")
        _ = try await client().restartFrontend(force: true)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.query, "force=1")
        StubURLProtocol.respond(409, body: #"{"error":"a game is running"}"#)
        do { _ = try await client().restartFrontend(); XCTFail("busy") } catch ServiceError.http(let code) { XCTAssertEqual(code, 409) }
    }

    func testFrontendAndInventoryRefreshArePosts() async throws {
        StubURLProtocol.respond(200, body: #"{"frontend":"attract-mode","refreshed":["X"],"errors":[]}"#)
        let r = try await client().refreshFrontend(system: "mame-libretro")
        XCTAssertEqual(r.refreshed, ["X"])
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "http://cabinet1.lan:8472/v1/frontend/refresh?system=mame-libretro")
        StubURLProtocol.respond(200, body: #"{"totalGames":5,"etag":"\"e\""}"#)
        try await client().refreshInventory()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/refresh")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
    }
}
