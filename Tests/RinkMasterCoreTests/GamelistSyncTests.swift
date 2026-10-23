import XCTest
@testable import RinkMasterCore

final class GamelistSyncTests: XCTestCase {
    private func installed(_ system: String, _ name: String, file: String? = nil) -> InstalledGame {
        InstalledGame(system: system, name: name, file: file ?? name + ".zip", emulator: nil, isPinned: false)
    }

    private let galaga = GameInfo(name: "galaga", title: "Galaga", year: "1981", manufacturer: "Namco", cloneOf: nil, artTypes: [], hasHistory: true, romSets: ["galaga"])

    func testAMameGameGetsTitleYearMakerAndDescription() throws {
        let e = try XCTUnwrap(GamelistSync.entry(for: installed("mame-libretro", "galaga"), info: galaga, description: "Shoot the bugs.", scraped: nil))
        XCTAssertEqual(e, ["path": "./galaga.zip", "name": "Galaga", "releasedate": "19810101T000000", "developer": "Namco", "desc": "Shoot the bugs."])
    }

    func testUnknownYearAndMakerAreLeftOut() throws {
        let odd = GameInfo(name: "x", title: "X", year: "19??", manufacturer: "<unknown>", cloneOf: nil, artTypes: [], hasHistory: false, romSets: [])
        XCTAssertEqual(GamelistSync.entry(for: installed("arcade", "x"), info: odd, description: nil, scraped: nil), ["path": "./x.zip", "name": "X"])
    }

    func testAGameTheMasterDoesNotKnowIsSkipped() {
        XCTAssertNil(GamelistSync.entry(for: installed("mame-libretro", "mystery"), info: nil, description: nil, scraped: nil))
    }

    func testAScrapedGameUsesTheMastersGamelist() throws {
        var s = GamelistEntry(); s.name = "ActRaiser"; s.desc = "Angel."; s.releaseDate = "19901221T000000"; s.developer = "Quintet"; s.publisher = "Enix"; s.genre = "Action"
        let e = try XCTUnwrap(GamelistSync.entry(for: installed("snes", "ActRaiser (USA)"), info: nil, description: nil, scraped: s))
        XCTAssertEqual(e["path"], "./ActRaiser (USA).zip"); XCTAssertEqual(e["name"], "ActRaiser"); XCTAssertEqual(e["publisher"], "Enix")
        XCTAssertEqual(e["genre"], "Action"); XCTAssertEqual(e["releasedate"], "19901221T000000")
        var nameless = GamelistEntry(); nameless.desc = "Only a description."
        XCTAssertEqual(GamelistSync.entry(for: installed("snes", "Bare"), info: nil, description: nil, scraped: nameless)?["name"], "Bare")
    }

    func testEntriesGroupBySystemAndHonourOnly() {
        let inv = MachineInventory(systems: [
            SystemInventory(name: "mame-libretro", defaultEmulator: nil, emulators: [], games: [installed("mame-libretro", "galaga"), installed("mame-libretro", "mystery")]),
            SystemInventory(name: "snes", defaultEmulator: nil, emulators: [], games: [installed("snes", "ActRaiser (USA)")]),
        ])
        let catalog = GameCatalog(games: [galaga])
        var s = GamelistEntry(); s.name = "ActRaiser"
        func run(only: Set<String>? = nil) -> [String] {
            GamelistSync.entries(inventory: inv, catalog: catalog, only: only, description: { _ in "d" }, scraped: { $1 == "ActRaiser (USA)" ? s : nil })
                .map { "\($0.system):\($0.games.count)" }
        }
        XCTAssertEqual(run(), ["mame-libretro:1", "snes:1"])
        XCTAssertEqual(run(only: ["galaga"]), ["mame-libretro:1"])
        XCTAssertEqual(run(only: ["snes/ActRaiser (USA)"]), ["snes:1"])
        XCTAssertEqual(run(only: ["nothing"]), [])
    }

    func testDescriptionIsTheOpeningTextCutAtASentence() {
        let text = "A short intro. It continues.\n\n- TECHNICAL -\n\nSpecs here."
        XCTAssertEqual(GamelistSync.shortDescription(text), "A short intro. It continues.")
        let long = String(repeating: "Word. ", count: 400)
        let d = GamelistSync.shortDescription(long, limit: 100)
        XCTAssertTrue(d!.hasSuffix("Word.")); XCTAssertLessThanOrEqual(d!.count, 100)
        XCTAssertEqual(GamelistSync.shortDescription(String(repeating: "x", count: 300), limit: 100)?.suffix(3), "...")
        XCTAssertNil(GamelistSync.shortDescription(nil)); XCTAssertNil(GamelistSync.shortDescription("- TECHNICAL -\nonly"))
    }
}

final class RomRepairTests: XCTestCase {
    func testFindsDeviceAndParentSetsMissingOnTheCabinetAndWhereTheMasterHasThem() throws {
        let tree = try makeMasterTree(["roms/sets/0.172/namcoc76.zip", "roms/sets/0.172/tekken3.zip"])
        defer { try? FileManager.default.removeItem(at: tree) }
        func game(_ n: String) -> InstalledGame { InstalledGame(system: "mame-libretro", name: n, file: n + ".zip", emulator: "lr-mame2016", isPinned: false) }
        let inv = MachineInventory(systems: [SystemInventory(name: "mame-libretro", defaultEmulator: "lr-mame2016", emulators: [], games: [game("tekken"), game("tekken3ua"), game("galaga")])])
        func info(_ n: String, _ sets: [String]) -> GameInfo { GameInfo(name: n, title: n, year: "1994", manufacturer: "Namco", cloneOf: nil, artTypes: [], hasHistory: false, romSets: sets) }
        let catalog = GameCatalog(games: [info("tekken", ["tekken", "namcoc76"]), info("tekken3ua", ["tekken3ua", "tekken3"]), info("galaga", ["galaga", "namco51"])])
        let plan = RomRepair.plan(inventory: inv, catalog: catalog, master: MasterLibrary(root: tree))
        XCTAssertEqual(plan.map(\.set), ["namco51", "namcoc76", "tekken3"])
        XCTAssertNil(plan[0].source)                                   // the master has no copy: reported, not copied
        XCTAssertEqual(plan[1].neededBy, ["tekken"])
        XCTAssertEqual(plan[2].source?.lastPathComponent, "tekken3.zip")
        let done = MachineInventory(systems: [SystemInventory(name: "mame-libretro", defaultEmulator: nil, emulators: [], games: inv.systems[0].games + [game("namcoc76"), game("tekken3"), game("namco51")])])
        XCTAssertTrue(RomRepair.plan(inventory: done, catalog: catalog, master: MasterLibrary(root: tree)).isEmpty)
    }
}
