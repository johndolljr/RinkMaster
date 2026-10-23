import XCTest
@testable import RinkMasterCore

final class ScoreSyncPlannerTests: XCTestCase {
    private let core = "mame-libretro/mame2003"
    private func entry(_ machine: String, _ game: String = "tempest", core: String? = nil, top: Int?, bytes: [UInt8]? = nil, mtime: Int = 100, kind: String = "hi") -> CollectedScore {
        let table = top.map { ScoreTable(columns: ["RANK", "SCORE", "NAME"], rows: [["1", String($0), "AAA"]]) }
        let bytes = bytes ?? [UInt8((top ?? 0) % 251)]  // different scores get different bytes unless a test says otherwise
        return CollectedScore(machine: machine, file: ScoreFile(core: core ?? self.core, kind: kind, game: game, size: bytes.count, mtime: mtime),
                              table: table, note: table == nil ? "x" : nil, data: Data(bytes))
    }

    func testLowerScoresAreReplacedByTheWinner() {
        let plan = ScoreSyncPlanner.plan(UnifiedScores(entries: [entry("arcade2", top: 73372, bytes: [9, 9]), entry("xarcade", top: 100, bytes: [1])]))
        XCTAssertEqual(plan.items.count, 1)
        let item = plan.items[0]
        XCTAssertEqual(item.from, "arcade2"); XCTAssertEqual(item.to, "xarcade")
        XCTAssertEqual(item.game, "tempest"); XCTAssertEqual(item.core, core)
        XCTAssertEqual(item.winnerScore, 73372); XCTAssertEqual(item.currentScore, 100)
        XCTAssertEqual(item.data, Data([9, 9]))
        XCTAssertEqual(item.relativePath, "mame-libretro/mame2003/hi/tempest.hi")
    }

    func testNothingToDoWhenFilesAlreadyMatchOrScoresTie() {
        let same = ScoreSyncPlanner.plan(UnifiedScores(entries: [entry("arcade2", top: 5, bytes: [1]), entry("xarcade", top: 5, bytes: [1])]))
        XCTAssertTrue(same.items.isEmpty)
        let tie = ScoreSyncPlanner.plan(UnifiedScores(entries: [entry("arcade2", top: 5, bytes: [1]), entry("xarcade", top: 5, bytes: [2])]))
        XCTAssertTrue(tie.items.isEmpty)  // equal top scores: leave each machine's own table alone
    }

    func testOnlyMachinesThatAlreadyHaveTheGamesFileOnThatCoreAreTargets() {
        let plan = ScoreSyncPlanner.plan(UnifiedScores(entries: [
            entry("arcade2", top: 900), entry("xarcade", top: 10),
            entry("xarcade", "galaga", top: 50),  // only one machine has a galaga file: nobody to send it to
        ]))
        XCTAssertEqual(plan.items.map(\.game), ["tempest"])
    }

    func testCoresAreNeverMixed() {
        let plan = ScoreSyncPlanner.plan(UnifiedScores(entries: [
            entry("arcade2", core: "mame-libretro/mame2003", top: 900), entry("xarcade", core: "mame-libretro/mame2010", top: 10),
        ]))
        XCTAssertTrue(plan.items.isEmpty)
    }

    func testUndecodableAndNVRAMFilesAreNeverSourcesOrTargets() {
        let plan = ScoreSyncPlanner.plan(UnifiedScores(entries: [
            entry("arcade2", top: 900), entry("xarcade", top: nil),                   // target we cannot read: leave alone
            entry("arcade2", "pacman", top: 10, kind: "nv"), entry("xarcade", "pacman", top: 5, kind: "nv"),
        ]))
        XCTAssertTrue(plan.items.isEmpty)
    }

    func testFilesWithoutBytesAreSkipped() {
        let noBytes = CollectedScore(machine: "arcade2", file: ScoreFile(core: core, kind: "hi", game: "tempest", size: 1, mtime: 1),
                                     table: ScoreTable(columns: ["SCORE"], rows: [["900"]]), note: nil, data: nil)
        XCTAssertTrue(ScoreSyncPlanner.plan(UnifiedScores(entries: [noBytes, entry("xarcade", top: 1)])).items.isEmpty)
    }

    func testPlanIsStablyOrdered() {
        let plan = ScoreSyncPlanner.plan(UnifiedScores(entries: [
            entry("arcade2", "tempest", top: 900), entry("xarcade", "tempest", top: 1), entry("pi3", "tempest", top: 2),
            entry("arcade2", "galaga", top: 900), entry("xarcade", "galaga", top: 1),
        ]))
        XCTAssertEqual(plan.items.map { "\($0.game)->\($0.to)" }, ["galaga->xarcade", "tempest->pi3", "tempest->xarcade"])
    }

