import XCTest
@testable import RinkMasterCore

/// Builds a fake NAS master tree in a temp dir.
func makeMasterTree(_ files: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("master-\(UUID().uuidString)")
    for rel in files {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(rel.utf8).write(to: url)
    }
    return root
}

final class MasterLibraryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = try makeMasterTree([
            "roms/sets/0.172/galaga.zip", "roms/sets/0.078/galaga.zip", "roms/sets/0.161/galaga.zip",
            "roms/sets/0.172/namco51.zip", "roms/sets/0.172/pacman.zip",
            "roms/extras/pacman.zip", "roms/extras/alt-abc123/ssf2t.zip", "roms/sets/0.172/ssf2t.zip",
            "artwork/best/snap/galaga.png", "artwork/best/video/galaga.mp4", "artwork/best/wheel/galaga.png",
            "artwork/best/marquee/galaga.png", "artwork/best/flyer/galaga.png", "artwork/best/title/galaga.png",
            "artwork/best/cabinet/galaga.png",
        ])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testACoreFallsBackToTheNearestSetVersionThatHasTheGame() throws {
        let tree = try makeMasterTree(["roms/sets/0.078/a.zip", "roms/sets/0.106/tron.zip", "roms/sets/0.161/tron.zip", "roms/sets/0.172/tron.zip", "roms/sets/0.172/pong.zip"])
        defer { try? FileManager.default.removeItem(at: tree) }
        let lib = MasterLibrary(root: tree)
        XCTAssertEqual(lib.locate(romSet: "tron", emulator: "lr-mame2003")?.deletingLastPathComponent().lastPathComponent, "0.106")
        XCTAssertEqual(lib.locate(romSet: "pong", emulator: "lr-mame2003")?.deletingLastPathComponent().lastPathComponent, "0.172")
        XCTAssertEqual(lib.locate(romSet: "tron", emulator: "lr-mame2016")?.deletingLastPathComponent().lastPathComponent, "0.172")
        XCTAssertEqual(lib.locate(romSet: "tron")?.deletingLastPathComponent().lastPathComponent, "0.172")
    }

    func testDefaultOrderPrefersExtrasThenNewestSet() {
        let lib = MasterLibrary(root: root)
        XCTAssertEqual(lib.locate(romSet: "galaga")?.path.hasSuffix("roms/sets/0.172/galaga.zip"), true)
        XCTAssertEqual(lib.locate(romSet: "pacman")?.path.hasSuffix("roms/extras/pacman.zip"), true)
        XCTAssertEqual(lib.locate(romSet: "ssf2t")?.path.hasSuffix("roms/extras/alt-abc123/ssf2t.zip"), true)
    }

    func testEmulatorPreferenceSelectsTheMatchingSetVersion() {
        let lib = MasterLibrary(root: root)
        XCTAssertEqual(lib.locate(romSet: "galaga", emulator: "lr-mame2003")?.path.hasSuffix("sets/0.078/galaga.zip"), true)
        XCTAssertEqual(lib.locate(romSet: "galaga", emulator: "lr-mame2015")?.path.hasSuffix("sets/0.161/galaga.zip"), true)
        XCTAssertEqual(lib.locate(romSet: "galaga", emulator: "lr-mame2016")?.path.hasSuffix("sets/0.172/galaga.zip"), true)
        // namco51 only exists in 0.172, so any emulator falls back to it
        XCTAssertEqual(lib.locate(romSet: "namco51", emulator: "lr-mame2003")?.path.hasSuffix("sets/0.172/namco51.zip"), true)
    }

    func testMissingSetIsNil() {
        XCTAssertNil(MasterLibrary(root: root).locate(romSet: "nosuchgame"))
    }

    func testArtFilesForAGameByType() {
        let art = MasterLibrary(root: root).artFiles(for: "galaga")
        XCTAssertEqual(Set(art.map(\.type)), ["snap", "video", "wheel", "marquee", "flyer", "title"])  // cabinet art is not copied to cabinets
        XCTAssertEqual(art.first { $0.type == "video" }?.url.lastPathComponent, "galaga.mp4")
        XCTAssertTrue(MasterLibrary(root: root).artFiles(for: "nosuchgame").isEmpty)
    }

    func testArtTypesMapToCabinetFolders() {
        XCTAssertEqual(MasterLibrary.cabinetArtFolder(forMasterType: "video"), "snap")
        XCTAssertEqual(MasterLibrary.cabinetArtFolder(forMasterType: "snap"), "snap")
        XCTAssertEqual(MasterLibrary.cabinetArtFolder(forMasterType: "wheel"), "wheel")
    }

    func testRomsRootIsReachableCheck() {
        XCTAssertTrue(MasterLibrary(root: root).isAvailable)
        XCTAssertFalse(MasterLibrary(root: root.appendingPathComponent("nope")).isAvailable)
    }

    func testOtherSystemGamesComeFromTheFilesAndFoldersOfEachSystem() throws {
        let tree = try makeMasterTree([
            "roms/other-systems/atari2600/Pitfall.bin", "roms/other-systems/atari2600/River Raid.bin", "roms/other-systems/atari2600/.DS_Store",
            "roms/other-systems/atari2600/._Pitfall.bin", "roms/other-systems/atari2600/.hidden",
            "roms/other-systems/atari2600/BIOS/readme.txt", "roms/other-systems/atari2600/emulationstation/x.txt",
            "roms/other-systems/daphne/ace.daphne/ace.txt", "roms/other-systems/daphne/Dragons_Lair.daphne/dl.zip",
            "roms/other-systems/daphne/roms/ace.zip", "roms/other-systems/daphne/Bios",
            "roms/other-systems/BIOS/a.bin", "roms/other-systems/EmulationStation/b.bin", "roms/other-systems/.hidden/c.bin",
            "roms/other-systems/nes/mario.nes", "roms/other-systems/stray-file.txt",
        ])
        defer { try? FileManager.default.removeItem(at: tree) }
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("roms/other-systems/empty"), withIntermediateDirectories: true)
        let games = MasterLibrary(root: tree).otherSystemGames()
        XCTAssertEqual(games.map { "\($0.system)/\($0.name)" }, ["atari2600/Pitfall", "atari2600/River Raid", "daphne/ace", "daphne/Dragons_Lair", "nes/mario"])
        let pitfall = try XCTUnwrap(games.first { $0.name == "Pitfall" })
        XCTAssertEqual(pitfall.system, "atari2600"); XCTAssertEqual(pitfall.title, "Pitfall")
        XCTAssertEqual(pitfall.sourcePath, "roms/other-systems/atari2600/Pitfall.bin")
        XCTAssertTrue(pitfall.romSets.isEmpty); XCTAssertTrue(pitfall.artTypes.isEmpty); XCTAssertFalse(pitfall.hasHistory)
        let ace = try XCTUnwrap(games.first { $0.name == "ace" })
        XCTAssertEqual(ace.sourcePath, "roms/other-systems/daphne/ace.daphne")  // the folder is what gets installed
        XCTAssertEqual(ace.id, "daphne/ace")
    }

    func testOtherSystemGamesAreEmptyWithoutTheFolder() {
        XCTAssertTrue(MasterLibrary(root: root).otherSystemGames().isEmpty)
    }
}
