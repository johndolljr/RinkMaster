import XCTest
@testable import RinkMasterCore

final class RinkPaletteTests: XCTestCase {
    func testBrandColorsMatchTheCabinetTheme() {
        XCTAssertEqual(RinkPalette.red, RGB(r: 229, g: 36, b: 43))
        XCTAssertEqual(RinkPalette.amber, RGB(r: 255, g: 176, b: 66))
        XCTAssertEqual(RinkPalette.teal, RGB(r: 46, g: 196, b: 182))
        XCTAssertEqual(RinkPalette.confetti.count, 5)
    }

    func testBackgroundGradientEndpointsAndMidpoint() {
        XCTAssertEqual(RinkPalette.background(at: 0), RGB(r: 4, g: 3, b: 10))
        XCTAssertEqual(RinkPalette.background(at: 1), RGB(r: 22, g: 6, b: 16))
        XCTAssertEqual(RinkPalette.background(at: 0.6), RGB(r: 12, g: 6, b: 24))
        // halfway between the first two stops (t=0.3): midpoint of (4,3,10) and (12,6,24)
        XCTAssertEqual(RinkPalette.background(at: 0.3), RGB(r: 8, g: 4, b: 17))
    }

    func testBackgroundClampsOutOfRange() {
        XCTAssertEqual(RinkPalette.background(at: -1), RinkPalette.background(at: 0))
        XCTAssertEqual(RinkPalette.background(at: 2), RinkPalette.background(at: 1))
    }

    func testRGBComponentsAreUnitRange() {
        let c = RGB(r: 255, g: 0, b: 51).unit
        XCTAssertEqual(c.r, 1.0, accuracy: 1e-9)
        XCTAssertEqual(c.g, 0.0, accuracy: 1e-9)
        XCTAssertEqual(c.b, 0.2, accuracy: 1e-9)
    }
}
