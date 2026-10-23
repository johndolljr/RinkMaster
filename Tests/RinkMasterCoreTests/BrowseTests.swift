import XCTest
@testable import RinkMasterCore

private func g(_ name: String, _ title: String, year: String = "1981", maker: String = "Namco", clone: String? = nil, art: [String] = ["snap"], hist: Bool = false, system: String = "mame") -> GameInfo {
    GameInfo(name: name, title: title, year: year, manufacturer: maker, cloneOf: clone, artTypes: art, hasHistory: hist, romSets: [name], system: system)
}

final class GameInfoDisplayTests: XCTestCase {
    func testMakerStripsBracketsAndLicenseNotes() {
        XCTAssertEqual(g("a", "A", maker: "Namco").maker, "Namco")
        XCTAssertEqual(g("a", "A", maker: "[Namco] (Midway license)").maker, "Namco")
        XCTAssertEqual(g("a", "A", maker: "Taito Corporation (Romstar license)").maker, "Taito Corporation")
        XCTAssertEqual(g("a", "A", maker: "<unknown>").maker, "Unknown")
        XCTAssertEqual(g("a", "A", maker: "").maker, "Unknown")
    }

    func testDecadeFromTheYearWhenItIsKnown() {
        XCTAssertEqual(g("a", "A", year: "1981").decade, 1980)
        XCTAssertEqual(g("a", "A", year: "200?").decade, 2000)
        XCTAssertNil(g("a", "A", year: "19??").decade)
        XCTAssertNil(g("a", "A", year: "").decade)
    }

    func testLetterIsTheFirstLetterOrHashForDigitsAndSymbols() {
        XCTAssertEqual(g("a", "Galaga").letter, "G")
        XCTAssertEqual(g("a", "galaxian").letter, "G")
        XCTAssertEqual(g("a", "1942").letter, "#")
        XCTAssertEqual(g("a", "'88 Games").letter, "#")
    }
}

final class GameQueryTests: XCTestCase {
    private let games = [
        g("galaga", "Galaga", year: "1981", maker: "Namco"),
        g("galagamf", "Galaga (Midway fast shoot)", year: "1981", maker: "[Namco] (Midway license)", clone: "galaga"),
        g("pacman", "Pac-Man", year: "1980", maker: "Namco", art: []),
        g("1942", "1942", year: "1984", maker: "Capcom"),
        g("sf2", "Street Fighter II", year: "1991", maker: "Capcom", hist: true),
        g("unk", "Mystery Game", year: "19??", maker: "<unknown>"),
    ]
    private lazy var catalog = GameCatalog(games: games)
    private func installed(_ entries: [String: [String]]) -> InstalledIndex {
        var inv: [String: MachineInventory] = [:]
        for (machine, names) in entries {
            let json = #"{"machine":"\#(machine)","totalGames":\#(names.count),"systems":[{"name":"mame-libretro","defaultEmulator":"lr-mame2010","emulators":["lr-mame2010"],"games":[\#(names.map { #"{"system":"mame-libretro","name":"\#($0)","file":"\#($0).zip","emulator":"lr-mame2010","isPinned":false,"size":1,"mtime":1}"# }.joined(separator: ","))]}]}"#
            inv[machine] = try! JSONDecoder().decode(MachineInventory.self, from: Data(json.utf8))
        }
        return InstalledIndex(inventories: inv)
    }
    private func names(_ q: GameQuery, _ idx: InstalledIndex? = nil) -> [String] { catalog.query(q, installed: idx ?? installed([:])).map(\.name) }

    func testDefaultListsEverythingSortedByTitleIgnoringCase() {
        XCTAssertEqual(names(GameQuery()), ["1942", "galaga", "galagamf", "unk", "pacman", "sf2"])
    }

    func testTextSearchStillWorks() {
        XCTAssertEqual(names(GameQuery(text: "capcom")), ["1942", "sf2"])
    }

