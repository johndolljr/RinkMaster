import Foundation

/// Where each game's write-up sits inside `history.dat`, so the 36 MB file is scanned once and read only for the game on screen.
public struct HistoryIndex: Sendable, Equatable {
    public struct Span: Codable, Equatable, Sendable {
        public let offset: Int
        public let length: Int
        public init(offset: Int, length: Int) { self.offset = offset; self.length = length }
    }

    public let spans: [String: Span]

    public init(spans: [String: Span]) { self.spans = spans }

    /// Indexes the arcade `$info=` entries (the text between `$bio` and `$end`).
    public static func scan(_ data: Data) -> HistoryIndex {
        var spans: [String: Span] = [:]
        var names: [String] = []
        var bodyStart: Int?
        func finish(at position: Int) {
            if let start = bodyStart, !names.isEmpty, position > start {
                for n in names { spans[n] = Span(offset: start, length: position - start) }
            }
            names = []; bodyStart = nil
        }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            func hasPrefix(_ at: Int, _ prefix: StaticString) -> Bool {
                let n = prefix.utf8CodeUnitCount
                guard at + n <= count else { return false }
                return memcmp(bytes.baseAddress! + at, prefix.utf8Start, n) == 0
            }
            var lineStart = 0
            while lineStart < count {
                var lineEnd = lineStart
                while lineEnd < count && bytes[lineEnd] != 0x0A { lineEnd += 1 }
                let next = min(lineEnd + 1, count)
                if bytes[lineStart] == 0x24 {  // '$'
                    if hasPrefix(lineStart, "$info=") {
                        finish(at: lineStart)
                        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[(lineStart + 6)..<lineEnd]), as: UTF8.self)
                        names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    } else if hasPrefix(lineStart, "$bio") {
                        if !names.isEmpty { bodyStart = next }
                    } else if hasPrefix(lineStart, "$end") {
                        finish(at: lineStart)
                    } else if lineEnd > lineStart, bytes[lineStart..<lineEnd].contains(0x3D) {  // another system's `$x=...` header
                        finish(at: lineStart)
                    }
                }
                lineStart = next
            }
            finish(at: count)
        }
        return HistoryIndex(spans: spans)
    }

    public func text(for game: String, in file: URL) -> String? {
        guard let span = spans[game], let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(span.offset))
            guard let data = try handle.read(upToCount: span.length) else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }

    public func sections(for game: String, in file: URL) -> [HistoryDatabase.Section]? {
        text(for: game, in: file).map { HistoryDatabase.sections(in: $0) }
    }
}

/// The finished catalog kept on disk so the app starts with the game list already in hand.
public struct CatalogCache: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version = CatalogCache.currentVersion
    public var xmlSignature: String
    public var historySignature: String
    /// Every ROM set name seen at the last build, including devices and BIOS sets, so those are not mistaken for new games.
    public var knownNames: [String]
    public var games: [GameInfo]
    public var history: [String: HistoryIndex.Span]
    public var builtAt: Date

    public init(xmlSignature: String, historySignature: String, knownNames: [String], games: [GameInfo],
                history: [String: HistoryIndex.Span], builtAt: Date) {
        self.xmlSignature = xmlSignature; self.historySignature = historySignature; self.knownNames = knownNames
        self.games = games; self.history = history; self.builtAt = builtAt
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RinkMaster/catalog-cache.json")
    }

    /// nil when missing, unreadable or from another version; the catalog is then rebuilt from the master.
    public static func load(from url: URL = defaultURL) -> CatalogCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(CatalogCache.self, from: data), cache.version == currentVersion else { return nil }
        return cache
    }

    public static func save(_ cache: CatalogCache, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(cache).write(to: url, options: .atomic)
    }

    public var historyIndex: HistoryIndex { HistoryIndex(spans: history) }
}

public struct CatalogUpdate: Sendable {
    public let cache: CatalogCache
    public let added: [String]
    public let removed: [String]
    /// True when the XML itself changed and every game was rebuilt.
    public let rebuilt: Bool
    public let changed: Bool
}

/// Brings a cached catalog up to date with the master. The 52 MB XML is parsed only when it changed or when the master has
/// ROM sets the cache has never seen; added and removed games, new art and a new history file are picked up from cheap
/// folder listings and file signatures.
public struct CatalogUpdater: Sendable {
    private let master: MasterLibrary
    private let loadDatabase: @Sendable (URL) throws -> MameDatabase

    public init(master: MasterLibrary, loadDatabase: @escaping @Sendable (URL) throws -> MameDatabase = { try MameDatabase.parse(Data(contentsOf: $0)) }) {
        self.master = master; self.loadDatabase = loadDatabase
    }

    private static func signature(_ url: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path), let size = a[.size] as? Int,
              let date = a[.modificationDate] as? Date else { return nil }
        return "\(size)-\(Int(date.timeIntervalSince1970))"
    }

    public func refresh(previous: CatalogCache?) throws -> CatalogUpdate {
        let xmlURL = master.root.appendingPathComponent("data/mame2016.xml")
        let historyURL = master.root.appendingPathComponent("data/history.dat")
        guard let xmlSignature = Self.signature(xmlURL) else { throw CocoaError(.fileNoSuchFile) }
        let historySignature = Self.signature(historyURL) ?? "none"

        let names = master.allRomSetNames()
        let art = master.artIndex()
        let history: [String: HistoryIndex.Span]
        if let previous, previous.historySignature == historySignature { history = previous.history }
        else if let data = try? Data(contentsOf: historyURL, options: .mappedIfSafe) { history = HistoryIndex.scan(data).spans }
        else { history = [:] }

        let rebuild = previous == nil || previous!.xmlSignature != xmlSignature
        let known = Set(rebuild ? [] : previous!.knownNames)
        let reusable = Dictionary((rebuild ? [] : previous!.games).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let fresh = names.filter { !known.contains($0) }
        let others = master.otherSystemGames()  // folder listings only; no XML needed

        var database: MameDatabase?
        if !fresh.isEmpty { database = try loadDatabase(xmlURL) }
        var games: [GameInfo] = []
        for name in names {
            let artTypes = (art[name] ?? []).sorted()
            let hasHistory = history[name] != nil
            if let old = reusable[name] { games.append(old.with(artTypes: artTypes, hasHistory: hasHistory)) }
            else if let database, let info = GameInfo.make(name: name, database: database, artTypes: artTypes, hasHistory: hasHistory) { games.append(info) }
        }

        games += others

        let before = Dictionary((previous?.games ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Set(games.map(\.id))
        let added = games.map(\.id).filter { before[$0] == nil }
        let removed = before.keys.filter { !after.contains($0) }.sorted()
        let changed = previous == nil || !added.isEmpty || !removed.isEmpty || previous!.games != games
            || previous!.xmlSignature != xmlSignature || previous!.historySignature != historySignature
        let cache = CatalogCache(xmlSignature: xmlSignature, historySignature: historySignature, knownNames: names, games: games, history: history, builtAt: Date())
        return CatalogUpdate(cache: cache, added: added, removed: removed, rebuilt: rebuild, changed: changed)
    }
}
