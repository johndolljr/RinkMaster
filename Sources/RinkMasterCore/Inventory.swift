import Foundation

public struct InstalledGame: Equatable, Hashable, Sendable, Codable {
    public let system: String
    /// Game name without extension (the part RetroPie uses in `<system>_<name>` pins).
    public let name: String
    /// The ROM file or folder name on the machine, e.g. `galaga.zip` or `lair.daphne`.
    public let file: String
    /// Emulator that will run it: the per-game pin if there is one, else the system default.
    public let emulator: String?
    public let isPinned: Bool
    /// Size in bytes and modification time (seconds since 1970) as reported by the cabinet service; 0 over SSH.
    public let size: Int
    public let mtime: Int

    public init(system: String, name: String, file: String, emulator: String?, isPinned: Bool, size: Int = 0, mtime: Int = 0) {
        self.system = system; self.name = name; self.file = file
        self.emulator = emulator; self.isPinned = isPinned; self.size = size; self.mtime = mtime
    }

    private enum CodingKeys: String, CodingKey { case system, name, file, emulator, isPinned, size, mtime }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        system = try c.decode(String.self, forKey: .system)
        name = try c.decode(String.self, forKey: .name)
        file = try c.decode(String.self, forKey: .file)
        emulator = try c.decodeIfPresent(String.self, forKey: .emulator)
        isPinned = try c.decode(Bool.self, forKey: .isPinned)
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        mtime = try c.decodeIfPresent(Int.self, forKey: .mtime) ?? 0
    }
}

public struct SystemInventory: Equatable, Sendable, Codable {
    public let name: String
    public let defaultEmulator: String?
    /// Emulator ids configured for this system.
    public let emulators: [String]
    public let games: [InstalledGame]

    public var gamesByEmulator: [String: [InstalledGame]] {
        Dictionary(grouping: games) { $0.emulator ?? "(none)" }
    }
}

public struct MachineInventory: Equatable, Sendable, Codable {
    public let systems: [SystemInventory]
    public var totalGames: Int { systems.reduce(0) { $0 + $1.games.count } }
}

public enum InventoryParser {
    /// Systems whose games are ROM zips.
    static let zipSystems: Set<String> = ["mame-libretro", "arcade", "mame-advmame", "mame-mame4all", "fba", "neogeo"]
    /// Extensions that are never games (config, saves, art, notes).
    static let nonGameExtensions: Set<String> = ["cfg", "txt", "png", "jpg", "jpeg", "db", "xml", "ini", "srm", "sav", "nv", "hi", "bak", "log", "mng", "mp4", "avi"]

    /// (name, file) if the directory entry is a game for this system, else nil.
    static func game(system: String, kind: Character, entry: String) -> (name: String, file: String)? {
        guard !entry.hasPrefix(".") else { return nil }
        let ext = (entry as NSString).pathExtension.lowercased()
        let base = (entry as NSString).deletingPathExtension
        if system == "daphne" { return kind == "d" && ext == "daphne" ? (base, entry) : nil }
        guard kind == "f", !base.isEmpty else { return nil }
        if zipSystems.contains(system) { return ext == "zip" ? (base, entry) : nil }
        if nonGameExtensions.contains(ext) || ext.hasPrefix("state") { return nil }
        return (base, entry)
    }

    /// Parses the output of `InventoryReader.command`: `@@SYSTEM <s>` blocks of `<f|d> <name>` lines, each followed by
    /// `@@CFG <s>` and that system's emulators.cfg, then `@@PINS` and `all/emulators.cfg`.
    public static func parse(_ output: String) -> MachineInventory {
        var entries: [String: [(Character, String)]] = [:]
        var configs: [String: String] = [:]
        var pins = ""
        var mode = "", current = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@SYSTEM ") { mode = "S"; current = String(line.dropFirst(9)); entries[current] = []; continue }
            if line.hasPrefix("@@CFG ") { mode = "C"; current = String(line.dropFirst(6)); configs[current] = ""; continue }
            if line == "@@PINS" { mode = "P"; continue }
            switch mode {
            case "S": if line.count > 2, let kind = line.first { entries[current, default: []].append((kind, String(line.dropFirst(2)))) }
            case "C": configs[current, default: ""] += line + "\n"
            case "P": pins += line + "\n"
            default: break
            }
        }
        let pinConfig = EmulatorsConfig.parse(pins)
        var systems: [SystemInventory] = []
        for system in entries.keys.sorted() {
            let cfg = EmulatorsConfig.parse(configs[system] ?? "")
            let games: [InstalledGame] = (entries[system] ?? []).compactMap { kind, entry in
                guard let g = game(system: system, kind: kind, entry: entry) else { return nil }
                let pin = pinConfig.entries["\(system)_\(g.name)"]
                return InstalledGame(system: system, name: g.name, file: g.file,
                                     emulator: pin ?? cfg.defaultEmulator, isPinned: pin != nil)
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            if !games.isEmpty {
                systems.append(SystemInventory(name: system, defaultEmulator: cfg.defaultEmulator, emulators: cfg.emulatorIDs, games: games))
            }
        }
        return MachineInventory(systems: systems)
    }
}

/// Reads a machine's inventory with one SSH round trip.
public struct InventoryReader: Sendable {
    private let shell: RemoteShell
    private let machine: Machine

    public init(shell: RemoteShell, machine: Machine) { self.shell = shell; self.machine = machine }

    static func command(romsPath: String) -> String {
        "roms=\(ShellQuote.quote(romsPath)); for d in \"$roms\"/*/; do s=$(basename \"$d\"); "
        + "echo \"@@SYSTEM $s\"; find \"$d\" -maxdepth 1 -mindepth 1 -printf '%y %f\\n'; "
        + "echo \"@@CFG $s\"; cat \"/opt/retropie/configs/$s/emulators.cfg\" 2>/dev/null; done; "
        + "echo \"@@PINS\"; cat /opt/retropie/configs/all/emulators.cfg 2>/dev/null"
    }

    public func read() async throws -> MachineInventory {
        let result = try await shell.run(Self.command(romsPath: machine.romsPath))
        return InventoryParser.parse(result.stdout)
    }
}