    func testHideClones() {
        XCTAssertEqual(names(GameQuery(hideClones: true)), ["1942", "galaga", "unk", "pacman", "sf2"])
    }

    func testDecadeAndMaker() {
        XCTAssertEqual(names(GameQuery(decade: 1980)), ["1942", "galaga", "galagamf", "pacman"])
        XCTAssertEqual(names(GameQuery(maker: "Namco")), ["galaga", "galagamf", "pacman"])
        XCTAssertEqual(names(GameQuery(decade: 1980, maker: "Capcom")), ["1942"])
    }

    func testLetterJump() {
        XCTAssertEqual(names(GameQuery(letter: "G")), ["galaga", "galagamf"])
        XCTAssertEqual(names(GameQuery(letter: "#")), ["1942"])
    }

    func testArtFilter() {
        XCTAssertFalse(names(GameQuery(requireArt: true)).contains("pacman"))
        XCTAssertEqual(names(GameQuery(requireHistory: true)), ["sf2"])
    }

    func testInstalledFilters() {
        let idx = installed(["arcade2": ["galaga", "pacman"], "xarcade": ["galaga", "sf2"]])
        XCTAssertEqual(names(GameQuery(installed: .notOnAnyCabinet), idx), ["1942", "galagamf", "unk"])
        XCTAssertEqual(names(GameQuery(installed: .onMachine("arcade2")), idx), ["galaga", "pacman"])
        XCTAssertEqual(names(GameQuery(installed: .onMachine("xarcade")), idx), ["galaga", "sf2"])
        XCTAssertEqual(names(GameQuery(installed: .onAnyCabinet), idx), ["galaga", "pacman", "sf2"])
    }

    func testSortByYearThenTitleAndByMaker() {
        XCTAssertEqual(names(GameQuery(sort: .year)), ["pacman", "galaga", "galagamf", "1942", "sf2", "unk"])  // unknown years last
        XCTAssertEqual(names(GameQuery(sort: .maker)), ["1942", "sf2", "galaga", "galagamf", "pacman", "unk"])
    }

    func testSystemFilterAndCounts() {
        let mixed = GameCatalog(games: games + [g("Pitfall", "Pitfall", year: "", maker: "", art: [], system: "atari2600"),
                                                g("River Raid", "River Raid", year: "", maker: "", art: [], system: "atari2600"),
                                                g("ace", "ace", year: "", maker: "", art: [], system: "daphne")])
        func n(_ q: GameQuery) -> [String] { mixed.query(q, installed: installed([:])).map(\.name) }
        XCTAssertEqual(n(GameQuery(system: "atari2600")), ["Pitfall", "River Raid"])
        XCTAssertEqual(n(GameQuery(system: "daphne")), ["ace"])
        XCTAssertEqual(n(GameQuery(system: "mame")).count, 6)
        XCTAssertEqual(n(GameQuery(system: "nes")), [])
        XCTAssertEqual(n(GameQuery(text: "river", system: "atari2600")), ["River Raid"])
        XCTAssertEqual(n(GameQuery(text: "river", system: "daphne")), [])
        XCTAssertEqual(n(GameQuery()).count, 9)
        XCTAssertEqual(mixed.systems.map { "\($0.name):\($0.count)" }, ["mame:6", "atari2600:2", "daphne:1"])
    }

    func testSameNameInTwoSystemsIsTwoGamesWithDistinctIds() {
        let both = GameCatalog(games: [g("pitfall", "Pitfall", system: "mame"), g("pitfall", "Pitfall", system: "atari2600")])
        XCTAssertEqual(both.games.map(\.id), ["pitfall", "atari2600/pitfall"])
        XCTAssertEqual(both.game("pitfall")?.system, "mame")
        XCTAssertEqual(both.game("atari2600/pitfall")?.system, "atari2600")
        XCTAssertEqual(GameCatalog(games: [g("Pitfall", "Pitfall", system: "atari2600")]).game("Pitfall")?.system, "atari2600")
    }

