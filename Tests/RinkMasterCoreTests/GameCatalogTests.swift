import XCTest
@testable import RinkMasterCore

final class GameCatalogTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = try makeMasterTree([
            "roms/sets/0.172/galaga.zip", "roms/sets/0.172/pacman.zip", "roms/sets/0.172/puckman.zip", "roms/sets/0.172/namco51.zip",
            "roms/sets/0.172/neogeo.zip", "roms/sets/0.172/mslug.zip", "roms/sets/0.078/galaga.zip", "roms/extras/zzzunknown.zip",
            "roms/other-systems/atari2600/Adventure.bin",
            "artwork/best/snap/galaga.png", "artwork/best/wheel/galaga.png", "artwork/best/cabinet/galaga.png", "artwork/best/video/galaga.mp4",
        ])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testRomSetNamesSpanSetsAndExtrasWithoutDuplicates() {
        let names = MasterLibrary(root: root).allRomSetNames()
        XCTAssertEqual(names, ["galaga", "mslug", "namco51", "neogeo", "pacman", "puckman", "zzzunknown"])
    }

    private func catalog(history: String = sampleHistory) throws -> GameCatalog {
        GameCatalog(master: MasterLibrary(root: root), database: try MameDatabase.parse(Data(sampleMameXML.utf8)), history: HistoryDatabase.parse(history))
    }

    func testCatalogListsRunnableGamesOnly() throws {
        let games = try catalog().games.filter(\.isMame)
        XCTAssertEqual(games.map(\.name), ["galaga", "mslug", "pacman", "puckman"])  // no devices (namco51), BIOS (neogeo) or sets unknown to the XML
    }

    func testGameInfoCombinesXMLArtAndHistory() throws {
        let g = try XCTUnwrap(try catalog().game("galaga"))
        XCTAssertEqual(g.title, "Galaga (Namco rev. B)")
        XCTAssertEqual(g.year, "1981")
        XCTAssertEqual(g.manufacturer, "Namco")
        XCTAssertNil(g.cloneOf)
        XCTAssertEqual(g.artTypes, ["snap", "video", "wheel", "cabinet"].sorted())
        XCTAssertTrue(g.hasHistory)
        XCTAssertFalse(try XCTUnwrap(try catalog().game("mslug")).hasHistory)
        XCTAssertEqual(try XCTUnwrap(try catalog().game("pacman")).cloneOf, "puckman")
    }

    func testSearchMatchesTitleNameYearAndManufacturer() throws {
        let c = try catalog()
        XCTAssertEqual(c.search("pac").map(\.name), ["pacman"])
        XCTAssertEqual(c.search("puck").map(\.name), ["puckman"])
        XCTAssertEqual(c.search("1981").map(\.name), ["galaga"])
        XCTAssertEqual(c.search("NAZCA").map(\.name), ["mslug"])
        XCTAssertEqual(c.search("  ").count, 5)  // four arcade games and the atari2600 file in the fixture
        XCTAssertTrue(c.search("zzz").isEmpty)
    }

    func testArtURLsForTheDetailView() throws {
        let art = MasterLibrary(root: root).artURL(type: "snap", game: "galaga")
        XCTAssertEqual(art?.lastPathComponent, "galaga.png")
        XCTAssertNil(MasterLibrary(root: root).artURL(type: "snap", game: "nosuch"))
        XCTAssertEqual(MasterLibrary(root: root).artURL(type: "cabinet", game: "galaga")?.lastPathComponent, "galaga.png")
    }

    func testInstalledOnMapsGamesToMachinesAndEmulators() throws {
        let inv = try JSONDecoder().decode(MachineInventory.self, from: Data(sampleInventoryJSON.utf8))
        let map = InstalledIndex(inventories: ["arcade2": inv])
        XCTAssertEqual(map.entries(for: "galaga").map(\.machine), ["arcade2"])
        XCTAssertEqual(map.entries(for: "galaga").first?.emulator, "lr-mame2010")
        XCTAssertTrue(map.entries(for: "pacman").isEmpty)
        XCTAssertEqual(map.entries(for: "tempest").first?.system, "mame-libretro")
    }
}
