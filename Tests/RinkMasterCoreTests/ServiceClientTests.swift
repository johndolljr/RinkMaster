import XCTest
@testable import RinkMasterCore

/// Intercepts URLSession requests so no test touches the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func respond(_ status: Int, body: String = "", headers: [String: String] = [:]) {
        handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, Data(body.utf8))
        }
    }
}

let sampleInventoryJSON = """
{"generatedAt":"2026-10-03T15:00:00Z","machine":"arcade2","totalGames":2,
 "systems":[{"name":"mame-libretro","defaultEmulator":"lr-mame2010","emulators":["lr-mame2003","lr-mame2010"],
   "games":[{"system":"mame-libretro","name":"galaga","file":"galaga.zip","emulator":"lr-mame2010","isPinned":false,"size":24797,"mtime":1700000000},
            {"system":"mame-libretro","name":"tempest","file":"tempest.zip","emulator":"lr-mame2003","isPinned":true,"size":100,"mtime":1700000001}]}]}
"""

final class ServiceClientTests: XCTestCase {
    private func client() -> ServiceClient { ServiceClient(host: "cabinet1.lan", port: 8472, session: StubURLProtocol.session) }

    func testDecodesInventoryAndEtag() async throws {
        StubURLProtocol.respond(200, body: sampleInventoryJSON, headers: ["ETag": "\"abc\""])
        let r = try await client().inventory(ifNoneMatch: nil)
        XCTAssertEqual(r.etag, "\"abc\"")
        XCTAssertFalse(r.notModified)
        let inv = try XCTUnwrap(r.inventory)
        XCTAssertEqual(inv.totalGames, 2)
        let mame = inv.systems[0]
        XCTAssertEqual(mame.defaultEmulator, "lr-mame2010")
        XCTAssertEqual(mame.emulators, ["lr-mame2003", "lr-mame2010"])
        XCTAssertEqual(mame.games[1].name, "tempest")
        XCTAssertTrue(mame.games[1].isPinned)
        XCTAssertEqual(mame.games[0].size, 24797)
        XCTAssertEqual(mame.games[0].mtime, 1700000000)
    }

