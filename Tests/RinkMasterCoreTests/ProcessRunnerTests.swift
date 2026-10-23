import XCTest
@testable import RinkMasterCore

final class ProcessRunnerTests: XCTestCase {
    private let runner = SystemProcessRunner()

    func testCapturesStdoutAndZeroStatus() async throws {
        let r = try await runner.run("/bin/echo", ["hello"], timeout: 5)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdout, "hello\n")
        XCTAssertTrue(r.succeeded)
    }

    func testCapturesStderrAndNonZeroStatus() async throws {
        let r = try await runner.run("/bin/sh", ["-c", "echo oops 1>&2; exit 3"], timeout: 5)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.stderr, "oops\n")
        XCTAssertFalse(r.succeeded)
    }

    func testTimesOutAndKillsTheProcess() async {
        do {
            _ = try await runner.run("/bin/sleep", ["5"], timeout: 0.3)
            XCTFail("expected a timeout")
        } catch let error as ProcessError {
            XCTAssertEqual(error, .timedOut)
        } catch { XCTFail("wrong error \(error)") }
    }

    func testMissingExecutableThrowsLaunchFailure() async {
        do {
            _ = try await runner.run("/no/such/binary", [], timeout: 1)
            XCTFail("expected failure")
        } catch let error as ProcessError {
            if case .launchFailed = error {} else { XCTFail("wrong error \(error)") }
        } catch { XCTFail("wrong error \(error)") }
    }
}
