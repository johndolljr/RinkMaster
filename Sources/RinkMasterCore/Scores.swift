import Foundation

public enum ScoreError: Error, Equatable {
    /// The game has no definition, the file does not match it, or the file is NVRAM.
    case notDecodable(String)
    /// Java or the hi2txt files are missing, so nothing can be decoded.
    case decoderUnavailable(String)
}

/// A score table as hi2txt prints it: a header row of column names and the rows beneath.
public struct ScoreTable: Equatable, Sendable, Codable {
    public let columns: [String]
    public let rows: [[String]]

    public init(columns: [String], rows: [[String]]) { self.columns = columns; self.rows = rows }

    /// Parses `COL|COL` text. Returns nil for empty output, errors, or a header with no rows.
    public static func parse(_ text: String) -> ScoreTable? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first, !header.hasPrefix("ERROR"), lines.count > 1 else { return nil }
        let rows = lines.dropFirst().map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
        return ScoreTable(columns: header.split(separator: "|").map(String.init), rows: rows)
    }

    /// The largest value in the SCORE column, ignoring digit-group separators.
    public var topScore: Int? {
        guard let index = columns.firstIndex(of: "SCORE") else { return nil }
        let values = rows.compactMap { $0.indices.contains(index) ? Int($0[index].filter(\.isNumber)) : nil }
        return values.max()
    }
}

/// Decodes a raw `.hi` file into a table.
public protocol ScoreDecoder: Sendable {
    func decode(game: String, data: Data) async throws -> ScoreTable
}

/// Runs the bundled hi2txt jar (it finds a game's layout by the file's name, so the bytes are staged as `<game>.hi`).
public struct Hi2txtDecoder: ScoreDecoder {
    public let java: String
    public let jar: String
    public let definitions: String
    private let runner: ProcessRunning

    public init(java: String, jar: String, definitions: String, runner: ProcessRunning = SystemProcessRunner()) {
        self.java = java; self.jar = jar; self.definitions = definitions; self.runner = runner
    }

