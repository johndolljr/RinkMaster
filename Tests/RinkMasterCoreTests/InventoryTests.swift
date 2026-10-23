import XCTest
@testable import RinkMasterCore

final class InventoryParserTests: XCTestCase {
    private let output = """
    @@SYSTEM mame-libretro
    f galaga.zip
    f galaga.zip.cfg
    d snap
    f tempest.zip
    d mame2003
    f mk2.state
    @@CFG mame-libretro
    lr-mame2003 = "retroarch -L a %ROM%"
    default = "lr-mame2010"
    lr-mame2010 = "retroarch -L b %ROM%"
    @@SYSTEM daphne
    d lair.daphne
    d roms
    @@CFG daphne
    daphne = "daphne %ROM%"
    default = "daphne"
    @@SYSTEM atari2600
    f Adventure.bin
    d snap
    f notes.txt
    @@CFG atari2600
    default = "lr-stella2014"
    @@SYSTEM nes
    d snap
    @@CFG nes
    @@PINS
    mame-libretro_tempest = "lr-mame2003"
    atari2600_Adventure = "stella"
    """

    func testGroupsGamesBySystemAndSkipsSystemsWithNoGames() {
        let inv = InventoryParser.parse(output)
        XCTAssertEqual(inv.systems.map(\.name), ["atari2600", "daphne", "mame-libretro"])
        XCTAssertEqual(inv.totalGames, 4)
    }

    func testMameGamesIgnoreCfgStateAndFolders() {
        let mame = InventoryParser.parse(output).systems.first { $0.name == "mame-libretro" }!
        XCTAssertEqual(mame.games.map(\.name), ["galaga", "tempest"])
        XCTAssertEqual(mame.games[0].file, "galaga.zip")
    }

    func testEmulatorIsPinOrSystemDefault() {
        let mame = InventoryParser.parse(output).systems.first { $0.name == "mame-libretro" }!
        let galaga = mame.games.first { $0.name == "galaga" }!
        let tempest = mame.games.first { $0.name == "tempest" }!
        XCTAssertEqual(galaga.emulator, "lr-mame2010")
        XCTAssertFalse(galaga.isPinned)
        XCTAssertEqual(tempest.emulator, "lr-mame2003")
        XCTAssertTrue(tempest.isPinned)
        XCTAssertEqual(mame.defaultEmulator, "lr-mame2010")
        XCTAssertEqual(mame.emulators, ["lr-mame2003", "lr-mame2010"])
    }

    func testDaphneGamesAreDaphneFoldersAndNameDropsExtension() {
        let daphne = InventoryParser.parse(output).systems.first { $0.name == "daphne" }!
        XCTAssertEqual(daphne.games.map(\.name), ["lair"])
        XCTAssertEqual(daphne.games[0].file, "lair.daphne")
    }

    func testOtherSystemsKeepRomFilesButNotNotesOrArt() {
        let atari = InventoryParser.parse(output).systems.first { $0.name == "atari2600" }!
        XCTAssertEqual(atari.games.map(\.name), ["Adventure"])
        XCTAssertEqual(atari.games[0].emulator, "stella")  // pinned override
    }

    func testGamesGroupedByEmulator() {
        let mame = InventoryParser.parse(output).systems.first { $0.name == "mame-libretro" }!
        let grouped = mame.gamesByEmulator
        XCTAssertEqual(grouped["lr-mame2010"]?.map(\.name), ["galaga"])
        XCTAssertEqual(grouped["lr-mame2003"]?.map(\.name), ["tempest"])
    }

    func testEmptyOutputIsEmptyInventory() {
        XCTAssertTrue(InventoryParser.parse("").systems.isEmpty)
    }

    func testGameWithoutAnyEmulatorHasNilEmulator() {
        let inv = InventoryParser.parse("@@SYSTEM foo\nf a.rom\n@@CFG foo\n@@PINS\n")
        XCTAssertNil(inv.systems[0].games[0].emulator)
    }
}

private struct FakeShell: RemoteShell {
    var output = ""
    var error: Error?
    let recorder = Recorder()
    final class Recorder: @unchecked Sendable { var commands: [String] = [] }
    func run(_ command: String) async throws -> CommandResult {
        recorder.commands.append(command)
        if let error { throw error }
        return CommandResult(status: 0, stdout: output, stderr: "")
    }
    func fetch(remotePath: String, to localPath: String) async throws -> CommandResult { fatalError("unused") }
    func push(localPath: String, toRemotePath remotePath: String) async throws -> CommandResult { fatalError("unused") }
}

final class InventoryReaderTests: XCTestCase {
    func testReadRunsOneCommandWithQuotedRomsPathAndParses() async throws {
        let shell = FakeShell(output: "@@SYSTEM mame-libretro\nf galaga.zip\n@@CFG mame-libretro\ndefault = \"lr-mame2010\"\n@@PINS\n")
        let machine = Machine(name: "arcade2", user: "pi", host: "h", frontend: .attractMode, romsPath: "/home/pi/Retro Pie/roms")
        let inv = try await InventoryReader(shell: shell, machine: machine).read()
        XCTAssertEqual(inv.totalGames, 1)
        XCTAssertEqual(shell.recorder.commands.count, 1)
        XCTAssertTrue(shell.recorder.commands[0].contains("'/home/pi/Retro Pie/roms'"))
        XCTAssertTrue(shell.recorder.commands[0].contains("/opt/retropie/configs/all/emulators.cfg"))
    }

    func testReadPropagatesRemoteErrors() async {
        let shell = FakeShell(error: RemoteError.commandFailed(status: 255, stderr: "unreachable"))
        let machine = Machine(name: "x", user: "pi", host: "h", frontend: .attractMode)
        do { _ = try await InventoryReader(shell: shell, machine: machine).read(); XCTFail("expected error") }
        catch let e as RemoteError { XCTAssertEqual(e, .commandFailed(status: 255, stderr: "unreachable")) }
        catch { XCTFail("wrong error \(error)") }
    }
}
