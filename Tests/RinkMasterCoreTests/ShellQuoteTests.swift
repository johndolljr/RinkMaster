import XCTest
@testable import RinkMasterCore

final class ShellQuoteTests: XCTestCase {
    func testPlainWordIsSingleQuoted() { XCTAssertEqual(ShellQuote.quote("galaga.zip"), "'galaga.zip'") }
    func testSpacesAreProtected() { XCTAssertEqual(ShellQuote.quote("a b c"), "'a b c'") }
    func testEmbeddedSingleQuoteIsEscaped() { XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'") }
    func testEmptyStringBecomesEmptyQuotes() { XCTAssertEqual(ShellQuote.quote(""), "''") }
    func testShellMetacharactersStayLiteral() {
        XCTAssertEqual(ShellQuote.quote("$(rm -rf /); `x` *"), "'$(rm -rf /); `x` *'")
    }
}
