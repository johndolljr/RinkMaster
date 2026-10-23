import Foundation

extension GameInfo {
    /// The manufacturer without license notes: "[Namco] (Midway license)" is Namco.
    public var maker: String {
        let m = manufacturer.trimmingCharacters(in: .whitespaces)
        if m.isEmpty || m == "<unknown>" { return "Unknown" }
        if m.hasPrefix("["), let close = m.firstIndex(of: "]") { return String(m[m.index(after: m.startIndex)..<close]) }
        if let open = m.range(of: " (") { return String(m[..<open.lowerBound]) }
        return m
    }

    /// 1980 for "1981" or "198?"; nil when the year is unknown ("19??").
    public var decade: Int? {
        guard year.count >= 3, year.prefix(3).allSatisfy(\.isNumber) else { return nil }
        return Int(year.prefix(3)).map { $0 * 10 }
    }

    /// First letter of the title, or "#" for digits and symbols.
    public var letter: Character {
        guard let c = title.first, c.isLetter else { return "#" }
        return Character(c.uppercased())
    }

    fileprivate var yearKey: Int { decade == nil ? Int.max : (Int(year.replacingOccurrences(of: "?", with: "0")) ?? Int.max) }
}

public enum InstalledFilter: Equatable, Sendable {
    case any, onAnyCabinet, notOnAnyCabinet
    case onMachine(String)
}

public enum GameSort: String, CaseIterable, Sendable {
    case title = "TITLE", year = "YEAR", maker = "MAKER"
}

/// What the Games screen is showing: free text plus the ways to browse when you do not know what you are looking for.
public struct GameQuery: Equatable, Sendable {
    public var text = ""
    public var hideClones = false
    public var decade: Int?
    public var maker: String?
    public var letter: Character?
    public var requireArt = false
    public var requireHistory = false
    /// Only games of this RetroPie system ("mame", "atari2600", ...).
    public var system: String?
    public var installed: InstalledFilter = .any
    public var sort: GameSort = .title

    public init(text: String = "", hideClones: Bool = false, decade: Int? = nil, maker: String? = nil, system: String? = nil, letter: Character? = nil,
                requireArt: Bool = false, requireHistory: Bool = false, installed: InstalledFilter = .any, sort: GameSort = .title) {
        self.text = text; self.hideClones = hideClones; self.decade = decade; self.maker = maker; self.system = system; self.letter = letter
        self.requireArt = requireArt; self.requireHistory = requireHistory; self.installed = installed; self.sort = sort
    }
}

extension GameQuery {
    /// True when any filter that needs the game's catalog entry (everything but text and where it is installed) is set.
    public var filtersOnMetadata: Bool {
        decade != nil || maker != nil || system != nil || letter != nil || hideClones || requireArt || requireHistory
    }

    /// Every filter except `installed`. `hay` is the game's lowercase search text.
    func matches(_ game: GameInfo, hay: String) -> Bool {
        if hideClones && game.cloneOf != nil { return false }
        if let d = decade, game.decade != d { return false }
        if let m = maker, game.maker != m { return false }
        if let s = system, game.system != s { return false }
        if let l = letter, game.letter != l { return false }
        if requireArt && game.artTypes.isEmpty { return false }
        if requireHistory && !game.hasHistory { return false }
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || hay.contains(needle)
    }
}

extension GameCatalog {
    public func query(_ q: GameQuery, installed index: InstalledIndex) -> [GameInfo] {
        var result: [GameInfo] = []
        for (game, hay) in indexed {  // already in title order
            if !q.matches(game, hay: hay) { continue }
            switch q.installed {
            case .any: break
            case .onAnyCabinet: if index.entries(for: game.id).isEmpty { continue }
            case .notOnAnyCabinet: if !index.entries(for: game.id).isEmpty { continue }
            case .onMachine(let m): if !index.entries(for: game.id).contains(where: { $0.machine == m }) { continue }
            }
            result.append(game)
        }
        switch q.sort {
        case .title: return result
        case .year: return result.enumerated().sorted { a, b in
            a.element.yearKey != b.element.yearKey ? a.element.yearKey < b.element.yearKey : a.offset < b.offset }.map(\.element)
        case .maker: return result.enumerated().sorted { a, b in
            let ma = a.element.maker.lowercased(), mb = b.element.maker.lowercased()
            return ma != mb ? ma < mb : a.offset < b.offset }.map(\.element)
        }
    }

    public var decades: [(decade: Int, count: Int)] {
        Dictionary(grouping: games.compactMap(\.decade), by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.0 < $1.0 }.map { (decade: $0.0, count: $0.1) }
    }

    /// Manufacturers, biggest first.
    public var makers: [(name: String, count: Int)] {
        let mame: [GameInfo] = games.filter { $0.isMame }
        let counts: [String: Int] = Dictionary(grouping: mame, by: { $0.maker }).mapValues { $0.count }
        return counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// Systems with their game counts, biggest first (so "mame" leads).
    public var systems: [(name: String, count: Int)] {
        let counts: [String: Int] = Dictionary(grouping: games, by: { $0.system }).mapValues { $0.count }
        return counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// The first letters in use, "#" first.
    public var letters: [Character] { Set(games.map(\.letter)).sorted { $0 == "#" ? $1 != "#" : ($1 == "#" ? false : $0 < $1) } }

    public func randomGame<G: RandomNumberGenerator>(matching q: GameQuery, installed index: InstalledIndex, using rng: inout G) -> GameInfo? {
        query(q, installed: index).randomElement(using: &rng)
    }
}

/// A small deterministic generator (SplitMix64) so "random game" can be tested.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct Pager: Equatable, Sendable {
    public let total: Int
    public let pageSize: Int

    public init(total: Int, pageSize: Int) { self.total = max(0, total); self.pageSize = max(1, pageSize) }

    public var pageCount: Int { max(1, (total + pageSize - 1) / pageSize) }

    public func range(page: Int) -> Range<Int> {
        let p = min(max(0, page), pageCount - 1)
        return (p * pageSize)..<min(total, (p + 1) * pageSize)
    }

    public func page(containing index: Int) -> Int { min(max(0, index / pageSize), pageCount - 1) }

    public func label(page: Int) -> String {
        guard total > 0 else { return "NO GAMES" }
        let r = range(page: page)
        return "\(r.lowerBound + 1)-\(r.upperBound) OF \(total)"
    }
}

/// The arithmetic behind a paged list that fits its window and is driven from the keyboard.
public enum ListNavigation {
    /// How many rows fit in `height` points; never fewer than `minimum` so a tiny window still shows something.
    public static func rows(forHeight height: Double, rowHeight: Double, minimum: Int = 5) -> Int {
        guard rowHeight > 0, height.isFinite else { return minimum }
        return max(minimum, Int(height / rowHeight))
    }

    /// The new selected index after moving `delta` rows. Nothing selected: down picks the first row, up the last. Clamped to the list.
    public static func step(selected: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let selected, (0..<count).contains(selected) else { return delta >= 0 ? 0 : count - 1 }
        return min(max(0, selected + delta), count - 1)
    }

    /// The new page after moving `delta` pages. Clamped.
    public static func page(current: Int, delta: Int, pageCount: Int) -> Int {
        min(max(0, current + delta), max(0, pageCount - 1))
    }
}
