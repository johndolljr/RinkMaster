import XCTest
@testable import RinkMasterCore

final class InstalledQueryTests: XCTestCase {
    private func game(_ system: String, _ name: String, emu: String?, pinned: Bool = false) -> InstalledGame {
        InstalledGame(system: system, name: name, file: name + ".zip", emulator: emu, isPinned: pinned)
    }

    private func info(_ name: String, _ title: String, year: String, maker: String, clone: String? = nil, art: Bool = true, system: String = "mame") -> GameInfo {
        GameInfo(name: name, title: title, year: year, manufacturer: maker, cloneOf: clone, artTypes: art ? ["snap"] : [], hasHistory: name == "galaga",
                 romSets: [name], system: system)
    }

    private lazy var catalog = GameCatalog(games: [
        info("galaga", "Galaga", year: "1981", maker: "Namco"),
        info("pacman", "Pac-Man", year: "1980", maker: "Namco"),
        info("mspac", "Ms. Pac-Man", year: "1981", maker: "Midway", clone: "pacman", art: false),
        info("Pitfall", "Pitfall", year: "", maker: "", art: false, system: "atari2600"),
    ])

    private lazy var inventory = MachineInventory(systems: [
        SystemInventory(name: "atari2600", defaultEmulator: "lr-stella2014", emulators: [], games: [game("atari2600", "Pitfall", emu: "lr-stella2014"), game("atari2600", "Mystery", emu: "stella", pinned: true)]),
        SystemInventory(name: "mame-libretro", defaultEmulator: "lr-mame2010", emulators: [], games: [
            game("mame-libretro", "galaga", emu: "lr-mame2010"), game("mame-libretro", "pacman", emu: "lr-mame2003", pinned: true),
            game("mame-libretro", "mspac", emu: "lr-mame2010"), game("mame-libretro", "unknownrom", emu: "lr-mame2010")]),
    ])

    private func names(_ q: InstalledQuery) -> [String] { inventory.entries(matching: q, catalog: catalog).flatMap { $0.entries.map(\.game.name) } }

    func testNoFilterListsEverythingGroupedBySystemAndSortedByTitle() {
        let groups = inventory.entries(matching: InstalledQuery(), catalog: catalog)
        XCTAssertEqual(groups.map(\.system), ["atari2600", "mame-libretro"])
        XCTAssertEqual(names(InstalledQuery()), ["Mystery", "Pitfall", "galaga", "mspac", "pacman", "unknownrom"])
        XCTAssertFalse(InstalledQuery().isFiltering)
    }

    func testSystemEmulatorAndPinnedFilters() {
        XCTAssertEqual(names(InstalledQuery(system: "atari2600")), ["Mystery", "Pitfall"])
        XCTAssertEqual(names(InstalledQuery(emulator: "lr-mame2010")), ["galaga", "mspac", "unknownrom"])
        XCTAssertEqual(names(InstalledQuery(pinnedOnly: true)), ["Mystery", "pacman"])
        XCTAssertEqual(names(InstalledQuery(system: "mame-libretro", emulator: "lr-mame2003")), ["pacman"])
        XCTAssertTrue(InstalledQuery(pinnedOnly: true).isFiltering)
    }

    func testEveryMasterFilterAppliesToCatalogedGames() {
        func q(_ g: GameQuery) -> [String] { names(InstalledQuery(game: g)) }
        XCTAssertEqual(q(GameQuery(decade: 1980)), ["galaga", "mspac", "pacman"])
        XCTAssertEqual(q(GameQuery(maker: "Midway")), ["mspac"])
        XCTAssertEqual(q(GameQuery(hideClones: true, decade: 1980)), ["galaga", "pacman"])
        XCTAssertEqual(q(GameQuery(requireArt: true)), ["galaga", "pacman"])
        XCTAssertEqual(q(GameQuery(requireHistory: true)), ["galaga"])
        XCTAssertEqual(q(GameQuery(letter: "P")), ["Pitfall", "pacman"])
        XCTAssertEqual(q(GameQuery(system: "atari2600")), ["Pitfall"])
    }

    func testTextMatchesUncatalogedGamesByNameButMetadataFiltersDropThem() {
        XCTAssertEqual(names(InstalledQuery(game: GameQuery(text: "unknown"))), ["unknownrom"])
        XCTAssertEqual(names(InstalledQuery(game: GameQuery(text: "pac-man"))), ["mspac", "pacman"])
        XCTAssertEqual(names(InstalledQuery(game: GameQuery(text: "1981"))), ["galaga", "mspac"])
        XCTAssertFalse(names(InstalledQuery(game: GameQuery(decade: 1980))).contains("unknownrom"))
    }

    func testSortByYearAndMakerKeepUnknownsLast() {
        XCTAssertEqual(names(InstalledQuery(game: GameQuery(sort: .year), system: "mame-libretro"))[0...2].map { $0 }, ["pacman", "galaga", "mspac"])
        XCTAssertEqual(names(InstalledQuery(game: GameQuery(sort: .maker), system: "mame-libretro")), ["mspac", "galaga", "pacman", "unknownrom"])
    }

    func testFacetsCountOnlyWhatTheCabinetHas() {
        let f = inventory.facets(catalog: catalog)
        XCTAssertEqual(f.systems.map { "\($0.name):\($0.count)" }, ["mame-libretro:4", "atari2600:2"])
        XCTAssertEqual(f.emulators.map { "\($0.name):\($0.count)" }, ["lr-mame2010:3", "lr-mame2003:1", "lr-stella2014:1", "stella:1"])
        XCTAssertEqual(f.decades.map { "\($0.decade):\($0.count)" }, ["1980:3"])
        XCTAssertEqual(f.makers.map { "\($0.name):\($0.count)" }, ["Namco:2", "Midway:1"])
        XCTAssertEqual(f.letters, ["G", "M", "P"])
        XCTAssertEqual(f, inventory.facets(catalog: catalog))
    }

    func testWithoutACatalogEverythingStillListsAndFiltersByTextSystemEmulator() {
        let rows = inventory.entries(matching: InstalledQuery(game: GameQuery(text: "gal")), catalog: nil)
        XCTAssertEqual(rows.flatMap { $0.entries.map(\.game.name) }, ["galaga"])
        XCTAssertEqual(rows.first?.entries.first?.title, "galaga")
        XCTAssertEqual(inventory.facets(catalog: nil).decades.count, 0)
    }
}
