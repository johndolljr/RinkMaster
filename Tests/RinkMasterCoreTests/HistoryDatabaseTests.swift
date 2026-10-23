import XCTest
@testable import RinkMasterCore

let sampleHistory = """
## comment header
$nes=100mandk,
$bio

Not an arcade entry.

$end

$info=galaga,galagao,
$bio

This Arcade Video game was published 38 years ago:

Galaga (c) 1981 Namco.

Galaga is a shoot-em-up.

- TRIVIA -

Pac-Man's cousin.

$end

$info=pacman,
$bio

Pac-Man (c) 1980 Namco.

$end
"""

final class HistoryDatabaseTests: XCTestCase {
    func testEntriesAreKeyedByEveryGameNameInTheHeader() {
        let h = HistoryDatabase.parse(sampleHistory)
        XCTAssertNotNil(h.text(for: "galaga"))
        XCTAssertEqual(h.text(for: "galagao"), h.text(for: "galaga"))
        XCTAssertNotNil(h.text(for: "pacman"))
    }

    func testOnlyArcadeInfoEntriesAreKept() {
        let h = HistoryDatabase.parse(sampleHistory)
        XCTAssertNil(h.text(for: "100mandk"))
        XCTAssertEqual(h.count, 3)
    }

    func testBodyIsTrimmedAndStopsAtEnd() throws {
        let t = try XCTUnwrap(HistoryDatabase.parse(sampleHistory).text(for: "pacman"))
        XCTAssertEqual(t, "Pac-Man (c) 1980 Namco.")
    }

    func testSectionsAreSplitOutByHeading() throws {
        let sections = try XCTUnwrap(HistoryDatabase.parse(sampleHistory).sections(for: "galaga"))
        XCTAssertEqual(sections.map(\.title), ["", "TRIVIA"])
        XCTAssertTrue(sections[0].body.hasPrefix("This Arcade Video game"))
        XCTAssertEqual(sections[1].body, "Pac-Man's cousin.")
    }

    func testUnknownGameAndEmptyInput() {
        XCTAssertNil(HistoryDatabase.parse(sampleHistory).text(for: "nope"))
        XCTAssertEqual(HistoryDatabase.parse("").count, 0)
    }

    func testRunsWithoutTrailingEnd() {
        XCTAssertEqual(HistoryDatabase.parse("$info=lone,\n$bio\n\nText only.\n").text(for: "lone"), "Text only.")
    }
}
