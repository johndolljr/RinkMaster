import Foundation

public struct GameInfo: Equatable, Identifiable, Sendable, Codable {
    /// Unique across systems: a MAME game is its ROM name, anything else is `system/name`.
    public var id: String { Self.key(system: system, name: name) }
    public let name: String
    public let title: String
    public let year: String
    public let manufacturer: String
    public let cloneOf: String?
    public let artTypes: [String]
    public let hasHistory: Bool
    /// The ROM sets needed to run it (itself, parents/BIOS, ROM-bearing devices), so adding a game never needs the XML.
    public let romSets: [String]
    /// "mame" for arcade ROM sets, otherwise the RetroPie system the file belongs to (atari2600, daphne, ...).
    public let system: String
    /// For non-MAME games: the file or folder to copy, relative to the master root, e.g. `roms/other-systems/atari2600/Adventure.bin`.
    public let sourcePath: String?

    public static let mameSystem = "mame"

    public var isMame: Bool { system == Self.mameSystem }

    public static func key(system: String, name: String) -> String { system == mameSystem ? name : "\(system)/\(name)" }

    /// The catalog key of a game installed on a cabinet: ROM-zip systems (MAME, FBNeo, ...) are all "mame".
    public static func key(forCabinetSystem system: String, name: String) -> String {
        InventoryParser.zipSystems.contains(system) ? name : key(system: system, name: name)
    }

    public init(name: String, title: String, year: String, manufacturer: String, cloneOf: String?, artTypes: [String], hasHistory: Bool, romSets: [String],
                system: String = GameInfo.mameSystem, sourcePath: String? = nil) {
        self.name = name; self.title = title; self.year = year; self.manufacturer = manufacturer; self.cloneOf = cloneOf
        self.artTypes = artTypes; self.hasHistory = hasHistory; self.romSets = romSets; self.system = system; self.sourcePath = sourcePath
    }

    /// nil for devices, BIOS sets and names the XML does not know.
    static func make(name: String, database: MameDatabase, artTypes: [String], hasHistory: Bool) -> GameInfo? {
        guard let m = database.machine(name), !m.isDevice, !m.isBIOS else { return nil }
        return GameInfo(name: name, title: m.description, year: m.year, manufacturer: m.manufacturer, cloneOf: m.cloneOf, artTypes: artTypes,
                        hasHistory: hasHistory, romSets: (try? database.requiredRomSets(for: name)) ?? [name])
    }

    func with(artTypes: [String], hasHistory: Bool) -> GameInfo {
        GameInfo(name: name, title: title, year: year, manufacturer: manufacturer, cloneOf: cloneOf, artTypes: artTypes, hasHistory: hasHistory, romSets: romSets,
                 system: system, sourcePath: sourcePath)
    }
}

/// Every runnable game in the master, with its MAME metadata, available art and history write-up.
public struct GameCatalog: Sendable {
    public let games: [GameInfo]
    private let byName: [String: GameInfo]
    /// Non-MAME games by bare name, only where the name is unique, so `game("Pitfall")` finds it without the system.
    private let byBareName: [String: GameInfo]
    /// Title order and a lowercase search string per game, computed once so filtering 30,000 games stays quick.
    let indexed: [(game: GameInfo, hay: String)]

    public init(master: MasterLibrary, database: MameDatabase, history: HistoryDatabase) {
        let artIndex = master.artIndex()
        self.init(games: master.allRomSetNames().compactMap { name in
            GameInfo.make(name: name, database: database, artTypes: (artIndex[name] ?? []).sorted(), hasHistory: history.text(for: name) != nil)
        } + master.otherSystemGames())
    }

    public init(games: [GameInfo]) {
        self.games = games
        byName = Dictionary(games.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let bare = Dictionary(grouping: games.filter { !$0.isMame }, by: { $0.name })
        byBareName = bare.compactMapValues { $0.count == 1 ? $0[0] : nil }
        indexed = games.map { ($0, "\($0.title)\n\($0.name)\n\($0.year)\n\($0.manufacturer)\n\($0.system)".lowercased()) }
            .sorted { a, b in
                let ta = a.game.title.lowercased(), tb = b.game.title.lowercased()
                return ta == tb ? a.game.name < b.game.name : ta < tb
            }
    }

    /// By catalog key: the ROM name for MAME games, `system/name` for the rest.
    public func game(_ key: String) -> GameInfo? { byName[key] ?? byBareName[key] }

    /// Only an exact catalog key, never the bare-name shortcut.
    public func exactGame(_ key: String) -> GameInfo? { byName[key] }

    /// Case-insensitive match on title, ROM name, year or manufacturer; a blank query lists everything.
    public func search(_ query: String) -> [GameInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return games }
        return games.filter { [$0.title, $0.name, $0.year, $0.manufacturer].contains { $0.lowercased().contains(q) } }
    }
}

/// Which machines already have each game, from their inventories.
public struct InstalledIndex: Sendable {
    public struct Entry: Equatable, Sendable {
        public let machine: String
        public let system: String
        public let emulator: String?
    }

    private let index: [String: [Entry]]

    public init(inventories: [String: MachineInventory]) {
        var index: [String: [Entry]] = [:]
        for machine in inventories.keys.sorted() {
            for system in inventories[machine]!.systems {
                for game in system.games {
                    index[GameInfo.key(forCabinetSystem: system.name, name: game.name), default: []].append(Entry(machine: machine, system: system.name, emulator: game.emulator))
                }
            }
        }
        self.index = index
    }

    /// `game` is the catalog key (`GameInfo.id`).
    public func entries(for game: String) -> [Entry] { index[game] ?? [] }
}
