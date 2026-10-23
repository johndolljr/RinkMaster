import XCTest
@testable import RinkMasterCore

final class HistoryIndexTests: XCTestCase {
    private func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).dat")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testIndexFindsEveryArcadeNameWithoutKeepingTheText() throws {
        let index = HistoryIndex.scan(Data(sampleHistory.utf8))
        XCTAssertEqual(Set(index.spans.keys), ["galaga", "galagao", "pacman"])
        XCTAssertNil(index.spans["100mandk"])  // another system's entry
        XCTAssertEqual(index.spans["galaga"], index.spans["galagao"])
    }

    func testTextReadFromTheFileMatchesTheFullParser() throws {
        let url = try file(sampleHistory); defer { try? FileManager.default.removeItem(at: url) }
        let index = HistoryIndex.scan(Data(sampleHistory.utf8))
        let full = HistoryDatabase.parse(sampleHistory)
        for name in ["galaga", "galagao", "pacman"] {
            XCTAssertEqual(index.text(for: name, in: url), full.text(for: name), name)
        }
        XCTAssertNil(index.text(for: "nope", in: url))
    }

    func testSectionsComeFromTheTextOnDemand() throws {
        let url = try file(sampleHistory); defer { try? FileManager.default.removeItem(at: url) }
        let index = HistoryIndex.scan(Data(sampleHistory.utf8))
        XCTAssertEqual(index.sections(for: "galaga", in: url), HistoryDatabase.parse(sampleHistory).sections(for: "galaga"))
    }

    func testMissingFileOrEmptyInput() {
        XCTAssertNil(HistoryIndex.scan(Data("$info=lone,\n$bio\n\nText.\n".utf8)).text(for: "lone", in: URL(fileURLWithPath: "/nonexistent")))
        XCTAssertTrue(HistoryIndex.scan(Data()).spans.isEmpty)
    }

    func testEntryWithoutTrailingEndStillIndexes() throws {
        let text = "$info=lone,\n$bio\n\nText only.\n"
        let url = try file(text); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(HistoryIndex.scan(Data(text.utf8)).text(for: "lone", in: url), "Text only.")
    }
}

final class CatalogCacheTests: XCTestCase {
    private func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).json") }

    func testRoundTripAndBadCache() throws {
        let u = url(); defer { try? FileManager.default.removeItem(at: u) }
        let cache = CatalogCache(xmlSignature: "1-2", historySignature: "3-4", knownNames: ["a", "b"],
                                 games: [GameInfo(name: "a", title: "A", year: "1981", manufacturer: "M", cloneOf: nil, artTypes: ["snap"], hasHistory: true, romSets: ["a", "dev"])],
                                 history: ["a": HistoryIndex.Span(offset: 10, length: 20)], builtAt: Date(timeIntervalSince1970: 1_700_000_000))
        try CatalogCache.save(cache, to: u)
        XCTAssertEqual(CatalogCache.load(from: u), cache)
        XCTAssertNil(CatalogCache.load(from: url()))
        try "junk".write(to: u, atomically: true, encoding: .utf8)
        XCTAssertNil(CatalogCache.load(from: u))
    }

    func testAnOlderCacheVersionIsIgnored() throws {
        let u = url(); defer { try? FileManager.default.removeItem(at: u) }
        var cache = CatalogCache(xmlSignature: "x", historySignature: "y", knownNames: [], games: [], history: [:], builtAt: Date())
        cache.version = 0
        try CatalogCache.save(cache, to: u)
        XCTAssertNil(CatalogCache.load(from: u))
    }

    func testAVersionOneCacheWithoutSystemsIsRejected() throws {
        let u = url(); defer { try? FileManager.default.removeItem(at: u) }
        let old = #"{"version":1,"xmlSignature":"x","historySignature":"y","knownNames":[],"games":[],"history":{},"builtAt":"2023-11-14T22:13:20Z"}"#
        try old.write(to: u, atomically: true, encoding: .utf8)
        XCTAssertNil(CatalogCache.load(from: u))
        XCTAssertEqual(CatalogCache.currentVersion, 2)
    }

    func testSystemAndSourceSurviveARoundTrip() throws {
        let u = url(); defer { try? FileManager.default.removeItem(at: u) }
        let game = GameInfo(name: "Pitfall", title: "Pitfall", year: "", manufacturer: "", cloneOf: nil, artTypes: [], hasHistory: false, romSets: [],
                            system: "atari2600", sourcePath: "roms/other-systems/atari2600/Pitfall.bin")
        let cache = CatalogCache(xmlSignature: "1", historySignature: "2", knownNames: [], games: [game], history: [:], builtAt: Date(timeIntervalSince1970: 1_700_000_000))
        try CatalogCache.save(cache, to: u)
        XCTAssertEqual(CatalogCache.load(from: u)?.games, [game])
    }
}

