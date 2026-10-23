import XCTest
@testable import RinkMasterCore

/// Records every command and file copy; no network or disk on the cabinet.
final class RecordingShell: RemoteShell, @unchecked Sendable {
    var commands: [String] = []
    var pushes: [(local: String, remote: String)] = []
    var failPush = false
    func run(_ command: String) async throws -> CommandResult { commands.append(command); return CommandResult(status: 0, stdout: "", stderr: "") }
    func fetch(remotePath: String, to localPath: String) async throws -> CommandResult { fatalError("unused") }
    func push(localPath: String, toRemotePath remotePath: String) async throws -> CommandResult {
        if failPush { throw RemoteError.commandFailed(status: 23, stderr: "rsync failed") }
        pushes.append((localPath, remotePath)); return CommandResult(status: 0, stdout: "", stderr: "")
    }
}

final class InstallerTests: XCTestCase {
    private var root: URL!
    private let machine = Machine(name: "arcade2", user: "pi", host: "cabinet1.lan", frontend: .attractMode)

    override func setUpWithError() throws {
        root = try makeMasterTree([
            "roms/sets/0.172/galaga.zip", "roms/sets/0.172/namco51.zip", "roms/sets/0.172/namco54.zip",
            "roms/sets/0.172/pacman.zip", "roms/sets/0.172/puckman.zip", "roms/sets/0.078/pacman.zip", "roms/sets/0.078/puckman.zip",
            "artwork/best/snap/galaga.png", "artwork/best/video/galaga.mp4", "artwork/best/wheel/galaga.png",
        ])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func emulators(installed: Bool = true) throws -> MachineEmulators {
        let json = #"{"machine":"arcade2","systems":[{"name":"mame-libretro","defaultEmulator":"lr-mame2010","hasInstalledEmulator":\#(installed),"emulators":[{"id":"lr-mame2003","installed":\#(installed),"command":"a"},{"id":"lr-mame2010","installed":\#(installed),"command":"b"}]}]}"#
        return try JSONDecoder().decode(MachineEmulators.self, from: Data(json.utf8))
    }

    private func installer(shell: RecordingShell, installed: Bool = true) throws -> Installer {
        StubURLProtocol.handler = { req in
            let body: String
            switch req.url!.path {
            case "/v1/emulators": body = #"{"machine":"arcade2","systems":[{"name":"mame-libretro","defaultEmulator":"lr-mame2010","hasInstalledEmulator":\#(installed),"emulators":[{"id":"lr-mame2003","installed":\#(installed),"command":"a"},{"id":"lr-mame2010","installed":\#(installed),"command":"b"}]}]}"#
            case "/v1/frontend/refresh": body = #"{"frontend":"attract-mode","refreshed":["Multiple Arcade Machine Emulator"],"errors":[]}"#
            default: body = #"{"totalGames":1,"etag":"e"}"#
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let db = try MameDatabase.parse(Data(sampleMameXML.utf8))
        return Installer(machine: machine, shell: shell, service: ServiceClient(host: "cabinet1.lan", port: 8472, session: StubURLProtocol.session),
                         master: MasterLibrary(root: root), database: db)
    }

    func testAddCopiesTheGameItsDevicesAndArtThenRefreshes() async throws {
        let shell = RecordingShell()
        let report = try await installer(shell: shell).add(game: "galaga", system: "mame-libretro", emulator: nil)
        XCTAssertEqual(report.romSets, ["galaga", "namco51", "namco54"])
        XCTAssertEqual(report.emulator, "lr-mame2010")
        let romPushes = shell.pushes.filter { $0.remote == "/home/pi/RetroPie/roms/mame-libretro/" }
        XCTAssertEqual(romPushes.map { ($0.local as NSString).lastPathComponent }, ["galaga.zip", "namco51.zip", "namco54.zip"])
        // art goes to the cabinet's art folders (video lands next to snaps)
        XCTAssertTrue(shell.pushes.contains { $0.remote == "/home/pi/RetroPie/roms/mame-libretro/snap/" && $0.local.hasSuffix("galaga.png") })
        XCTAssertTrue(shell.pushes.contains { $0.remote == "/home/pi/RetroPie/roms/mame-libretro/snap/" && $0.local.hasSuffix("galaga.mp4") })
        XCTAssertTrue(shell.pushes.contains { $0.remote == "/home/pi/RetroPie/roms/mame-libretro/wheel/" })
        XCTAssertTrue(shell.commands.contains { $0.contains("mkdir -p") && $0.contains("/mame-libretro/snap") })
        XCTAssertEqual(report.frontendRefreshed, ["Multiple Arcade Machine Emulator"])
        XCTAssertFalse(shell.commands.contains { $0.contains("emulators.cfg") })  // default emulator: no per-game pin
    }

    func testPickingANonDefaultEmulatorAddsAPerGamePinAndUsesThatCoresRomSet() async throws {
        let shell = RecordingShell()
        let report = try await installer(shell: shell).add(game: "pacman", system: "mame-libretro", emulator: "lr-mame2003")
        XCTAssertEqual(report.romSets, ["pacman", "puckman"])
        XCTAssertTrue(shell.pushes.contains { $0.local.hasSuffix("sets/0.078/pacman.zip") })  // matching mame2003 set version
        let pin = try XCTUnwrap(shell.commands.first { $0.contains("emulators.cfg") })
        XCTAssertTrue(pin.contains("mame-libretro_pacman"))
        XCTAssertTrue(pin.contains("lr-mame2003"))
        XCTAssertTrue(pin.contains("grep -q"))  // idempotent
    }

    func testAddIsRefusedWhenNoEmulatorIsInstalledAndNothingIsCopied() async throws {
        let shell = RecordingShell()
        do { _ = try await installer(shell: shell, installed: false).add(game: "galaga", system: "mame-libretro", emulator: nil); XCTFail("expected refusal") }
        catch let e as InstallError { XCTAssertEqual(e, .noEmulatorInstalled(machine: "arcade2", system: "mame-libretro")) }
        XCTAssertTrue(shell.pushes.isEmpty)
        XCTAssertTrue(shell.commands.isEmpty)
    }

    func testAnEmulatorThatIsNotInstalledCannotBeChosen() async throws {
        let shell = RecordingShell()
        do { _ = try await installer(shell: shell).add(game: "galaga", system: "mame-libretro", emulator: "lr-mame9999"); XCTFail("expected refusal") }
        catch let e as InstallError { XCTAssertEqual(e, .emulatorNotInstalled(machine: "arcade2", emulator: "lr-mame9999")) }
        XCTAssertTrue(shell.pushes.isEmpty)
    }

    func testMissingRomSetFailsBeforeAnythingIsCopied() async throws {
        let shell = RecordingShell()
        try FileManager.default.removeItem(at: root.appendingPathComponent("roms/sets/0.172/namco54.zip"))
        do { _ = try await installer(shell: shell).add(game: "galaga", system: "mame-libretro", emulator: nil); XCTFail("expected failure") }
        catch let e as InstallError { XCTAssertEqual(e, .missingRomSet("namco54")) }
        XCTAssertTrue(shell.pushes.isEmpty)
    }

    func testUnknownGameFails() async throws {
        let shell = RecordingShell()
        do { _ = try await installer(shell: shell).add(game: "nosuchgame", system: "mame-libretro", emulator: nil); XCTFail("expected failure") }
        catch let e as InstallError { XCTAssertEqual(e, .unknownGame("nosuchgame")) }
    }

    func testCopyFailureIsReportedAndStopsBeforeTheFrontendRefresh() async throws {
        let shell = RecordingShell(); shell.failPush = true
        do { _ = try await installer(shell: shell).add(game: "galaga", system: "mame-libretro", emulator: nil); XCTFail("expected failure") }
        catch let e as RemoteError { XCTAssertEqual(e, .commandFailed(status: 23, stderr: "rsync failed")) }
        XCTAssertFalse(StubURLProtocol.lastRequest?.url?.path.contains("frontend") ?? false)
    }

    func testPlanShowsWhatAnAddWouldDoWithoutCopyingAnything() async throws {
        let shell = RecordingShell()
        let plan = try await installer(shell: shell).plan(game: "galaga", system: "mame-libretro", emulator: "lr-mame2003")
        XCTAssertEqual(plan.romSets, ["galaga", "namco51", "namco54"])
        XCTAssertEqual(plan.emulator, "lr-mame2003")
        XCTAssertTrue(plan.pinsEmulator, "lr-mame2003 is not the system default, so the game would be pinned to it")
        XCTAssertEqual(plan.romFiles.map { ($0 as NSString).lastPathComponent }, ["galaga.zip", "namco51.zip", "namco54.zip"])
        XCTAssertTrue(plan.romFiles[0].hasSuffix("sets/0.172/galaga.zip"), "galaga only exists in 0.172, so that core falls back to it")
        XCTAssertEqual(Set(plan.artFiles.map { $0.type }), ["snap", "video", "wheel"])
        XCTAssertTrue(shell.pushes.isEmpty); XCTAssertTrue(shell.commands.isEmpty)
        let plain = try await installer(shell: shell).plan(game: "galaga", system: "mame-libretro", emulator: nil)
        XCTAssertFalse(plain.pinsEmulator)
        XCTAssertEqual(plain.emulator, "lr-mame2010")
    }

    func testPlansCompareByContent() async throws {
        let a = try await installer(shell: RecordingShell()).plan(game: "galaga", system: "mame-libretro", emulator: nil)
        let b = try await installer(shell: RecordingShell()).plan(game: "galaga", system: "mame-libretro", emulator: nil)
        let c = try await installer(shell: RecordingShell()).plan(game: "galaga", system: "mame-libretro", emulator: "lr-mame2003")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testPlanRefusesExactlyWhenAddWould() async throws {
        let shell = RecordingShell()
        do { _ = try await installer(shell: shell, installed: false).plan(game: "galaga", system: "mame-libretro", emulator: nil); XCTFail() }
        catch let e as InstallError { XCTAssertEqual(e, .noEmulatorInstalled(machine: "arcade2", system: "mame-libretro")) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("roms/sets/0.172/namco54.zip"))
        do { _ = try await installer(shell: shell).plan(game: "galaga", system: "mame-libretro", emulator: nil); XCTFail() }
        catch let e as InstallError { XCTAssertEqual(e, .missingRomSet("namco54")) }
    }

    func testAddUsesTheCatalogsRomSetsWithoutTheXMLDatabase() async throws {
        let shell = RecordingShell()
        StubURLProtocol.handler = { req in
            let body = req.url!.path == "/v1/emulators" ? #"{"machine":"arcade2","systems":[{"name":"mame-libretro","defaultEmulator":"lr-mame2010","hasInstalledEmulator":true,"emulators":[{"id":"lr-mame2010","installed":true,"command":"b"}]}]}"#
                : req.url!.path == "/v1/frontend/refresh" ? #"{"frontend":"attract-mode","refreshed":["X"],"errors":[]}"# : #"{"totalGames":1,"etag":"e"}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let inst = Installer(machine: machine, shell: shell, service: ServiceClient(host: "cabinet1.lan", port: 8472, session: StubURLProtocol.session),
                             master: MasterLibrary(root: root), database: nil)
        let report = try await inst.add(game: "galaga", system: "mame-libretro", emulator: nil, romSets: ["galaga", "namco51"])
        XCTAssertEqual(report.romSets, ["galaga", "namco51"])
        XCTAssertEqual(shell.pushes.filter { $0.remote.hasSuffix("/mame-libretro/") }.count, 2)
        do { _ = try await inst.add(game: "galaga", system: "mame-libretro", emulator: nil); XCTFail("needs sets or a database") }
        catch let e as InstallError { XCTAssertEqual(e, .unknownGame("galaga")) }
    }

    func testRemoveUsesTheServiceAndNeverTouchesTheMaster() async throws {
        let shell = RecordingShell()
        StubURLProtocol.respond(200, body: #"{"dryRun":false,"name":"galaga","pin":false,"remove":["mame-libretro/galaga.zip"],"removed":["mame-libretro/galaga.zip"],"system":"mame-libretro"}"#)
        let db = try MameDatabase.parse(Data(sampleMameXML.utf8))
        let inst = Installer(machine: machine, shell: shell, service: ServiceClient(host: "cabinet1.lan", port: 8472, session: StubURLProtocol.session),
                             master: MasterLibrary(root: root), database: db)
        let plan = try await inst.remove(game: "galaga", system: "mame-libretro", options: RemovalOptions(art: true), dryRun: false)
        XCTAssertEqual(plan.removed, ["mame-libretro/galaga.zip"])
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertTrue(shell.pushes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("roms/sets/0.172/galaga.zip").path))
    }
}