    func testFiltersCombine() {
        XCTAssertEqual(names(GameQuery(text: "galaga", hideClones: true, decade: 1980, maker: "Namco")), ["galaga"])
    }

    func testFacetsCountWhatIsThere() {
        XCTAssertEqual(catalog.decades.map { "\($0.decade):\($0.count)" }, ["1980:4", "1990:1"])
        XCTAssertEqual(catalog.makers.prefix(2).map { "\($0.name):\($0.count)" }, ["Namco:3", "Capcom:2"])
        XCTAssertEqual(catalog.letters, ["#", "G", "M", "P", "S"])
    }

    func testRandomPickComesFromTheResultsAndIsDeterministicWithASeed() {
        var rng = SeededGenerator(seed: 7)
        let pick = catalog.randomGame(matching: GameQuery(maker: "Capcom"), installed: installed([:]), using: &rng)
        XCTAssertTrue(["1942", "sf2"].contains(pick?.name ?? ""))
        var empty = SeededGenerator(seed: 1)
        XCTAssertNil(catalog.randomGame(matching: GameQuery(text: "zzz"), installed: installed([:]), using: &empty))
    }
}

final class PagerTests: XCTestCase {
    func testPagesAndRanges() {
        let p = Pager(total: 250, pageSize: 100)
        XCTAssertEqual(p.pageCount, 3)
        XCTAssertEqual(p.range(page: 0), 0..<100)
        XCTAssertEqual(p.range(page: 2), 200..<250)
        XCTAssertEqual(p.range(page: 9), 200..<250)  // clamped
        XCTAssertEqual(p.range(page: -1), 0..<100)
        XCTAssertEqual(p.label(page: 1), "101-200 OF 250")
    }

    func testEmptyAndExact() {
        XCTAssertEqual(Pager(total: 0, pageSize: 100).pageCount, 1)
        XCTAssertEqual(Pager(total: 0, pageSize: 100).range(page: 0), 0..<0)
        XCTAssertEqual(Pager(total: 0, pageSize: 100).label(page: 0), "NO GAMES")
        XCTAssertEqual(Pager(total: 200, pageSize: 100).pageCount, 2)
        XCTAssertEqual(Pager(total: 5, pageSize: 100).label(page: 0), "1-5 OF 5")
    }

    func testPageContainingAnIndex() {
        let p = Pager(total: 250, pageSize: 100)
        XCTAssertEqual(p.page(containing: 0), 0); XCTAssertEqual(p.page(containing: 199), 1); XCTAssertEqual(p.page(containing: 249), 2)
    }
}

final class PlayerRankingsTests: XCTestCase {
    private func table(_ rows: [(String, Int)], columns: [String] = ["RANK", "SCORE", "NAME"]) -> ScoreTable {
        ScoreTable(columns: columns, rows: rows.enumerated().map { ["\($0.offset + 1)", String($0.element.1), $0.element.0] })
    }
    private func entry(_ machine: String, _ game: String, _ rows: [(String, Int)], core: String = "c") -> CollectedScore {
        CollectedScore(machine: machine, file: ScoreFile(core: core, kind: "hi", game: game, size: 1, mtime: 1), table: table(rows), note: nil, data: Data([1]))
    }

    func testPlayersAreRankedByPointsAcrossGames() {
        let u = UnifiedScores(entries: [
            entry("arcade2", "galaga", [("JON", 300), ("JJD", 200), ("ABE", 100)]),
            entry("arcade2", "tempest", [("JJD", 900), ("JON", 800)]),
            entry("arcade2", "pacman", [("JON", 50)]),
        ])
        let r = PlayerRankings.build(from: u)
        XCTAssertEqual(r.map(\.name), ["JON", "JJD", "ABE"])
        let jon = r[0]
        XCTAssertEqual(jon.firstPlaces, 2)  // galaga and pacman
        XCTAssertEqual(jon.games.count, 3)
        XCTAssertEqual(jon.points, 10 + 9 + 10)  // 1st galaga, 2nd tempest, 1st pacman
        XCTAssertEqual(r[1].points, 9 + 10)
        XCTAssertEqual(r[1].firstPlaces, 1)
        XCTAssertEqual(r[2].points, 8)
    }

