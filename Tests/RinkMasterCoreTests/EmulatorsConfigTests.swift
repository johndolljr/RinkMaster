import XCTest
@testable import RinkMasterCore

final class EmulatorsConfigTests: XCTestCase {
    private let sample = """
    lr-mame2003 = "/opt/retropie/emulators/retroarch/bin/retroarch -L /x/mame2003_libretro.so --config /c %ROM%"
    default = "lr-mame2010"
    # a comment
    lr-mame2010 = "/opt/retropie/emulators/retroarch/bin/retroarch -L /x/mame2010_libretro.so --config /c %ROM%"

    not a valid line
    """

    func testParsesKeysDefaultAndEmulatorIds() {
        let c = EmulatorsConfig.parse(sample)
        XCTAssertEqual(c.defaultEmulator, "lr-mame2010")
        XCTAssertEqual(c.emulatorIDs, ["lr-mame2003", "lr-mame2010"])
        XCTAssertTrue(c.entries["lr-mame2003"]?.contains("mame2003_libretro.so") ?? false)
    }

    func testEmptyTextHasNoDefault() {
        let c = EmulatorsConfig.parse("")
        XCTAssertNil(c.defaultEmulator)
        XCTAssertTrue(c.emulatorIDs.isEmpty)
    }

    func testValueMayContainEqualsAndQuotesAreStripped() {
        let c = EmulatorsConfig.parse(#"stella = "stella -maxres 320x240 -x=1 %ROM%""#)
        XCTAssertEqual(c.entries["stella"], "stella -maxres 320x240 -x=1 %ROM%")
    }
}
