import XCTest
@testable import RinkMasterCore

final class InstallerOtherSystemTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeMasterTree([
            "roms/other-systems/snes/ActRaiser (USA).zip",
            "roms/other-systems/snes/boxart/ActRaiser (USA).png", "roms/other-systems/snes/cartart/ActRaiser (USA).png",
            "roms/other-systems/snes/snap/ActRaiser (USA).mp4", "roms/other-systems/snes/wheel/ActRaiser (USA).png",
            "roms/other-systems/snes/Bare.zip", "roms/other-systems/daphne/lair.daphne/lair.txt",
        ])
        let list = "<gameList><game><path>./ActRaiser (USA).zip</path><name>ActRaiser</name><desc>Angel.</desc><releasedate>19901221T000000</releasedate><developer>Quintet</developer></game></gameList>"
        try list.write(to: root.appendingPathComponent("roms/other-systems/snes/gamelist.xml"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func bodyData(_ req: URLRequest) -> Data {
        guard let stream = req.httpBodyStream else { return req.httpBody ?? Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }

    private func installer(_ frontend: FrontendType, shell: RecordingShell, gamelistBodies: Box) -> Installer {
        StubURLProtocol.handler = { [self] req in
            let body: String
            switch req.url!.path {
            case "/v1/emulators": body = #"{"machine":"m","systems":[{"name":"snes","defaultEmulator":"lr-snes9x","hasInstalledEmulator":true,"emulators":[{"id":"lr-snes9x","installed":true,"command":"a"}]},{"name":"daphne","defaultEmulator":"daphne","hasInstalledEmulator":true,"emulators":[{"id":"daphne","installed":true,"command":"d"}]}]}"#
            case "/v1/gamelist": gamelistBodies.items.append(bodyData(req)); body = #"{"added":1}"#
            case "/v1/frontend/refresh": body = #"{"frontend":"x","refreshed":[],"errors":[]}"#
            default: body = #"{"totalGames":1,"etag":"e"}"#
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let machine = Machine(name: "m", user: "pi", host: "m.lan", frontend: frontend)
        return Installer(machine: machine, shell: shell, service: ServiceClient(host: "m.lan", port: 8472, session: StubURLProtocol.session),
                         master: MasterLibrary(root: root), database: nil)
    }

    final class Box: @unchecked Sendable { var items: [Data] = [] }

    func testPlanListsTheRomAndTheCabinetArtButNotCartArt() async throws {
        let plan = try await installer(.attractMode, shell: RecordingShell(), gamelistBodies: Box())
            .plan(game: "ActRaiser (USA)", system: "snes", emulator: nil, sourcePath: "roms/other-systems/snes/ActRaiser (USA).zip")
        XCTAssertEqual(plan.romFiles, [root.appendingPathComponent("roms/other-systems/snes/ActRaiser (USA).zip").path])
        XCTAssertEqual(plan.artFiles.map(\.type), ["boxart", "snap", "wheel"])
        XCTAssertFalse(plan.pinsEmulator)
    }

    func testAttractCabinetGetsTheArtFoldersAndNoGamelist() async throws {
        let shell = RecordingShell(), box = Box()
        _ = try await installer(.attractMode, shell: shell, gamelistBodies: box)
            .add(game: "ActRaiser (USA)", system: "snes", emulator: nil, sourcePath: "roms/other-systems/snes/ActRaiser (USA).zip")
        XCTAssertEqual(shell.pushes.map(\.remote), ["/home/pi/RetroPie/roms/snes/", "/home/pi/RetroPie/roms/snes/flyer/", "/home/pi/RetroPie/roms/snes/snap/", "/home/pi/RetroPie/roms/snes/wheel/"])
        XCTAssertTrue(box.items.isEmpty)
    }

    func testEmulationStationCabinetAlsoGetsItsGameListUpdated() async throws {
        let shell = RecordingShell(), box = Box()
        _ = try await installer(.emulationStation, shell: shell, gamelistBodies: box)
            .add(game: "ActRaiser (USA)", system: "snes", emulator: nil, sourcePath: "roms/other-systems/snes/ActRaiser (USA).zip")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(box.items.first)) as? [String: Any])
        XCTAssertEqual(json["system"] as? String, "snes")
        let game = try XCTUnwrap((json["games"] as? [[String: String]])?.first)
        XCTAssertEqual(game["path"], "./ActRaiser (USA).zip"); XCTAssertEqual(game["name"], "ActRaiser"); XCTAssertEqual(game["desc"], "Angel.")
        XCTAssertEqual(game["image"], "./flyer/ActRaiser (USA).png"); XCTAssertEqual(game["marquee"], "./wheel/ActRaiser (USA).png")
        XCTAssertNil(game["video"])  // a <video> tag switches ES to its video view, which crashed xarcade
        XCTAssertEqual(game["releasedate"], "19901221T000000"); XCTAssertEqual(game["developer"], "Quintet")
    }

    func testAGameWithNoDetailsOrArtStillGetsAnEntryNamedAfterItsFile() async throws {
        let shell = RecordingShell(), box = Box()
        _ = try await installer(.emulationStation, shell: shell, gamelistBodies: box)
            .add(game: "Bare", system: "snes", emulator: nil, sourcePath: "roms/other-systems/snes/Bare.zip")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(box.items.first)) as? [String: Any])
        XCTAssertEqual((json["games"] as? [[String: String]])?.first, ["path": "./Bare.zip", "name": "Bare"])
        XCTAssertEqual(shell.pushes.map(\.remote), ["/home/pi/RetroPie/roms/snes/"])
    }

    func testAFolderGameIsCopiedWholeAndAMissingSourceIsRefused() async throws {
        let shell = RecordingShell()
        let inst = installer(.attractMode, shell: shell, gamelistBodies: Box())
        _ = try await inst.add(game: "lair", system: "daphne", emulator: nil, sourcePath: "roms/other-systems/daphne/lair.daphne")
        XCTAssertEqual(shell.pushes.first?.local, root.appendingPathComponent("roms/other-systems/daphne/lair.daphne").path)
        do { _ = try await inst.plan(game: "x", system: "snes", emulator: nil, sourcePath: "roms/other-systems/snes/Missing.zip"); XCTFail() }
        catch InstallError.missingRomSet(let s) { XCTAssertEqual(s, "roms/other-systems/snes/Missing.zip") }
        do { _ = try await inst.plan(game: "x", system: "snes", emulator: nil, sourcePath: "../../etc/passwd"); XCTFail() }
        catch InstallError.missingRomSet { }
    }

    func testUpsertGamelistPostsJSON() async throws {
        StubURLProtocol.respond(200, body: #"{"added":1}"#)
        try await ServiceClient(host: "m.lan", port: 8472, session: StubURLProtocol.session).upsertGamelist(system: "snes", games: [["path": "./a.zip"]], dryRun: true)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "http://m.lan:8472/v1/gamelist?dryRun=1")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
    }
}