    /// The decoder set up from the master (`tools/hi2txt/hi2txt.jar`, `data/hi2txt/*.xml`), or nil if either is missing.
    public static func inMaster(_ master: MasterLibrary, java: String) -> Hi2txtDecoder? {
        let jar = master.root.appendingPathComponent("tools/hi2txt/hi2txt.jar").path
        let defs = master.root.appendingPathComponent("data/hi2txt").path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: jar), FileManager.default.fileExists(atPath: defs, isDirectory: &isDir), isDir.boolValue else { return nil }
        return Hi2txtDecoder(java: java, jar: jar, definitions: defs)
    }

    private static let nameRule = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._+\\-]*$")

    public func decode(game: String, data: Data) async throws -> ScoreTable {
        let range = NSRange(game.startIndex..., in: game)
        guard Self.nameRule.firstMatch(in: game, range: range) != nil, !game.contains("..") else { throw ScoreError.notDecodable("bad game name") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rinkmaster-hi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appendingPathComponent(game + ".hi")
        try data.write(to: staged)
        let result: CommandResult
        do {
            result = try await runner.run(java, ["-jar", jar, "-r", "-descr", definitions, "-notrace", staged.path], timeout: 30)
        } catch ProcessError.launchFailed(let why) {
            throw ScoreError.decoderUnavailable(why)
        } catch ProcessError.timedOut {
            throw ScoreError.notDecodable("decoder timed out")
        }
        if let table = ScoreTable.parse(result.stdout) { return table }
        let firstLine = result.stdout.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if firstLine.hasPrefix("ERROR:") { throw ScoreError.notDecodable(String(firstLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)) }
        throw ScoreError.notDecodable(result.stderr.isEmpty ? "no scores in file" : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// A score file on a cabinet, as listed by the service.
public struct ScoreFile: Equatable, Hashable, Sendable, Codable {
    public let core: String
    public let kind: String
    public let game: String
    public let size: Int
    public let mtime: Int
    /// MD5 of the file's bytes as reported by the cabinet service (nil from an older service).
    public let md5: String?

    public init(core: String, kind: String, game: String, size: Int, mtime: Int, md5: String? = nil) {
        self.core = core; self.kind = kind; self.game = game; self.size = size; self.mtime = mtime; self.md5 = md5
    }

    /// True if `other` is the same bytes: equal MD5s, or (without MD5s) the same size and modification time.
    func sameContent(as other: ScoreFile) -> Bool {
        if let a = md5, let b = other.md5 { return a == b }
        return size == other.size && mtime == other.mtime
    }

    var identity: String { "\(core)|\(kind)|\(game)" }

    /// Only `.hi` snapshots can be decoded; `.nv` NVRAM images cannot.
    public var isDecodable: Bool { kind == "hi" }
}

/// One cabinet's score file with whatever could be decoded from it.
public struct CollectedScore: Equatable, Sendable, Codable {
    public let machine: String
    public let file: ScoreFile
    public let table: ScoreTable?
    public let note: String?
    public let data: Data?

    public init(machine: String, file: ScoreFile, table: ScoreTable?, note: String?, data: Data? = nil) {
        self.machine = machine; self.file = file; self.table = table; self.note = note; self.data = data
    }

    public var topScore: Int? { table?.topScore }

    /// A result worth keeping until the file changes. Failures that were only down to the decoder being missing or the
    /// download failing are tried again next time.
    var isDefinitive: Bool {
        if table != nil { return true }
        guard let note else { return false }
        return !(note == "decoder not set up" || note == "decoder unavailable" || note.hasPrefix("could not read"))
    }
}

/// The last collected scores, kept on disk so the app shows them at once and only re-reads what changed.
public struct ScoreCache: Equatable, Sendable, Codable {
    public let entries: [CollectedScore]
    public let collectedAt: Date

    public init(entries: [CollectedScore], collectedAt: Date) { self.entries = entries; self.collectedAt = collectedAt }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RinkMaster/score-cache.json")
    }

    /// nil if there is no cache or it cannot be read; a bad cache just means collecting from scratch.
    public static func load(from url: URL = defaultURL) -> ScoreCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScoreCache.self, from: data)
    }

    public static func save(_ cache: ScoreCache, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(cache).write(to: url, options: .atomic)
    }

    public func entries(for machine: String) -> [CollectedScore] { entries.filter { $0.machine == machine } }

    public func replacing(machine: String, with fresh: [CollectedScore]) -> ScoreCache {
        ScoreCache(entries: entries.filter { $0.machine != machine } + fresh, collectedAt: collectedAt)
    }

    public func keeping(machines: Set<String>) -> ScoreCache {
        ScoreCache(entries: entries.filter { machines.contains($0.machine) }, collectedAt: collectedAt)
    }
}

/// Scores from every cabinet, grouped by game. A `.hi` file can only be used by the core that wrote it, so the
/// winner is chosen per game and core (or across all cores for display).
public struct UnifiedScores: Sendable {
    private let byGame: [String: [CollectedScore]]

    public init(entries: [CollectedScore]) {
        byGame = Dictionary(grouping: entries, by: \.file.game).mapValues { $0.sorted { ($0.machine, $0.file.core) < ($1.machine, $1.file.core) } }
    }

    public var games: [String] { byGame.keys.sorted() }

    public func entries(for game: String) -> [CollectedScore] { byGame[game] ?? [] }

    public func cores(for game: String) -> [String] { Array(Set(entries(for: game).map(\.file.core))).sorted() }

    /// Highest top score; ties go to the newest file, then the machine name. Undecodable files never win.
    public func best(for game: String, core: String? = nil) -> CollectedScore? {
        entries(for: game)
            .filter { core == nil || $0.file.core == core }
            .filter { $0.topScore != nil }
            .min { a, b in
                if a.topScore! != b.topScore! { return a.topScore! > b.topScore! }
                if a.file.mtime != b.file.mtime { return a.file.mtime > b.file.mtime }
                return a.machine < b.machine
            }
    }
}

