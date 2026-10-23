import XCTest
@testable import RinkMasterCore

final class ConfettiGeneratorTests: XCTestCase {
    func testProducesRequestedCountWithinBounds() {
        var gen = ConfettiGenerator(seed: 1984)
        let pieces = gen.pieces(count: 500, width: 1000, height: 600)
        XCTAssertEqual(pieces.count, 500)
        for p in pieces {
            XCTAssertTrue((0...1000).contains(p.x))
            XCTAssertTrue((0...600).contains(p.y))
            XCTAssertTrue((0..<RinkPalette.confetti.count).contains(p.colorIndex))
            XCTAssertTrue((10...26).contains(p.length))
            XCTAssertTrue((3...6).contains(p.thickness))
            XCTAssertTrue((38...85).contains(p.alpha))
        }
    }

    func testSameSeedIsDeterministicAndDifferentSeedDiffers() {
        var a = ConfettiGenerator(seed: 7), b = ConfettiGenerator(seed: 7), c = ConfettiGenerator(seed: 8)
        let pa = a.pieces(count: 50, width: 400, height: 400)
        XCTAssertEqual(pa, b.pieces(count: 50, width: 400, height: 400))
        XCTAssertNotEqual(pa, c.pieces(count: 50, width: 400, height: 400))
    }

    func testDensityIsHigherTowardTheLeftAndRightEdges() {
        var gen = ConfettiGenerator(seed: 42)
        let pieces = gen.pieces(count: 3000, width: 900, height: 900)
        let center = pieces.filter { $0.x >= 300 && $0.x < 600 }.count
        let edges = pieces.count - center
        // the middle third covers 1/3 of the area but should hold clearly fewer than 1/3 of the pieces
        XCTAssertLessThan(Double(center) / Double(pieces.count), 0.28)
        XCTAssertGreaterThan(edges, center * 2)
    }

    func testZeroCountOrZeroSizeIsEmpty() {
        var gen = ConfettiGenerator(seed: 1)
        XCTAssertTrue(gen.pieces(count: 0, width: 100, height: 100).isEmpty)
        XCTAssertTrue(gen.pieces(count: 10, width: 0, height: 100).isEmpty)
    }
}