    func testDescriptionListsEachWrite() {
        let plan = ScoreSyncPlanner.plan(UnifiedScores(entries: [entry("arcade2", top: 900), entry("xarcade", top: 1)]))
        XCTAssertEqual(plan.items[0].summary, "tempest: arcade2 (900) -> xarcade (1) [mame-libretro/mame2003]")
    }
}

final class FakeWriter: ScoreWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(core: String, game: String, data: Data)] = []
    var failWith: Error?
    var writes: [(core: String, game: String, data: Data)] { lock.withLock { log } }
    func replace(core: String, game: String, with data: Data) async throws -> String {
        if let failWith { throw failWith }
        lock.withLock { log.append((core, game, data)) }
        return "\(game).hi.bak-1"
    }
}

final class ScoreSyncRunnerTests: XCTestCase {
    private let item1 = ScoreSyncItem(game: "tempest", core: "mame-libretro/mame2003", from: "arcade2", to: "xarcade", winnerScore: 900, currentScore: 1, data: Data([9]))
    private let item2 = ScoreSyncItem(game: "galaga", core: "mame-libretro/mame2010", from: "xarcade", to: "arcade2", winnerScore: 800, currentScore: 2, data: Data([8]))

    func testApplyWritesEachFileToItsTargetMachine() async {
        let x = FakeWriter(), a = FakeWriter()
        let results = await ScoreSyncRunner(writers: ["xarcade": x, "arcade2": a]).apply(ScoreSyncPlan(items: [item1, item2]))
        XCTAssertEqual(results.map(\.error), [nil, nil])
        XCTAssertEqual(x.writes.map(\.game), ["tempest"])
        XCTAssertEqual(x.writes[0].core, "mame-libretro/mame2003")
        XCTAssertEqual(x.writes[0].data, Data([9]))
        XCTAssertEqual(a.writes.map(\.game), ["galaga"])
    }

    func testOneMachineFailingDoesNotStopTheOthers() async {
        let bad = FakeWriter(); bad.failWith = ServiceError.http(404)
        let good = FakeWriter()
        let results = await ScoreSyncRunner(writers: ["xarcade": bad, "arcade2": good]).apply(ScoreSyncPlan(items: [item1, item2]))
        XCTAssertEqual(results[0].error, "service answered 404")
        XCTAssertNil(results[1].error)
        XCTAssertEqual(good.writes.count, 1)
    }

    func testOtherErrorsAreReportedAsText() async {
        let bad = FakeWriter(); bad.failWith = URLError(.timedOut)
        let results = await ScoreSyncRunner(writers: ["xarcade": bad]).apply(ScoreSyncPlan(items: [item1]))
        XCTAssertNotNil(results[0].error)
    }

    func testUnknownTargetMachineIsReportedNotCrashed() async {
        let results = await ScoreSyncRunner(writers: [:]).apply(ScoreSyncPlan(items: [item1]))
        XCTAssertEqual(results[0].error, "xarcade is not configured")
    }

    func testDryRunTouchesNothing() async {
        let w = FakeWriter()
        let lines = ScoreSyncRunner(writers: ["xarcade": w]).dryRun(ScoreSyncPlan(items: [item1, item2]))
        XCTAssertEqual(lines, ["tempest: arcade2 (900) -> xarcade (1) [mame-libretro/mame2003]", "galaga: xarcade (800) -> arcade2 (2) [mame-libretro/mame2010]"])
        XCTAssertTrue(w.writes.isEmpty)
    }

    func testServiceClientPutsTheBytesAndReadsTheBackupName() async throws {
        StubURLProtocol.respond(200, body: #"{"written":true,"backup":"tempest.hi.bak-20231114T221320Z","size":2}"#)
        let backup = try await ServiceClient(host: "h", port: 1, session: StubURLProtocol.session).replace(core: "mame-libretro/mame2003", game: "tempest", with: Data([1, 2]))
        XCTAssertEqual(backup, "tempest.hi.bak-20231114T221320Z")
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url?.path, "/v1/scores/file")
        XCTAssertTrue(req.url?.query?.contains("kind=hi") == true)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
    }

    func testServiceClientRejectsAnUnreadableReply() async {
        StubURLProtocol.respond(200, body: "not json")
        do { _ = try await ServiceClient(host: "h", port: 1, session: StubURLProtocol.session).replace(core: "c", game: "g", with: Data([1])); XCTFail() }
        catch let e as ServiceError { if case .decoding = e {} else { XCTFail("\(e)") } } catch { XCTFail("\(error)") }
    }

    func testWeeklyDueReminder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(ScoreSyncSchedule.isDue(last: nil, now: now))
        XCTAssertFalse(ScoreSyncSchedule.isDue(last: now.addingTimeInterval(-6 * 86_400), now: now))
        XCTAssertTrue(ScoreSyncSchedule.isDue(last: now.addingTimeInterval(-7 * 86_400), now: now))
    }
}
