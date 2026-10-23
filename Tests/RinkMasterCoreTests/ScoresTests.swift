import XCTest
@testable import RinkMasterCore

/// Fake `java` that records its arguments, returns canned output and remembers the staged .hi file's name and bytes.
final class FakeJava: ProcessRunning, @unchecked Sendable {
    var result = CommandResult(status: 0, stdout: "RANK|SCORE|NAME\n1|302780|JON\n2|276710|ABC\n\n", stderr: "")
    var error: Error?
    var calls: [(exe: String, args: [String])] = []
    var stagedName: String?
    var stagedBytes: Data?
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        calls.append((executable, arguments))
        if let path = arguments.last { stagedName = (path as NSString).lastPathComponent; stagedBytes = FileManager.default.contents(atPath: path) }
        if let error { throw error }
        return result
    }
}

final class ScoreTableTests: XCTestCase {
    func testParsesHeaderAndRows() throws {
        let t = try XCTUnwrap(ScoreTable.parse("RANK|SCORE|NAME\n1|302780|JON\n2|276710|ABC\n\n"))
        XCTAssertEqual(t.columns, ["RANK", "SCORE", "NAME"])
        XCTAssertEqual(t.rows, [["1", "302780", "JON"], ["2", "276710", "ABC"]])
    }

    func testTopScoreIsTheLargestScoreColumnValue() throws {
        XCTAssertEqual(ScoreTable.parse("RANK|SCORE|NAME\n1|302780|JON\n2|276710|ABC")?.topScore, 302780)
        XCTAssertEqual(ScoreTable.parse("RANK|NAME|SCORE\n1|EJD|10101\n2|DES|73372")?.topScore, 73372)
        XCTAssertEqual(ScoreTable.parse("RANK|SCORE|NAME\n1|1.234.560|X")?.topScore, 1234560)  // grouped digits
        XCTAssertNil(ScoreTable.parse("RANK|NAME\n1|JON")?.topScore)  // no score column
    }

    func testEmptyOrHeaderOnlyIsNil() {
        XCTAssertNil(ScoreTable.parse(""))
        XCTAssertNil(ScoreTable.parse("RANK|SCORE|NAME\n"))
        XCTAssertNil(ScoreTable.parse("ERROR: no xml\n"))
    }
}

final class Hi2txtDecoderTests: XCTestCase {
    private let java = FakeJava()
    private func decoder() -> Hi2txtDecoder {
        Hi2txtDecoder(java: "/usr/bin/java", jar: "/m/tools/hi2txt/hi2txt.jar", definitions: "/m/data/hi2txt", runner: java)
    }

    func testDecodeStagesTheFileUnderTheGameNameAndRunsTheJar() async throws {
        let bytes = Data([1, 2, 3])
        let table = try await decoder().decode(game: "galaga", data: bytes)
        XCTAssertEqual(table.topScore, 302780)
        XCTAssertEqual(java.stagedName, "galaga.hi")  // hi2txt finds its definition by file name
        XCTAssertEqual(java.stagedBytes, bytes)
        let call = try XCTUnwrap(java.calls.first)
        XCTAssertEqual(call.exe, "/usr/bin/java")
        XCTAssertEqual(Array(call.args.prefix(6)), ["-jar", "/m/tools/hi2txt/hi2txt.jar", "-r", "-descr", "/m/data/hi2txt", "-notrace"])
    }

