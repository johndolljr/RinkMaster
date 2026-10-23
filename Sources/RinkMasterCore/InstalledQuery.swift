import Foundation

/// What a cabinet's game list is showing: every filter the Games screen has (through `GameQuery`), plus the two that only make
/// sense on a cabinet: which RetroPie system folder a game sits in, and which emulator runs it.
public struct InstalledQuery: Equatable, Sendable {
    /// `installed` is ignored here; everything else filters the cabinet's games by their catalog entry.
    public var game = GameQuery()
    /// The cabinet's system folder, e.g. mame-libretro or atari2600.
    public var system: String?
    public var emulator: String?
    public var pinnedOnly = false

    public init(game: GameQuery = GameQuery(), system: String? = nil, emulator: String? = nil, pinnedOnly: Bool = false) {
        self.game = game; self.system = system; self.emulator = emulator; self.pinnedOnly = pinnedOnly
    }

    public var isFiltering: Bool { self != InstalledQuery() }
}

public struct InstalledEntry: Equatable, Identifiable, Sendable {
    public let game: InstalledGame
    /// The master catalog entry; nil for games the catalog does not know.
    public let info: GameInfo?
    public var id: String { "\(game.system)/\(game.name)" }
    public var title: String { info?.title ?? game.name }
}

extension MachineInventory {
    /// The catalog entry for an installed game, if the master has it.
    public func info(for game: InstalledGame, in catalog: GameCatalog?) -> GameInfo? {
        catalog?.exactGame(GameInfo.key(forCabinetSystem: game.system, name: game.name))
    }

    /// The games matching `q`, grouped by system (empty systems dropped), sorted as `q.game.sort` says.
    /// Games the catalog does not know still match on text, system, emulator and pinned; any filter that needs
    /// catalog data (decade, maker, letter, clones, art, history) leaves them out.
    public func entries(matching q: InstalledQuery, catalog: GameCatalog?) -> [(system: String, entries: [InstalledEntry])] {
        let needle = q.game.text.trimmingCharacters(in: .whitespaces).lowercased()
        var groups: [(system: String, entries: [InstalledEntry])] = []
        for system in systems where q.system == nil || q.system == system.name {
            var list: [InstalledEntry] = []
            for game in system.games {
                if q.pinnedOnly && !game.isPinned { continue }
                if let e = q.emulator, (game.emulator ?? "(none)") != e { continue }
                let info = self.info(for: game, in: catalog)
                if let info {
                    let hay = "\(info.title)\n\(info.name)\n\(info.year)\n\(info.manufacturer)\n\(info.system)".lowercased()
                    if !q.game.matches(info, hay: hay) { continue }
                } else {
                    if q.game.filtersOnMetadata { continue }
                    if !needle.isEmpty && !game.name.lowercased().contains(needle) { continue }
                }
                list.append(InstalledEntry(game: game, info: info))
            }
            if !list.isEmpty { groups.append((system.name, Self.sorted(list, by: q.game.sort))) }
        }
        return groups
    }

    private static func sorted(_ list: [InstalledEntry], by sort: GameSort) -> [InstalledEntry] {
        let byTitle = list.sorted { $0.title.lowercased() < $1.title.lowercased() }
        switch sort {
        case .title: return byTitle
        case .year: return byTitle.enumerated().sorted { a, b in
            let ya = a.element.info?.decade == nil ? Int.max : Int(a.element.info!.year.replacingOccurrences(of: "?", with: "0")) ?? Int.max
            let yb = b.element.info?.decade == nil ? Int.max : Int(b.element.info!.year.replacingOccurrences(of: "?", with: "0")) ?? Int.max
            return ya != yb ? ya < yb : a.offset < b.offset }.map(\.element)
        case .maker: return byTitle.enumerated().sorted { a, b in
            let ma = a.element.info?.maker.lowercased() ?? "~", mb = b.element.info?.maker.lowercased() ?? "~"
            return ma != mb ? ma < mb : a.offset < b.offset }.map(\.element)
        }
    }

    /// What the filter menus offer for this cabinet: only values that exist among its games, with counts.
    public struct Facets: Equatable, Sendable {
        public var systems: [(name: String, count: Int)] = []
        public var emulators: [(name: String, count: Int)] = []
        public var decades: [(decade: Int, count: Int)] = []
        public var makers: [(name: String, count: Int)] = []
        public var letters: [Character] = []

        public static func == (a: Facets, b: Facets) -> Bool {
            a.systems.map { "\($0.name)\($0.count)" } == b.systems.map { "\($0.name)\($0.count)" }
                && a.emulators.map { "\($0.name)\($0.count)" } == b.emulators.map { "\($0.name)\($0.count)" }
                && a.decades.map { "\($0.decade)\($0.count)" } == b.decades.map { "\($0.decade)\($0.count)" }
                && a.makers.map { "\($0.name)\($0.count)" } == b.makers.map { "\($0.name)\($0.count)" } && a.letters == b.letters
        }
    }

    public func facets(catalog: GameCatalog?) -> Facets {
        func ranked(_ counts: [String: Int]) -> [(name: String, count: Int)] {
            counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        }
        var f = Facets()
        var emu: [String: Int] = [:], mk: [String: Int] = [:], dec: [Int: Int] = [:]
        var letters = Set<Character>()
        for system in systems {
            f.systems.append((system.name, system.games.count))
            for g in system.games {
                emu[g.emulator ?? "(none)", default: 0] += 1
                guard let info = info(for: g, in: catalog) else { continue }
                letters.insert(info.letter)
                if info.isMame { mk[info.maker, default: 0] += 1 }
                if let d = info.decade { dec[d, default: 0] += 1 }
            }
        }
        f.systems.sort { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        f.emulators = ranked(emu)
        f.makers = ranked(mk)
        f.decades = dec.map { (decade: $0.key, count: $0.value) }.sorted { $0.decade < $1.decade }
        f.letters = letters.sorted { $0 == "#" ? $1 != "#" : ($1 == "#" ? false : $0 < $1) }
        return f
    }
}