    func testAPlayersBestScorePerGameAcrossMachinesAndCoresCounts() {
        let u = UnifiedScores(entries: [
            entry("arcade2", "galaga", [("JON", 300), ("JJD", 250)], core: "mame2010"),
            entry("xarcade", "galaga", [("JJD", 400), ("JON", 100)], core: "mame2010"),
            entry("xarcade", "galaga", [("JON", 50)], core: "mame2003"),
        ])
        let r = PlayerRankings.build(from: u)
        let galaga = r.flatMap { p in p.games.map { (p.name, $0) } }
        XCTAssertEqual(galaga.count, 2, "one result per player and game, not per file")
        XCTAssertEqual(r.first { $0.name == "JJD" }?.games.first?.score, 400)
        XCTAssertEqual(r.first { $0.name == "JJD" }?.games.first?.rank, 1)
        XCTAssertEqual(r.first { $0.name == "JON" }?.games.first?.score, 300)
        XCTAssertEqual(r.first { $0.name == "JON" }?.games.first?.rank, 2)
        XCTAssertEqual(r.first { $0.name == "JJD" }?.games.first?.machine, "xarcade")
    }

    func testBlankNamesAndUnreadableTablesAreSkipped() {
        let noName = ScoreTable(columns: ["RANK", "SCORE"], rows: [["1", "100"]])
        let u = UnifiedScores(entries: [
            entry("a", "g", [("", 900), ("  ", 800), ("JON", 10)]),
            CollectedScore(machine: "a", file: ScoreFile(core: "c", kind: "hi", game: "h", size: 1, mtime: 1), table: noName, note: nil),
            CollectedScore(machine: "a", file: ScoreFile(core: "c", kind: "hi", game: "i", size: 1, mtime: 1), table: nil, note: "x"),
        ])
        XCTAssertEqual(PlayerRankings.build(from: u).map(\.name), ["JON"])
    }

    func testNamesAreComparedIgnoringCaseAndPadding() {
        let u = UnifiedScores(entries: [entry("a", "g", [("jon ", 5)]), entry("b", "h", [("JON", 5)])])
        let r = PlayerRankings.build(from: u)
        XCTAssertEqual(r.count, 1); XCTAssertEqual(r[0].name, "JON"); XCTAssertEqual(r[0].games.count, 2)
    }

    func testTiesShareARankAndPoints() {
        let u = UnifiedScores(entries: [entry("a", "g", [("ABE", 100), ("BOB", 100), ("CAL", 50)])])
        let r = PlayerRankings.build(from: u)
        XCTAssertEqual(r.first { $0.name == "ABE" }?.games.first?.rank, 1)
        XCTAssertEqual(r.first { $0.name == "BOB" }?.games.first?.rank, 1)
        XCTAssertEqual(r.first { $0.name == "CAL" }?.games.first?.rank, 3)
    }

    func testPointsStopAtTenthPlaceAndTiesBreakByFirstsThenName() {
        let rows = (1...12).map { ("P\($0)", 1000 - $0) }
        let r = PlayerRankings.build(from: UnifiedScores(entries: [entry("a", "g", rows)]))
        XCTAssertEqual(r.first { $0.name == "P10" }?.points, 1)
        XCTAssertEqual(r.first { $0.name == "P11" }?.points, 0)
        let tie = PlayerRankings.build(from: UnifiedScores(entries: [entry("a", "g", [("ZED", 5)]), entry("a", "h", [("ABE", 5)])]))
        XCTAssertEqual(tie.map(\.name), ["ABE", "ZED"])
    }

