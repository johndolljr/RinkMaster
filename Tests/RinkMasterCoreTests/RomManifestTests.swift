import XCTest
@testable import RinkMasterCore

final class RomManifestTests: XCTestCase {
    private let sample = """
    #system\tfile\tsize\tsig\tmaster_dir
    mame-libretro\tgalaga.zip\t24797\tabc123\textras
    mame-libretro\t1942.zip\t106788\tdef456\tsets/0.172
    mame-libretro\tzaxxon3.zip\t1000\t-\t-
    daphne\tlair.daphne\t800000\tfp:4:800000\tother-systems/daphne

    """

    func testParsesRowsAndSkipsHeaderAndBlankLines() throws {
        let manifest = try RomManifest.parse(sample)
        XCTAssertEqual(manifest.entries.count, 4)
        XCTAssertEqual(manifest.entries[0].system, "mame-libretro")
        XCTAssertEqual(manifest.entries[0].file, "galaga.zip")
        XCTAssertEqual(manifest.entries[0].size, 24797)
        XCTAssertEqual(manifest.entries[0].masterDir, "extras")
    }

    func testDashMeansNotInMaster() throws {
        let manifest = try RomManifest.parse(sample)
        XCTAssertNil(manifest.entries[2].masterDir)
        XCTAssertFalse(manifest.entries[2].isInMaster)
        XCTAssertTrue(manifest.entries[1].isInMaster)
    }

    func testGameNameStripsZipExtensionAndKeepsFolderNames() throws {
        let manifest = try RomManifest.parse(sample)
        XCTAssertEqual(manifest.entries[0].gameName, "galaga")
        XCTAssertEqual(manifest.entries[3].gameName, "lair.daphne")
    }

    func testGroupsGamesBySystem() throws {
        let manifest = try RomManifest.parse(sample)
        let bySystem = manifest.entriesBySystem
        XCTAssertEqual(bySystem["mame-libretro"]?.count, 3)
        XCTAssertEqual(bySystem["daphne"]?.count, 1)
    }

    func testRejectsRowsWithTooFewColumns() {
        XCTAssertThrowsError(try RomManifest.parse("mame-libretro\tgalaga.zip\t12\n")) { error in
            XCTAssertEqual(error as? RomManifest.ParseError, .badRow(line: 1))
        }
    }

    func testRejectsNonNumericSize() {
        XCTAssertThrowsError(try RomManifest.parse("mame-libretro\tgalaga.zip\tbig\tsig\textras\n")) { error in
            XCTAssertEqual(error as? RomManifest.ParseError, .badRow(line: 1))
        }
    }
}