/// Remembers decode results by game and file contents, so collecting again only decodes files that changed.
public actor CachingDecoder: ScoreDecoder {
    private struct Key: Hashable { let game: String; let data: Data }
    private let inner: ScoreDecoder
    private var cache: [Key: Result<ScoreTable, ScoreError>] = [:]

    public init(_ inner: ScoreDecoder) { self.inner = inner }

    public func decode(game: String, data: Data) async throws -> ScoreTable {
        let key = Key(game: game, data: data)
        if let hit = cache[key] { return try hit.get() }
        let result: Result<ScoreTable, ScoreError>
        do { result = .success(try await inner.decode(game: game, data: data)) }
        catch let e as ScoreError { result = .failure(e) }
        cache[key] = result
        return try result.get()
    }
}

/// Fetches and decodes every score file on one cabinet (decoding a few files at a time).
public struct ScoreCollector: Sendable {
    private let service: ServiceClient
    private let decoder: ScoreDecoder?
    private let parallelism: Int

    public init(service: ServiceClient, decoder: ScoreDecoder?, parallelism: Int = 4) {
        self.service = service; self.decoder = decoder; self.parallelism = max(1, parallelism)
    }

    /// `previous` is what was collected from this machine last time: files whose MD5 has not changed are not downloaded
    /// or decoded again.
    public func collect(machine: String, previous: [CollectedScore] = []) async throws -> [CollectedScore] {
        let files = try await service.scoreFiles()
        let known = Dictionary(previous.filter(\.isDefinitive).map { ($0.file.identity, $0) }, uniquingKeysWith: { a, _ in a })
        // fetch first (cheap), keeping every file's slot so the result order matches the listing
        var slots: [CollectedScore?] = Array(repeating: nil, count: files.count)
        var toDecode: [(index: Int, data: Data)] = []
        for (i, file) in files.enumerated() {
            if let old = known[file.identity], old.file.sameContent(as: file) {
                slots[i] = CollectedScore(machine: machine, file: file, table: old.table, note: old.note, data: old.data); continue
            }
            guard file.isDecodable else {
                slots[i] = CollectedScore(machine: machine, file: file, table: nil, note: "NVRAM cannot be decoded"); continue
            }
            let data: Data
            do { data = try await service.scoreData(file) } catch ServiceError.http(let code) {
                slots[i] = CollectedScore(machine: machine, file: file, table: nil, note: "could not read: service answered \(code)"); continue
            }
            if decoder == nil { slots[i] = CollectedScore(machine: machine, file: file, table: nil, note: "decoder not set up", data: data) }
            else { toDecode.append((i, data)) }
        }
        if let decoder {
            var next = 0
            await withTaskGroup(of: (Int, CollectedScore).self) { group in
                func launch() {
                    guard next < toDecode.count else { return }
                    let (index, data) = toDecode[next]; next += 1
                    let file = files[index]
                    group.addTask {
                        do { return (index, CollectedScore(machine: machine, file: file, table: try await decoder.decode(game: file.game, data: data), note: nil, data: data)) }
                        catch ScoreError.notDecodable(let why) { return (index, CollectedScore(machine: machine, file: file, table: nil, note: why, data: data)) }
                        catch { return (index, CollectedScore(machine: machine, file: file, table: nil, note: "decoder unavailable", data: data)) }
                    }
                }
                for _ in 0..<parallelism { launch() }
                while let (index, entry) = await group.next() { slots[index] = entry; launch() }
            }
        }
        return slots.compactMap { $0 }
    }
}

extension ServiceClient {
    private struct ScoreList: Decodable { let files: [ScoreFile] }

    public func scoreFiles() async throws -> [ScoreFile] {
        let data = try await sendRaw("GET", "v1/scores")  // network errors propagate as they are, so the app can explain them
        do { return try JSONDecoder().decode(ScoreList.self, from: data).files }
        catch { throw ServiceError.decoding("\(error)") }
    }

    public func scoreData(_ file: ScoreFile) async throws -> Data {
        try await sendRaw("GET", "v1/scores/file", query: [URLQueryItem(name: "core", value: file.core), URLQueryItem(name: "kind", value: file.kind),
                                                          URLQueryItem(name: "game", value: file.game)])
    }
}
