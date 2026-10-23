import XCTest
@testable import RinkMasterCore

private let sampleGamelist = """
<?xml version="1.0"?>
<gameList>
  <game id="1" source="ScreenScraper">
    <path>./Pitfall (USA).zip</path>
    <name>Pitfall!</name>
    <desc>Swing &amp; jump.</desc>
    <releasedate>19820101T000000</releasedate>
    <developer>Activision</developer>
    <publisher>Activision Inc.</publisher>
    <genre>Platform</genre>
  </game>
  <game>
    <path>./Plain.zip</path>
  </game>
  <game>
    <path>./Broken.zip</path>
    <name>4th & Inches</name>
  </game>
</gameList>
"""

final class GamelistTests: XCTestCase {
    func testParsesEntriesByRomStem() {
        let list = Gamelist.parse(Data(sampleGamelist.utf8))
        let p = list["Pitfall (USA)"]
        XCTAssertEqual(p?.name, "Pitfall!"); XCTAssertEqual(p?.desc, "Swing & jump.")
        XCTAssertEqual(p?.year, "1982"); XCTAssertEqual(p?.maker, "Activision")
        XCTAssertEqual(p?.genre, "Platform"); XCTAssertEqual(p?.publisher, "Activision Inc.")
        XCTAssertEqual(list["Plain"]?.name, "")
        XCTAssertEqual(GamelistEntry().year, "")
    }

    func testAMalformedFileKeepsTheGamesBeforeTheError() {
        XCTAssertNotNil(Gamelist.parse(Data(sampleGamelist.utf8))["Pitfall (USA)"])  // the bare & in the last game breaks the XML
        XCTAssertNil(Gamelist.parse(Data(sampleGamelist.utf8))["Broken"])
        XCTAssertTrue(Gamelist.parse(Data("not xml".utf8)).isEmpty)
        XCTAssertTrue(Gamelist.load(from: URL(fileURLWithPath: "/nonexistent/gamelist.xml")).isEmpty)
    }

    func testMakerFallsBackToPublisher() {
        var e = GamelistEntry(); e.publisher = "Atari"
        XCTAssertEqual(e.maker, "Atari")
    }
}

final class OtherSystemArtTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = try makeMasterTree([
            "roms/other-systems/snes/ActRaiser (USA).zip", "roms/other-systems/snes/Plain.zip",
            "roms/other-systems/snes/boxart/ActRaiser (USA).png", "roms/other-systems/snes/cartart/ActRaiser (USA).png",
            "roms/other-systems/snes/snap/ActRaiser (USA).mp4", "roms/other-systems/snes/wheel/ActRaiser (USA).png",
            "roms/other-systems/snes/marquee/ActRaiser (USA).jpg",
            "roms/other-systems/c64/Zork.zip", "roms/other-systems/c64/flyer/Zork.png", "roms/other-systems/c64/boxart/Zork.png",
        ])
        let list = "<gameList><game><path>./ActRaiser (USA).zip</path><name>ActRaiser</name><desc>Angel.</desc><releasedate>19901221T000000</releasedate><developer>Quintet</developer></game></gameList>"
        try list.write(to: root.appendingPathComponent("roms/other-systems/snes/gamelist.xml"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCatalogGamesTakeTitleYearMakerAndArtFromTheSystemFolder() {
        let games = MasterLibrary(root: root).otherSystemGames()
        XCTAssertEqual(games.map(\.id), ["c64/Zork", "snes/ActRaiser (USA)", "snes/Plain"])  // art folders and gamelist.xml are not games
        let act = games.first { $0.name == "ActRaiser (USA)" }!
        XCTAssertEqual(act.title, "ActRaiser"); XCTAssertEqual(act.year, "1990"); XCTAssertEqual(act.manufacturer, "Quintet")
        XCTAssertEqual(act.artTypes, ["boxart", "cartart", "snap", "wheel", "marquee"]); XCTAssertTrue(act.hasHistory)
        let plain = games.first { $0.name == "Plain" }!
        XCTAssertEqual(plain.title, "Plain"); XCTAssertTrue(plain.artTypes.isEmpty); XCTAssertFalse(plain.hasHistory)
    }

    func testArtURLsFindAnyUsualExtension() throws {
        let lib = MasterLibrary(root: root)
        let act = lib.otherSystemGames().first { $0.name == "ActRaiser (USA)" }!
        XCTAssertEqual(lib.otherArtURL(game: act, type: "boxart")?.lastPathComponent, "ActRaiser (USA).png")
        XCTAssertEqual(lib.otherArtURL(game: act, type: "snap")?.lastPathComponent, "ActRaiser (USA).mp4")
        XCTAssertEqual(lib.otherArtURL(game: act, type: "marquee")?.lastPathComponent, "ActRaiser (USA).jpg")
        XCTAssertNil(lib.otherArtURL(game: act, type: "flyer"))
        XCTAssertNil(lib.otherArtURL(game: act, type: "../x"))
        XCTAssertNil(lib.otherArtURL(system: "snes/../c64", name: "Zork", type: "flyer"))
        XCTAssertNil(lib.otherArtURL(game: GameInfo(name: "galaga", title: "", year: "", manufacturer: "", cloneOf: nil, artTypes: [], hasHistory: false, romSets: []), type: "snap"))
    }

    func testCabinetArtIsFlyerSnapWheelMarqueeAndNeverCartArt() {
        let lib = MasterLibrary(root: root)
        let types = lib.otherArtFiles(system: "snes", name: "ActRaiser (USA)").map(\.type)
        XCTAssertEqual(types, ["boxart", "snap", "wheel", "marquee"])
        XCTAssertEqual(types.map(MasterLibrary.cabinetArtFolder(forMasterType:)), ["flyer", "snap", "wheel", "marquee"])
        XCTAssertEqual(lib.otherArtFiles(system: "c64", name: "Zork").map(\.type), ["flyer"])  // flyer wins over boxart, one file per folder
        XCTAssertTrue(lib.otherArtFiles(system: "snes", name: "Plain").isEmpty)
        XCTAssertEqual(lib.gamelistEntry(system: "snes", name: "ActRaiser (USA)")?.desc, "Angel.")
        XCTAssertNil(lib.gamelistEntry(system: "snes", name: "Plain"))
        XCTAssertNil(lib.gamelistEntry(system: "../x", name: "a"))
    }

    func testIndexListsWhatEachFolderHas() {
        let index = MasterLibrary(root: root).otherArtIndex(system: "c64")
        XCTAssertEqual(index["flyer"], ["Zork"]); XCTAssertNil(index["snap"])
    }
}