    func testHealthDecodes() async throws {
        StubURLProtocol.respond(200, body: #"{"machine":"arcade2","ok":true,"uptimeSeconds":5,"version":"0.1.0"}"#)
        let h = try await client().health()
        XCTAssertEqual(h, ServiceHealth(ok: true, version: "0.1.0", machine: "arcade2"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/health")
    }

    func testHealthErrorsAreReported() async {
        StubURLProtocol.respond(503)
        do { _ = try await client().health(); XCTFail("expected error") }
        catch let e as ServiceError { XCTAssertEqual(e, .http(503)) }
        catch { XCTFail("wrong error \(error)") }
        StubURLProtocol.respond(200, body: "garbage")
        do { _ = try await client().health(); XCTFail("expected error") }
        catch let e as ServiceError { if case .decoding = e {} else { XCTFail("wrong \(e)") } }
        catch { XCTFail("wrong error \(error)") }
    }

    func testInventoryRoundTripsThroughJSON() throws {
        let inv = try JSONDecoder().decode(MachineInventory.self, from: Data(sampleInventoryJSON.utf8))
        let again = try JSONDecoder().decode(MachineInventory.self, from: JSONEncoder().encode(inv))
        XCTAssertEqual(again, inv)
    }

    func testGameWithoutSizeOrMtimeStillDecodes() throws {
        let json = #"{"system":"s","name":"n","file":"n.zip","emulator":null,"isPinned":false}"#
        let g = try JSONDecoder().decode(InstalledGame.self, from: Data(json.utf8))
        XCTAssertEqual(g.size, 0)
        XCTAssertNil(g.emulator)
    }

    func testRequestUsesPortPathAndIfNoneMatch() async throws {
        StubURLProtocol.respond(200, body: sampleInventoryJSON)
        _ = try await client().inventory(ifNoneMatch: "\"abc\"")
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "http://cabinet1.lan:8472/v1/inventory")
        XCTAssertEqual(req.value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
    }

    func test304IsNotModified() async throws {
        StubURLProtocol.respond(304, headers: ["ETag": "\"abc\""])
        let r = try await client().inventory(ifNoneMatch: "\"abc\"")
        XCTAssertTrue(r.notModified)
        XCTAssertNil(r.inventory)
    }

    func testServerErrorThrows() async {
        StubURLProtocol.respond(500)
        do { _ = try await client().inventory(ifNoneMatch: nil); XCTFail("expected error") }
        catch let e as ServiceError { XCTAssertEqual(e, .http(500)) }
        catch { XCTFail("wrong error \(error)") }
    }

    func testInvalidJSONThrowsDecoding() async {
        StubURLProtocol.respond(200, body: "not json")
        do { _ = try await client().inventory(ifNoneMatch: nil); XCTFail("expected error") }
        catch let e as ServiceError { if case .decoding = e {} else { XCTFail("wrong \(e)") } }
        catch { XCTFail("wrong error \(error)") }
    }

    func testNetworkFailureIsPropagated() async {
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do { _ = try await client().inventory(ifNoneMatch: nil); XCTFail("expected error") }
        catch { XCTAssertTrue(error is URLError) }
    }
}

private struct StubShell: RemoteShell {
    let output: String
    func run(_ command: String) async throws -> CommandResult { CommandResult(status: 0, stdout: output, stderr: "") }
    func fetch(remotePath: String, to localPath: String) async throws -> CommandResult { fatalError() }
    func push(localPath: String, toRemotePath remotePath: String) async throws -> CommandResult { fatalError() }
}

private struct FailingShell: RemoteShell {
    func run(_ command: String) async throws -> CommandResult { throw RemoteError.commandFailed(status: 255, stderr: "down") }
    func fetch(remotePath: String, to localPath: String) async throws -> CommandResult { fatalError() }
    func push(localPath: String, toRemotePath remotePath: String) async throws -> CommandResult { fatalError() }
}

final class InventoryProviderTests: XCTestCase {
    private let machine = Machine(name: "arcade2", user: "pi", host: "cabinet1.lan", frontend: .attractMode)
    private func service() -> ServiceClient { ServiceClient(host: "cabinet1.lan", port: 8472, session: StubURLProtocol.session) }
    private let sshOutput = "@@SYSTEM mame-libretro\nf galaga.zip\n@@CFG mame-libretro\ndefault = \"lr-mame2010\"\n@@PINS\n"

    func testUsesServiceThenCachedOn304() async throws {
        StubURLProtocol.respond(200, body: sampleInventoryJSON, headers: ["ETag": "\"abc\""])
        let provider = InventoryProvider(service: service(), fallback: InventoryReader(shell: FailingShell(), machine: machine))
        let first = try await provider.load()
        XCTAssertEqual(first.source, .service(cached: false))
        XCTAssertEqual(first.inventory.totalGames, 2)

        StubURLProtocol.respond(304, headers: ["ETag": "\"abc\""])
        let second = try await provider.load()
        XCTAssertEqual(second.source, .service(cached: true))
        XCTAssertEqual(second.inventory, first.inventory)
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
    }

    func testFallsBackToSSHWhenServiceIsUnreachable() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let provider = InventoryProvider(service: service(), fallback: InventoryReader(shell: StubShell(output: sshOutput), machine: machine))
        let loaded = try await provider.load()
        XCTAssertEqual(loaded.source, .ssh)
        XCTAssertEqual(loaded.inventory.totalGames, 1)
    }

    func testFallsBackWhenServiceSays304ButNothingIsCached() async throws {
        StubURLProtocol.respond(304, headers: ["ETag": "\"x\""])
        let provider = InventoryProvider(service: service(), fallback: InventoryReader(shell: StubShell(output: sshOutput), machine: machine))
        let loaded = try await provider.load()
        XCTAssertEqual(loaded.source, .ssh)
    }

    func testFallsBackWhenServiceReturnsAnError() async throws {
        StubURLProtocol.respond(500)
        let provider = InventoryProvider(service: service(), fallback: InventoryReader(shell: StubShell(output: sshOutput), machine: machine))
        let loaded = try await provider.load()
        XCTAssertEqual(loaded.source, .ssh)
    }

    func testThrowsWhenBothFail() async {
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let provider = InventoryProvider(service: service(), fallback: InventoryReader(shell: FailingShell(), machine: machine))
        do { _ = try await provider.load(); XCTFail("expected error") }
        catch let e as RemoteError { XCTAssertEqual(e, .commandFailed(status: 255, stderr: "down")) }
        catch { XCTFail("wrong error \(error)") }
    }
}

final class MachineServicePortTests: XCTestCase {
    func testDefaultPortAndOldSettingsStillDecode() throws {
        XCTAssertEqual(Machine(name: "a", user: "pi", host: "h", frontend: .attractMode).servicePort, 8472)
        let old = #"{"machines":[{"name":"a","user":"pi","host":"h.lan","frontend":"attract-mode","romsPath":"/r"}],"masterPath":"/m"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.machines[0].servicePort, 8472)
    }

    func testCustomPortRoundTrips() throws {
        var m = Machine(name: "a", user: "pi", host: "h", frontend: .attractMode)
        m.servicePort = 9000
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(Machine.self, from: data).servicePort, 9000)
    }
}