    func testFactoryDefaultInitialsAreNotPlayers() {
        let rows = [("AAA", 900), ("BBB", 800), ("A.A", 700), ("N.N", 600), ("...", 500), ("---", 400), ("   ", 300), ("JON", 200), ("JJD", 100), ("ED", 50), ("A1B", 40)]
        let r = PlayerRankings.build(from: UnifiedScores(entries: [entry("a", "g", rows)]))
        XCTAssertEqual(r.map(\.name).sorted(), ["A1B", "ED", "JJD", "JON"])
        XCTAssertEqual(r.first { $0.name == "JON" }?.games.first?.rank, 1, "defaults do not take up places")
        XCTAssertTrue(PlayerRankings.isPlaceholder("ZZZ"))
        XCTAssertFalse(PlayerRankings.isPlaceholder("ZZA"))
    }

    func testPlayersCanBeLimitedToOneMachine() {
        let u = UnifiedScores(entries: [entry("arcade2", "g", [("JON", 5)]), entry("xarcade", "g", [("JJD", 9)])])
        XCTAssertEqual(PlayerRankings.build(from: u, machine: "arcade2").map(\.name), ["JON"])
    }
}

final class ListNavigationTests: XCTestCase {
    func testRowsThatFitTheWindowWithAFloor() {
        XCTAssertEqual(ListNavigation.rows(forHeight: 720, rowHeight: 36), 20)
        XCTAssertEqual(ListNavigation.rows(forHeight: 725, rowHeight: 36), 20)  // a partial row is not shown
        XCTAssertEqual(ListNavigation.rows(forHeight: 60, rowHeight: 36), 5)    // tiny window keeps a minimum
        XCTAssertEqual(ListNavigation.rows(forHeight: .infinity, rowHeight: 36), 5)
        XCTAssertEqual(ListNavigation.rows(forHeight: 500, rowHeight: 0), 5)
    }

    func testUpAndDownMoveOneGameAndStopAtTheEnds() {
        XCTAssertEqual(ListNavigation.step(selected: 3, delta: 1, count: 10), 4)
        XCTAssertEqual(ListNavigation.step(selected: 3, delta: -1, count: 10), 2)
        XCTAssertEqual(ListNavigation.step(selected: 0, delta: -1, count: 10), 0)
        XCTAssertEqual(ListNavigation.step(selected: 9, delta: 1, count: 10), 9)
        XCTAssertNil(ListNavigation.step(selected: nil, delta: 1, count: 0))
    }

    func testWithNothingSelectedDownPicksTheFirstAndUpTheLast() {
        XCTAssertEqual(ListNavigation.step(selected: nil, delta: 1, count: 10), 0)
        XCTAssertEqual(ListNavigation.step(selected: nil, delta: -1, count: 10), 9)
        XCTAssertEqual(ListNavigation.step(selected: 50, delta: 1, count: 10), 0)  // a stale selection counts as none
    }

    func testLeftAndRightChangePageAndStopAtTheEnds() {
        XCTAssertEqual(ListNavigation.page(current: 2, delta: 1, pageCount: 5), 3)
        XCTAssertEqual(ListNavigation.page(current: 2, delta: -1, pageCount: 5), 1)
        XCTAssertEqual(ListNavigation.page(current: 0, delta: -1, pageCount: 5), 0)
        XCTAssertEqual(ListNavigation.page(current: 4, delta: 1, pageCount: 5), 4)
        XCTAssertEqual(ListNavigation.page(current: 0, delta: 1, pageCount: 0), 0)
    }

    func testStepAcrossAPageEdgeLandsOnThePageOfTheNewGame() {
        let pager = Pager(total: 40, pageSize: 18)
        let i = ListNavigation.step(selected: 17, delta: 1, count: 40)!
        XCTAssertEqual(pager.page(containing: i), 1)
    }
}