    func testTheStagedFileIsCleanedUp() async throws {
        _ = try await decoder().decode(game: "galaga", data: Data([1]))
        let dir = (java.calls[0].args.last! as NSString).deletingLastPathComponent
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    func testUnknownGameOrLayoutIsNotDecodable() async {
        java.result = CommandResult(status: 0, stdout: "ERROR: No XML description found for ROM 'zzz'\n", stderr: "")
        do { _ = try await decoder().decode(game: "zzz", data: Data([1])); XCTFail() }
        catch let e as ScoreError { XCTAssertEqual(e, .notDecodable("No XML description found for ROM 'zzz'")) }
        catch { XCTFail("\(error)") }
    }

    func testMissingJavaIsReportedAsUnavailable() async {
        java.error = ProcessError.launchFailed("no such file")
        do { _ = try await decoder().decode(game: "galaga", data: Data([1])); XCTFail() }
        catch let e as ScoreError { XCTAssertEqual(e, .decoderUnavailable("no such file")) }
        catch { XCTFail("\(error)") }
    }

    func testBadGameNamesAreRefusedBeforeAnythingRuns() async {
        for bad in ["", "../x", "a/b", "-r"] {
            do { _ = try await decoder().decode(game: bad, data: Data([1])); XCTFail(bad) }
            catch let e as ScoreError { XCTAssertEqual(e, .notDecodable("bad game name")) }
            catch { XCTFail("\(error)") }
        }
        XCTAssertTrue(java.calls.isEmpty)
    }

    func testDecoderIsAvailableOnlyWhenJarAndDefinitionsExist() throws {
        let root = try makeMasterTree(["tools/hi2txt/hi2txt.jar", "data/hi2txt/galaga.xml"])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNotNil(Hi2txtDecoder.inMaster(MasterLibrary(root: root), java: "/usr/bin/java"))
        let empty = try makeMasterTree(["x"])
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertNil(Hi2txtDecoder.inMaster(MasterLibrary(root: empty), java: "/usr/bin/java"))
    }
}

final class ScoreServiceClientTests: XCTestCase {
    private func client() -> ServiceClient { ServiceClient(host: "cabinet1.lan", port: 8472, session: StubURLProtocol.session) }

    func testListsScoreFiles() async throws {
        StubURLProtocol.respond(200, body: #"{"machine":"arcade2","files":[{"core":"mame-libretro/mame2003","kind":"hi","game":"tempest","size":283,"mtime":1700000000},{"core":"mame-libretro/mame2010","kind":"nv","game":"1944","size":128,"mtime":1700000001}]}"#)
        let files = try await client().scoreFiles()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/scores")
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0], ScoreFile(core: "mame-libretro/mame2003", kind: "hi", game: "tempest", size: 283, mtime: 1700000000))
        XCTAssertTrue(files[0].isDecodable)
        XCTAssertFalse(files[1].isDecodable)  // .nv NVRAM cannot be decoded
    }

