import Foundation

/// Builds EmulationStation game-list entries for games installed on a cabinet, from what the master knows about them, so ES shows
/// a title, year, maker and description instead of "unknown". Art is not listed here: the cabinet service looks for the files that
/// really exist beside each ROM (`autoMedia`), and `onlyMissing` keeps anything the list already has (a scraper's work, say).
public enum GamelistSync {
    public static let batchSize = 100

    /// The opening of a MAME history write-up, short enough for a game-list description.
    public static func shortDescription(_ historyText: String?, limit: Int = 1200) -> String? {
        guard let text = historyText, let first = HistoryDatabase.sections(in: text).first(where: { $0.title.isEmpty && !$0.body.isEmpty }) else { return nil }
        let body = first.body
        guard body.count > limit else { return body }
        let cut = body.prefix(limit)
        if let end = cut.lastIndex(where: { ".!?".contains($0) }) { return String(cut[...end]) }
        return String(cut) + "..."
    }

    /// One installed game's entry; nil when nothing is known about it beyond its file name.
    public static func entry(for game: InstalledGame, info: GameInfo?, description: String?, scraped: GamelistEntry?) -> [String: String]? {
        var entry: [String: String] = ["path": "./" + game.file]
        if let scraped, !scraped.name.isEmpty || !scraped.desc.isEmpty {
            entry["name"] = scraped.name.isEmpty ? game.name : scraped.name
            if !scraped.desc.isEmpty { entry["desc"] = scraped.desc }
            if !scraped.releaseDate.isEmpty { entry["releasedate"] = scraped.releaseDate }
            if !scraped.developer.isEmpty { entry["developer"] = scraped.developer }
            if !scraped.publisher.isEmpty { entry["publisher"] = scraped.publisher }
            if !scraped.genre.isEmpty { entry["genre"] = scraped.genre }
            return entry
        }
        guard let info else { return nil }
        entry["name"] = info.title
        if info.year.count == 4, info.year.allSatisfy(\.isNumber) { entry["releasedate"] = info.year + "0101T000000" }
        if info.maker != "Unknown" { entry["developer"] = info.maker }
        if let description, !description.isEmpty { entry["desc"] = description }
        return entry
    }

    /// Entries for every installed game the master knows, grouped by system. `only` limits it to a few catalog keys.
    public static func entries(inventory: MachineInventory, catalog: GameCatalog?, only: Set<String>? = nil,
                               description: (GameInfo) -> String?, scraped: (String, String) -> GamelistEntry?) -> [(system: String, games: [[String: String]])] {
        var out: [(system: String, games: [[String: String]])] = []
        for system in inventory.systems {
            var games: [[String: String]] = []
            for g in system.games {
                let key = GameInfo.key(forCabinetSystem: g.system, name: g.name)
                if let only, !only.contains(key) { continue }
                let info = inventory.info(for: g, in: catalog)
                let isMame = info?.isMame ?? InventoryParser.zipSystems.contains(g.system)
                let entry = Self.entry(for: g, info: info, description: info.flatMap { isMame ? description($0) : nil },
                                       scraped: isMame ? nil : scraped(g.system, g.name))
                if let entry { games.append(entry) }
            }
            if !games.isEmpty { out.append((system.name, games)) }
        }
        return out
    }
}
