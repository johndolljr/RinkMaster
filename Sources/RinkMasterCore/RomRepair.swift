import Foundation

/// Finds the support ROM sets (device ROMs, BIOS, parents) that games installed on a cabinet need but the cabinet does not have.
/// Games added by older tools, or copied by hand, often lack them, and then fail to start with "required files are missing".
public enum RomRepair {
    public struct Missing: Equatable, Sendable {
        public let system: String
        /// The ROM set (zip name without extension) to copy, e.g. `namcoc76`.
        public let set: String
        /// The emulator whose set version decides which master copy is used.
        public let emulator: String?
        public let neededBy: [String]
        /// The file in the master, or nil when the master has no copy.
        public let source: URL?
    }

    /// Per installed MAME game, every ROM set it needs (from the catalog) that is not in the same cabinet folder.
    public static func plan(inventory: MachineInventory, catalog: GameCatalog, master: MasterLibrary) -> [Missing] {
        var out: [Missing] = []
        for system in inventory.systems where InventoryParser.zipSystems.contains(system.name) {
            let present = Set(system.games.map(\.name))
            var needed: [String: (emulator: String?, by: [String])] = [:]
            for game in system.games {
                guard let info = catalog.exactGame(game.name), info.isMame else { continue }
                for set in info.romSets where !present.contains(set) {
                    var entry = needed[set] ?? (game.emulator, [])
                    entry.by.append(game.name)
                    needed[set] = entry
                }
            }
            for (set, entry) in needed.sorted(by: { $0.key < $1.key }) {
                out.append(Missing(system: system.name, set: set, emulator: entry.emulator, neededBy: entry.by.sorted(),
                                   source: master.locate(romSet: set, emulator: entry.emulator)))
            }
        }
        return out
    }
}