    func testFetchesRawBytesWithEncodedQuery() async throws {
        StubURLProtocol.respond(200, body: "\u{01}\u{02}")
        let data = try await client().scoreData(ScoreFile(core: "mame-libretro/mame2003", kind: "hi", game: "tempest", size: 2, mtime: 0))
        XCTAssertEqual(data, Data([1, 2]))
        let comps = URLComponents(url: try XCTUnwrap(StubURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(comps?.path, "/v1/scores/file")
        XCTAssertEqual(Set((comps?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }), ["core=mame-libretro/mame2003", "kind=hi", "game=tempest"])
    }

    func testHTTPErrorsSurface() async {
        StubURLProtocol.respond(404, body: "{}")
        do { _ = try await client().scoreData(ScoreFile(core: "a", kind: "hi", game: "b", size: 0, mtime: 0)); XCTFail() }
        catch let e as ServiceError { XCTAssertEqual(e, .http(404)) }
        catch { XCTFail("\(error)") }
    }
}

final class UnifiedScoresTests: XCTestCase {
    private func entry(_ machine: String, _ core: String, _ game: String, top: Int?, mtime: Int = 100) -> CollectedScore {
        let table = top.map { ScoreTable(columns: ["RANK", "SCORE", "NAME"], rows: [["1", String($0), "AAA"]]) }
        return CollectedScore(machine: machine, file: ScoreFile(core: core, kind: "hi", game: game, size: 10, mtime: mtime), table: table, note: table == nil ? "not decodable" : nil)
    }

    func testBestPerGameAcrossMachines() {
        let u = UnifiedScores(entries: [
            entry("arcade2", "mame-libretro/mame2003", "tempest", top: 73372),
            entry("xarcade", "mame-libretro/mame2003", "tempest", top: 90000),
            entry("arcade2", "mame-libretro/mame2010", "galaga", top: 302780),
        ])
        XCTAssertEqual(u.best(for: "tempest")?.machine, "xarcade")
        XCTAssertEqual(u.best(for: "galaga")?.machine, "arcade2")
        XCTAssertNil(u.best(for: "pacman"))
        XCTAssertEqual(u.games, ["galaga", "tempest"])
    }

    func testTiesGoToTheNewestFileThenTheMachineName() {
        let newer = UnifiedScores(entries: [entry("arcade2", "c", "g", top: 5, mtime: 100), entry("xarcade", "c", "g", top: 5, mtime: 200)])
        XCTAssertEqual(newer.best(for: "g")?.machine, "xarcade")
        let same = UnifiedScores(entries: [entry("xarcade", "c", "g", top: 5), entry("arcade2", "c", "g", top: 5)])
        XCTAssertEqual(same.best(for: "g")?.machine, "arcade2")
    }

    func testBestIsPerCoreBecauseFilesDoNotCrossCores() {
        let u = UnifiedScores(entries: [
            entry("arcade2", "mame-libretro/mame2003", "tempest", top: 73372),
            entry("xarcade", "mame-libretro/mame2010", "tempest", top: 99999),
        ])
        XCTAssertEqual(u.best(for: "tempest", core: "mame-libretro/mame2003")?.machine, "arcade2")
        XCTAssertEqual(u.best(for: "tempest", core: "mame-libretro/mame2010")?.machine, "xarcade")
        XCTAssertEqual(u.cores(for: "tempest"), ["mame-libretro/mame2003", "mame-libretro/mame2010"])
    }

    func testUndecodableFilesNeverWinButStillListed() {
        let u = UnifiedScores(entries: [entry("arcade2", "c", "g", top: nil), entry("xarcade", "c", "g", top: 10)])
        XCTAssertEqual(u.best(for: "g")?.machine, "xarcade")
        XCTAssertEqual(u.entries(for: "g").count, 2)
        XCTAssertNil(UnifiedScores(entries: [entry("arcade2", "c", "h", top: nil)]).best(for: "h"))
    }

    func testEntriesGroupByGameSortedByMachine() {
        let u = UnifiedScores(entries: [entry("xarcade", "c", "g", top: 1), entry("arcade2", "c", "g", top: 2)])
        XCTAssertEqual(u.entries(for: "g").map(\.machine), ["arcade2", "xarcade"])
    }
}

struct FakeDecoder: ScoreDecoder {
    func decode(game: String, data: Data) async throws -> ScoreTable {
        if game == "bad" { throw ScoreError.notDecodable("layout mismatch") }
        return ScoreTable(columns: ["RANK", "SCORE", "NAME"], rows: [["1", String(data.count * 1000), "AAA"]])
    }
}

final class ScoreCollectorTests: XCTestCase {
    private func stub() {
        StubURLProtocol.handler = { req in
            let body: Data
            if req.url!.path == "/v1/scores" {
                body = Data(#"{"files":[{"core":"c","kind":"hi","game":"good","size":3,"mtime":5},{"core":"c","kind":"hi","game":"bad","size":3,"mtime":5},{"core":"c","kind":"nv","game":"nv1","size":3,"mtime":5}]}"#.utf8)
            } else { body = Data([1, 2, 3]) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
    }

    func testCollectDecodesHiFilesAndNotesTheRest() async throws {
        stub()
        let collector = ScoreCollector(service: ServiceClient(host: "h", port: 1, session: StubURLProtocol.session), decoder: FakeDecoder())
        let out = try await collector.collect(machine: "arcade2")
        XCTAssertEqual(out.map(\.file.game), ["good", "bad", "nv1"])
        XCTAssertEqual(out[0].topScore, 3000)
        XCTAssertEqual(out[0].data, Data([1, 2, 3]))
        XCTAssertEqual(out[1].note, "layout mismatch")
        XCTAssertNil(out[1].table)
        XCTAssertEqual(out[2].note, "NVRAM cannot be decoded")
        XCTAssertNil(out[2].data)  // not fetched
    }

    func testAFileThatCannotBeFetchedDoesNotDropTheMachine() async throws {
        StubURLProtocol.handler = { req in
            let list = req.url!.path == "/v1/scores"
            let body = list ? #"{"files":[{"core":"c","kind":"hi","game":"gone","size":3,"mtime":5},{"core":"c","kind":"hi","game":"good","size":3,"mtime":5}]}"# : "xyz"
            let code = !list && req.url!.query!.contains("gone") ? 404 : 200
            return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let out = try await ScoreCollector(service: ServiceClient(host: "h", port: 1, session: StubURLProtocol.session), decoder: FakeDecoder()).collect(machine: "m")
        XCTAssertEqual(out.map(\.file.game), ["gone", "good"])
        XCTAssertEqual(out[0].note, "could not read: service answered 404")
        XCTAssertNotNil(out[1].table)
    }

    func testWithoutADecoderFilesAreStillCollected() async throws {
        stub()
        let out = try await ScoreCollector(service: ServiceClient(host: "h", port: 1, session: StubURLProtocol.session), decoder: nil).collect(machine: "m")
        XCTAssertEqual(out[0].note, "decoder not set up")
        XCTAssertEqual(out[0].data, Data([1, 2, 3]))
    }
}

final class CountingDecoder: ScoreDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func decode(game: String, data: Data) async throws -> ScoreTable {
        lock.withLock { count += 1 }
        if game == "bad" { throw ScoreError.notDecodable("nope") }
        return ScoreTable(columns: ["SCORE"], rows: [[String(data.count)]])
    }
}

final class CachingDecoderTests: XCTestCase {
    func testSameGameAndBytesDecodeOnce() async throws {
        let inner = CountingDecoder()
        let cache = CachingDecoder(inner)
        let a = try await cache.decode(game: "g", data: Data([1, 2]))
        let b = try await cache.decode(game: "g", data: Data([1, 2]))
        XCTAssertEqual(a, b)
        XCTAssertEqual(inner.calls, 1)
        _ = try await cache.decode(game: "g", data: Data([1, 2, 3]))  // different bytes
        _ = try await cache.decode(game: "h", data: Data([1, 2]))     // different game
        XCTAssertEqual(inner.calls, 3)
    }

    func testFailuresAreCachedToo() async {
        let inner = CountingDecoder()
        let cache = CachingDecoder(inner)
        for _ in 0..<2 {
            do { _ = try await cache.decode(game: "bad", data: Data([9])); XCTFail() }
            catch let e as ScoreError { XCTAssertEqual(e, .notDecodable("nope")) } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(inner.calls, 1)
    }

    func testCollectorKeepsFileOrderWhenDecodingInParallel() async throws {
        let games = (0..<20).map { "g\($0)" }
        StubURLProtocol.handler = { req in
            let files = games.map { #"{"core":"c","kind":"hi","game":"\#($0)","size":1,"mtime":1}"# }.joined(separator: ",")
            let body = req.url!.path == "/v1/scores" ? #"{"files":[\#(files)]}"# : "x"
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let out = try await ScoreCollector(service: ServiceClient(host: "h", port: 1, session: StubURLProtocol.session), decoder: CountingDecoder()).collect(machine: "m")
        XCTAssertEqual(out.map(\.file.game), games)
        XCTAssertTrue(out.allSatisfy { $0.table != nil })
    }
}

final class IncrementalCollectTests: XCTestCase {
    private func listing(_ files: [(game: String, md5: String?)]) -> String {
        let items = files.map { #"{"core":"c","kind":"hi","game":"\#($0.game)","size":3,"mtime":5\#($0.md5.map { #","md5":"\#($0)""# } ?? "")}"# }.joined(separator: ",")
        return #"{"files":[\#(items)]}"#
    }
    private func stub(_ files: [(game: String, md5: String?)], fetched: Counter) {
        StubURLProtocol.handler = { req in
            let body: Data
            if req.url!.path == "/v1/scores" { body = Data(self.listing(files).utf8) } else { fetched.add(req.url!.query ?? ""); body = Data([1, 2, 3]) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
    }
    private func collector(_ decoder: ScoreDecoder = FakeDecoder()) -> ScoreCollector {
        ScoreCollector(service: ServiceClient(host: "h", port: 1, session: StubURLProtocol.session), decoder: decoder)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    func testUnchangedFilesAreNotFetchedOrDecodedAgain() async throws {
        let counter = Counter(), decoder = CountingDecoder()
        stub([("a", "m1"), ("b", "m2")], fetched: counter)
        let first = try await collector(decoder).collect(machine: "arcade2")
        XCTAssertEqual(counter.all.count, 2); XCTAssertEqual(decoder.calls, 2)
        XCTAssertEqual(first.map(\.file.md5), ["m1", "m2"])

        let second = try await collector(decoder).collect(machine: "arcade2", previous: first)
        XCTAssertEqual(counter.all.count, 2, "no new downloads"); XCTAssertEqual(decoder.calls, 2, "no new decodes")
        XCTAssertEqual(second, first)
    }

    func testOnlyTheChangedFileIsFetchedAndDecoded() async throws {
        let counter = Counter(), decoder = CountingDecoder()
        stub([("a", "m1"), ("b", "m2")], fetched: counter)
        let first = try await collector(decoder).collect(machine: "m")
        stub([("a", "m1"), ("b", "CHANGED")], fetched: counter)
        let second = try await collector(decoder).collect(machine: "m", previous: first)
        XCTAssertEqual(counter.all.count, 3)
        XCTAssertTrue(counter.all[2].contains("game=b"))
        XCTAssertEqual(decoder.calls, 3)
        XCTAssertEqual(second.map(\.file.md5), ["m1", "CHANGED"])
    }

    func testFilesRemovedFromTheCabinetDropOutAndNewOnesAreAdded() async throws {
        let counter = Counter()
        stub([("a", "m1"), ("b", "m2")], fetched: counter)
        let first = try await collector().collect(machine: "m")
        stub([("b", "m2"), ("c", "m3")], fetched: counter)
        let second = try await collector().collect(machine: "m", previous: first)
        XCTAssertEqual(second.map(\.file.game), ["b", "c"])
    }

    func testWithoutAnMD5TheSizeAndModifiedTimeDecideSoOldServicesStillWork() async throws {
        let counter = Counter()
        stub([("a", nil)], fetched: counter)
        let first = try await collector().collect(machine: "m")
        _ = try await collector().collect(machine: "m", previous: first)
        XCTAssertEqual(counter.all.count, 1)
    }

    func testTemporaryFailuresAreRetriedNotCached() async throws {
        let counter = Counter()
        stub([("a", "m1")], fetched: counter)
        // an entry that only failed because the decoder was missing must be tried again
        let stale = [CollectedScore(machine: "m", file: ScoreFile(core: "c", kind: "hi", game: "a", size: 3, mtime: 5, md5: "m1"), table: nil, note: "decoder not set up", data: Data([1]))]
        let again = try await collector().collect(machine: "m", previous: stale)
        XCTAssertNotNil(again[0].table)
        // but a definitive "not decodable" answer is kept
        let definitive = [CollectedScore(machine: "m", file: ScoreFile(core: "c", kind: "hi", game: "a", size: 3, mtime: 5, md5: "m1"), table: nil, note: "layout mismatch", data: Data([1]))]
        let before = counter.all.count
        let kept = try await collector().collect(machine: "m", previous: definitive)
        XCTAssertEqual(kept, definitive)
        XCTAssertEqual(counter.all.count, before)
    }
}

final class ScoreCacheTests: XCTestCase {
    private func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("scores-\(UUID().uuidString).json") }
    private let sample = [
        CollectedScore(machine: "arcade2", file: ScoreFile(core: "c", kind: "hi", game: "g", size: 3, mtime: 5, md5: "abc"),
                       table: ScoreTable(columns: ["RANK", "SCORE"], rows: [["1", "900"]]), note: nil, data: Data([1, 2, 3])),
        CollectedScore(machine: "xarcade", file: ScoreFile(core: "c", kind: "nv", game: "h", size: 9, mtime: 6), table: nil, note: "NVRAM cannot be decoded"),
    ]

    func testSaveAndLoadRoundTrip() throws {
        let u = url(); defer { try? FileManager.default.removeItem(at: u) }
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try ScoreCache.save(ScoreCache(entries: sample, collectedAt: when), to: u)
        let loaded = try XCTUnwrap(ScoreCache.load(from: u))
        XCTAssertEqual(loaded.entries, sample)
        XCTAssertEqual(loaded.collectedAt, when)
    }

    func testMissingOrCorruptCacheIsJustEmpty() throws {
        XCTAssertNil(ScoreCache.load(from: url()))
        let u = url(); defer { try? FileManager.default.removeItem(at: u) }
        try "garbage".write(to: u, atomically: true, encoding: .utf8)
        XCTAssertNil(ScoreCache.load(from: u))  // a bad cache must never block the app; it is rebuilt
    }

    func testEntriesForOneMachineCanBeReplacedWithoutTouchingTheOthers() {
        let cache = ScoreCache(entries: sample, collectedAt: Date())
        let fresh = [CollectedScore(machine: "arcade2", file: ScoreFile(core: "c", kind: "hi", game: "new", size: 1, mtime: 1), table: nil, note: "x")]
        let merged = cache.replacing(machine: "arcade2", with: fresh)
        XCTAssertEqual(merged.entries.map { "\($0.machine)/\($0.file.game)" }, ["xarcade/h", "arcade2/new"])
        XCTAssertEqual(cache.entries(for: "arcade2").count, 1)
    }

    func testMachinesNoLongerConfiguredAreDropped() {
        let cache = ScoreCache(entries: sample, collectedAt: Date())
        XCTAssertEqual(cache.keeping(machines: ["arcade2"]).entries.map(\.machine), ["arcade2"])
    }
}