final class CatalogUpdaterTests: XCTestCase {
    private var root: URL!
    private final class LoadCounter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        var value: Int { get { lock.withLock { n } } set { lock.withLock { n = newValue } } }
        func bump() { lock.withLock { n += 1 } }
    }
    private let loads = LoadCounter()
    private var xmlLoads: Int { get { loads.value } set { loads.value = newValue } }

    override func setUpWithError() throws {
        root = try makeMasterTree([
            "roms/sets/0.172/galaga.zip", "roms/sets/0.172/pacman.zip", "roms/sets/0.172/puckman.zip", "roms/sets/0.172/namco51.zip",
            "roms/sets/0.172/namco54.zip", "roms/sets/0.172/neogeo.zip", "roms/sets/0.172/mslug.zip",
            "artwork/best/snap/galaga.png", "artwork/best/wheel/galaga.png",
            "data/mame2016.xml", "data/history.dat",
        ])
        try Data(sampleHistory.utf8).write(to: root.appendingPathComponent("data/history.dat"))
        xmlLoads = 0
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func updater() -> CatalogUpdater {
        let loads = self.loads
        return CatalogUpdater(master: MasterLibrary(root: root)) { _ in
            loads.bump()
            return try MameDatabase.parse(Data(sampleMameXML.utf8))
        }
    }

    func testFirstBuildMatchesTheDirectCatalogAndCarriesRomSets() throws {
        let update = try updater().refresh(previous: nil)
        XCTAssertEqual(update.cache.games.map(\.name), ["galaga", "mslug", "pacman", "puckman"])
        XCTAssertEqual(update.cache.games.first { $0.name == "galaga" }?.romSets, ["galaga", "namco51", "namco54"])
        XCTAssertEqual(update.cache.games.first { $0.name == "mslug" }?.romSets, ["mslug", "neogeo"])
        XCTAssertEqual(update.cache.games.first { $0.name == "galaga" }?.artTypes, ["snap", "wheel"])
        XCTAssertEqual(update.cache.games.first { $0.name == "galaga" }?.hasHistory, true)
        XCTAssertEqual(update.cache.knownNames.sorted(), ["galaga", "mslug", "namco51", "namco54", "neogeo", "pacman", "puckman"])
        XCTAssertTrue(update.changed); XCTAssertEqual(update.added.count, 4); XCTAssertEqual(xmlLoads, 1)
        let direct = GameCatalog(master: MasterLibrary(root: root), database: try MameDatabase.parse(Data(sampleMameXML.utf8)), history: HistoryDatabase.parse(sampleHistory))
        XCTAssertEqual(update.cache.games.map(\.name), direct.games.map(\.name))
    }

    func testNothingChangedMeansNoXMLParseAndNoChange() throws {
        let first = try updater().refresh(previous: nil)
        xmlLoads = 0
        let second = try updater().refresh(previous: first.cache)
        XCTAssertEqual(xmlLoads, 0)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.cache.games, first.cache.games)
    }

    func testRemovedGamesDropOutWithoutParsingTheXML() throws {
        let first = try updater().refresh(previous: nil)
        xmlLoads = 0
        try FileManager.default.removeItem(at: root.appendingPathComponent("roms/sets/0.172/mslug.zip"))
        let second = try updater().refresh(previous: first.cache)
        XCTAssertEqual(second.removed, ["mslug"]); XCTAssertTrue(second.added.isEmpty); XCTAssertTrue(second.changed)
        XCTAssertEqual(second.cache.games.map(\.name), ["galaga", "pacman", "puckman"])
        XCTAssertEqual(xmlLoads, 0)
    }

    func testNewRomSetsAreLookedUpInTheXMLOnlyWhenNeeded() throws {
        let first = try updater().refresh(previous: nil)
        xmlLoads = 0
        try Data("x".utf8).write(to: root.appendingPathComponent("roms/sets/0.172/loop1.zip"))
        let second = try updater().refresh(previous: first.cache)
        XCTAssertEqual(second.added, ["loop1"])
        XCTAssertEqual(xmlLoads, 1)
        XCTAssertEqual(second.cache.games.first { $0.name == "loop1" }?.title, "Loop A")
        // a set the XML does not know about is remembered, so it does not trigger a parse every time
        try Data("x".utf8).write(to: root.appendingPathComponent("roms/sets/0.172/unknownthing.zip"))
        let third = try updater().refresh(previous: second.cache)
        XCTAssertFalse(third.cache.games.contains { $0.name == "unknownthing" })
        xmlLoads = 0
        _ = try updater().refresh(previous: third.cache)
        XCTAssertEqual(xmlLoads, 0)
    }

    func testArtChangesUpdateWithoutParsingTheXML() throws {
        let first = try updater().refresh(previous: nil)
        xmlLoads = 0
        try FileManager.default.createDirectory(at: root.appendingPathComponent("artwork/best/flyer"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("artwork/best/flyer/pacman.png"))
        let second = try updater().refresh(previous: first.cache)
        XCTAssertTrue(second.changed); XCTAssertTrue(second.added.isEmpty); XCTAssertTrue(second.removed.isEmpty)
        XCTAssertEqual(second.cache.games.first { $0.name == "pacman" }?.artTypes, ["flyer"])
        XCTAssertEqual(xmlLoads, 0)
    }

    func testReplacingTheXMLRebuildsEverything() throws {
        let first = try updater().refresh(previous: nil)
        xmlLoads = 0
        try Data("changed contents, different size".utf8).write(to: root.appendingPathComponent("data/mame2016.xml"))
        let second = try updater().refresh(previous: first.cache)
        XCTAssertEqual(xmlLoads, 1)
        XCTAssertTrue(second.rebuilt)
        XCTAssertNotEqual(second.cache.xmlSignature, first.cache.xmlSignature)
    }

    func testReplacingHistoryReindexesIt() throws {
        let first = try updater().refresh(previous: nil)
        try Data("$info=mslug,\n$bio\n\nMetal Slug text.\n$end\n".utf8).write(to: root.appendingPathComponent("data/history.dat"))
        let second = try updater().refresh(previous: first.cache)
        XCTAssertEqual(second.cache.games.first { $0.name == "mslug" }?.hasHistory, true)
        XCTAssertEqual(second.cache.games.first { $0.name == "galaga" }?.hasHistory, false)
        XCTAssertEqual(xmlLoads, 1, "the XML itself did not change")
    }

    func testOtherSystemsJoinTheCatalogWithoutTheXMLAndKeepMameAsMame() throws {
        for rel in ["roms/other-systems/atari2600/Pitfall.bin", "roms/other-systems/daphne/ace.daphne/ace.txt", "roms/other-systems/daphne/roms/x.zip"] {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let first = try updater().refresh(previous: nil)
        XCTAssertEqual(first.cache.games.filter { $0.system == "mame" }.map(\.name), ["galaga", "mslug", "pacman", "puckman"])
        XCTAssertEqual(first.cache.games.filter { $0.system != "mame" }.map(\.id), ["atari2600/Pitfall", "daphne/ace"])
        XCTAssertEqual(first.added.count, 6)
        XCTAssertFalse(first.cache.knownNames.contains("Pitfall"))
        xmlLoads = 0
        let same = try updater().refresh(previous: first.cache)
        XCTAssertFalse(same.changed); XCTAssertEqual(xmlLoads, 0)
        try Data("x".utf8).write(to: root.appendingPathComponent("roms/other-systems/atari2600/Adventure.bin"))
        let more = try updater().refresh(previous: same.cache)
        XCTAssertEqual(more.added, ["atari2600/Adventure"]); XCTAssertTrue(more.changed); XCTAssertEqual(xmlLoads, 0)
        try FileManager.default.removeItem(at: root.appendingPathComponent("roms/other-systems/atari2600/Pitfall.bin"))
        let less = try updater().refresh(previous: more.cache)
        XCTAssertEqual(less.removed, ["atari2600/Pitfall"])
    }

    func testMissingXMLThrows() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("data/mame2016.xml"))
        XCTAssertThrowsError(try updater().refresh(previous: nil))
    }

    func testMissingHistoryIsFine() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("data/history.dat"))
        let update = try updater().refresh(previous: nil)
        XCTAssertTrue(update.cache.games.allSatisfy { !$0.hasHistory })
    }
}
