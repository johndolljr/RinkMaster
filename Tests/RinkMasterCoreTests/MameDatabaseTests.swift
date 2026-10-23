import XCTest
@testable import RinkMasterCore

let sampleMameXML = """
<?xml version="1.0"?>
<datafile>
<machine name="puckman" sourcefile="pacman.cpp"><description>Puck Man (Japan set 1)</description><year>1980</year><manufacturer>Namco</manufacturer>
  <rom name="pm1_prg1.6e" size="2048" crc="f36e88ab"/><device_ref name="z80"/><device_ref name="namco"/></machine>
<machine name="pacman" sourcefile="pacman.cpp" cloneof="puckman" romof="puckman"><description>Pac-Man (Midway)</description><year>1980</year><manufacturer>[Namco] (Midway license)</manufacturer>
  <rom name="pacman.6e" merge="pm1_prg1.6e" size="2048" crc="c1e6ab10"/><device_ref name="z80"/><device_ref name="namco"/></machine>
<machine name="galaga" sourcefile="galaga.cpp"><description>Galaga (Namco rev. B)</description><year>1981</year><manufacturer>Namco</manufacturer>
  <rom name="gg1_1b.3p" size="4096" crc="ab036c9f"/><device_ref name="z80"/><device_ref name="namco51"/><device_ref name="namco54"/><device_ref name="namco51"/></machine>
<machine name="namco51" sourcefile="namco51.cpp" isdevice="yes" runnable="no"><description>Namco 51xx</description><rom name="51xx.bin" size="1024" crc="c2f57ef8"/></machine>
<machine name="namco54" sourcefile="namco54.cpp" isdevice="yes" runnable="no"><description>Namco 54xx</description><rom name="54xx.bin" size="1024" crc="ee7357e0"/></machine>
<machine name="z80" sourcefile="z80.cpp" isdevice="yes" runnable="no"><description>Zilog Z80</description></machine>
<machine name="neogeo" sourcefile="neogeo.cpp" isbios="yes"><description>Neo-Geo MV-6F</description><year>1990</year><manufacturer>SNK</manufacturer><rom name="sp-s2.sp1" size="131072" crc="9036d879"/></machine>
<machine name="mslug" sourcefile="neogeo.cpp" romof="neogeo"><description>Metal Slug</description><year>1996</year><manufacturer>Nazca</manufacturer><rom name="201-p1.p1" size="1048576" crc="08d8daa5"/></machine>
<machine name="loop1" cloneof="loop2" romof="loop2"><description>Loop A</description></machine>
<machine name="loop2" cloneof="loop1" romof="loop1"><description>Loop B</description></machine>
</datafile>
"""

final class MameDatabaseTests: XCTestCase {
    private func db() throws -> MameDatabase { try MameDatabase.parse(Data(sampleMameXML.utf8)) }

    func testParsesDescriptionYearManufacturerAndRelations() throws {
        let m = try XCTUnwrap(db().machine("pacman"))
        XCTAssertEqual(m.description, "Pac-Man (Midway)")
        XCTAssertEqual(m.year, "1980")
        XCTAssertEqual(m.manufacturer, "[Namco] (Midway license)")
        XCTAssertEqual(m.cloneOf, "puckman")
        XCTAssertEqual(m.romOf, "puckman")
        XCTAssertFalse(m.isDevice)
        XCTAssertEqual(m.deviceRefs, ["z80", "namco"])
        XCTAssertGreaterThan(m.romCount, 0)
    }

    func testDevicesAndBiosFlagsAreRecorded() throws {
        let d = try db()
        XCTAssertTrue(try XCTUnwrap(d.machine("namco51")).isDevice)
        XCTAssertTrue(try XCTUnwrap(d.machine("neogeo")).isBIOS)
        XCTAssertEqual(try XCTUnwrap(d.machine("z80")).romCount, 0)
        XCTAssertNil(d.machine("nosuchgame"))
        XCTAssertEqual(d.count, 10)
    }

    func testRequiredSetsForAStandaloneGameWithDevices() throws {
        // galaga needs its own set plus the namco51/namco54 device ROM sets; z80 has no ROMs so it is skipped
        XCTAssertEqual(try db().requiredRomSets(for: "galaga"), ["galaga", "namco51", "namco54"])
    }

    func testRequiredSetsIncludeTheParentChain() throws {
        XCTAssertEqual(try db().requiredRomSets(for: "pacman"), ["pacman", "puckman"])
    }

    func testRequiredSetsIncludeTheBios() throws {
        XCTAssertEqual(try db().requiredRomSets(for: "mslug"), ["mslug", "neogeo"])
    }

    func testCyclesDoNotLoopForever() throws {
        XCTAssertEqual(try db().requiredRomSets(for: "loop1"), ["loop1", "loop2"])
    }

    func testUnknownGameThrows() throws {
        XCTAssertThrowsError(try db().requiredRomSets(for: "nosuch")) { XCTAssertEqual($0 as? MameDatabase.LookupError, .unknownGame("nosuch")) }
    }

    func testBadXMLThrows() {
        XCTAssertThrowsError(try MameDatabase.parse(Data("<datafile><machine name=".utf8)))
    }
}
