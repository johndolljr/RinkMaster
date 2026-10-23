import Foundation

public struct ArtFile: Equatable, Sendable {
    public let type: String
    public let url: URL
}

/// The NAS master collection: ROM sets by MAME version, hand-picked extras, and the single best copy of each artwork type.
public struct MasterLibrary: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// Art types that are copied to cabinets (cabinet photos are only for the app).
    static let cabinetArtTypes = ["snap", "video", "wheel", "marquee", "flyer", "title"]

    /// The MAME version whose ROM sets a libretro core expects.
    private static let setVersion: [String: String] = [
        "lr-mame2000": "0.037", "lr-mame2003": "0.078", "lr-mame2003-plus": "0.078", "lr-mame2010": "0.139",
        "lr-mame2014": "0.159", "lr-mame2015": "0.161", "lr-mame2016": "0.172",
    ]

    public var isAvailable: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("roms").path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Extras first (they were chosen on purpose), then the newest set that has the game.
    /// With an emulator, the set version that core expects wins when it has the game, else the nearest version that does.
    public func locate(romSet: String, emulator: String? = nil) -> URL? {
        let fm = FileManager.default
        let file = romSet + ".zip"
        let sets = root.appendingPathComponent("roms/sets")
        if let emulator, let version = Self.setVersion[emulator] {
            let candidate = sets.appendingPathComponent(version).appendingPathComponent(file)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let extras = root.appendingPathComponent("roms/extras")
        let direct = extras.appendingPathComponent(file)
        if fm.fileExists(atPath: direct.path) { return direct }
        for dir in sortedSubdirectories(extras) {
            let candidate = dir.appendingPathComponent(file)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        var ordered = Array(sortedSubdirectories(sets).reversed())  // newest first
        if let emulator, let wanted = Self.setVersion[emulator].flatMap(Double.init) {
            // a core wants its own ROM version; when the set lacks the game, the nearest version is the best bet
            ordered.sort { abs((Double($0.lastPathComponent) ?? 0) - wanted) < abs((Double($1.lastPathComponent) ?? 0) - wanted) }
        }
        for dir in ordered {
            let candidate = dir.appendingPathComponent(file)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func artFiles(for game: String) -> [ArtFile] {
        let fm = FileManager.default
        return Self.cabinetArtTypes.compactMap { type in
            let dir = root.appendingPathComponent("artwork/best/\(type)")
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            guard let name = names.sorted().first(where: { ($0 as NSString).deletingPathExtension == game }) else { return nil }
            return ArtFile(type: type, url: dir.appendingPathComponent(name))
        }
    }

    /// Every ROM set name in the sets and extras folders, once, sorted.
    public func allRomSetNames() -> [String] {
        let fm = FileManager.default
        var names = Set<String>()
        func collect(_ dir: URL) {
            for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where file.hasSuffix(".zip") {
                names.insert(String(file.dropLast(4)))
            }
        }
        let extras = root.appendingPathComponent("roms/extras")
        collect(extras)
        sortedSubdirectories(extras).forEach(collect)
        sortedSubdirectories(root.appendingPathComponent("roms/sets")).forEach(collect)
        return names.sorted()
    }

    public func otherSystemURL(sourcePath: String) -> URL? {
        guard sourcePath.hasPrefix("roms/other-systems/"), !sourcePath.contains("..") else { return nil }
        let url = root.appendingPathComponent(sourcePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Names that are never games, wherever they sit under `roms/other-systems` (compared case-insensitively).
    private static let nonGameNames: Set<String> = ["bios", "emulationstation"]

    /// Every file or folder under `roms/other-systems/<system>/` as a game of that system (name = entry name without its extension;
    /// the full entry is what gets copied). BIOS and emulationstation entries, hidden/AppleDouble files and daphne's `roms` folder are skipped.
    /// Sorted by system, then name. Only lists folders; reads no file contents.
    public func otherSystemGames() -> [GameInfo] {
        let fm = FileManager.default
        func entries(_ dir: URL) -> [(name: String, isDirectory: Bool)] {
            let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            return urls.map { (name: $0.lastPathComponent, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
                .filter { !$0.name.hasPrefix(".") && !Self.nonGameNames.contains($0.name.lowercased()) }
                .sorted { $0.name.compare($1.name, options: [.caseInsensitive, .numeric]) == .orderedAscending }
        }
        var games: [GameInfo] = []
        let base = "roms/other-systems"
        for system in entries(root.appendingPathComponent(base)) where system.isDirectory {
            let gamelist = Gamelist.load(from: root.appendingPathComponent("\(base)/\(system.name)/gamelist.xml"))
            let art = otherArtIndex(system: system.name)
            for entry in entries(root.appendingPathComponent("\(base)/\(system.name)")) {
                if Self.otherArtTypes.contains(entry.name.lowercased()) { continue }  // artwork folders, not games
                if system.name == "daphne" && entry.isDirectory == false { /* daphne games are folders; stray files are not games */ continue }
                if system.name == "daphne" && entry.name.lowercased() == "roms" { continue }
                if !entry.isDirectory, InventoryParser.nonGameExtensions.contains((entry.name as NSString).pathExtension.lowercased()) { continue }  // gamelist.xml, notes, saves
                let stem = (entry.name as NSString).deletingPathExtension
                guard !stem.isEmpty else { continue }
                let meta = gamelist[stem]
                games.append(GameInfo(name: stem, title: (meta?.name.isEmpty ?? true) ? stem : meta!.name, year: meta?.year ?? "", manufacturer: meta?.maker ?? "",
                                      cloneOf: nil, artTypes: Self.otherArtTypes.filter { art[$0]?.contains(stem) == true }, hasHistory: !(meta?.desc.isEmpty ?? true),
                                      romSets: [], system: system.name, sourcePath: "\(base)/\(system.name)/\(entry.name)"))
            }
        }
        return games.sorted { a, b in a.system != b.system ? a.system < b.system : a.name.compare(b.name, options: [.caseInsensitive, .numeric]) == .orderedAscending }
    }

    /// Artwork folders inside `roms/other-systems/<system>/`, named like the folders on a cabinet except boxart (a cabinet's `flyer`)
    /// and cartart (app only).
    public static let otherArtTypes = ["boxart", "cartart", "snap", "wheel", "marquee", "flyer"]

    /// For one non-MAME system: art type -> the ROM names (no extension) that have it. Folder listings only.
    public func otherArtIndex(system: String) -> [String: Set<String>] {
        let fm = FileManager.default
        var index: [String: Set<String>] = [:]
        for type in Self.otherArtTypes {
            let dir = root.appendingPathComponent("roms/other-systems/\(system)/\(type)")
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if !names.isEmpty { index[type] = Set(names.filter { !$0.hasPrefix(".") }.map { ($0 as NSString).deletingPathExtension }) }
        }
        return index
    }

    /// A non-MAME game's artwork file of one type, e.g. `roms/other-systems/snes/boxart/ActRaiser (USA).png`.
    public func otherArtURL(game: GameInfo, type: String) -> URL? { game.isMame ? nil : otherArtURL(system: game.system, name: game.name, type: type) }

    public func otherArtURL(system: String, name: String, type: String) -> URL? {
        guard Self.otherArtTypes.contains(type), !system.contains("/"), !name.contains("/") else { return nil }
        let dir = root.appendingPathComponent("roms/other-systems/\(system)/\(type)")
        for ext in ["png", "jpg", "jpeg", "PNG", "JPG", "mp4", "gif"] {
            let candidate = dir.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The artwork that gets copied to a cabinet for a non-MAME game: flyer (else boxart), snap, wheel, marquee. Cart art is app-only.
    public func otherArtFiles(for game: GameInfo) -> [ArtFile] { game.isMame ? [] : otherArtFiles(system: game.system, name: game.name) }

    public func otherArtFiles(system: String, name: String) -> [ArtFile] {
        var out: [ArtFile] = []
        for type in ["flyer", "boxart", "snap", "wheel", "marquee"] {
            if Self.cabinetArtFolder(forMasterType: type) == "flyer", out.contains(where: { Self.cabinetArtFolder(forMasterType: $0.type) == "flyer" }) { continue }
            if let url = otherArtURL(system: system, name: name, type: type) { out.append(ArtFile(type: type, url: url)) }
        }
        return out
    }

    /// The scraped description and details of a non-MAME game, if its system has a `gamelist.xml`.
    public func gamelistEntry(for game: GameInfo) -> GamelistEntry? { game.isMame ? nil : gamelistEntry(system: game.system, name: game.name) }

    public func gamelistEntry(system: String, name: String) -> GamelistEntry? {
        guard !system.contains("/") else { return nil }
        return Gamelist.load(from: root.appendingPathComponent("roms/other-systems/\(system)/gamelist.xml"))[name]
    }

    /// game -> art types available in the master (including cabinet photos, which are only for the app).
    public func artIndex() -> [String: Set<String>] {
        let fm = FileManager.default
        var index: [String: Set<String>] = [:]
        for type in Self.cabinetArtTypes + ["cabinet"] {
            for file in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("artwork/best/\(type)").path)) ?? [] {
                index[(file as NSString).deletingPathExtension, default: []].insert(type)
            }
        }
        return index
    }

    public func artURL(type: String, game: String) -> URL? {
        let dir = root.appendingPathComponent("artwork/best/\(type)")
        // Probing the usual names is far cheaper than listing a folder of tens of thousands of files over the network.
        for ext in ["png", "jpg", "jpeg", "mp4", "gif"] {
            let candidate = dir.appendingPathComponent("\(game).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        guard let file = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            .first(where: { ($0 as NSString).deletingPathExtension == game }) else { return nil }
        return dir.appendingPathComponent(file)
    }

    /// Cabinets keep video snaps beside the still snaps.
    public static func cabinetArtFolder(forMasterType type: String) -> String { type == "video" ? "snap" : (type == "boxart" ? "flyer" : type) }

    private func sortedSubdirectories(_ dir: URL) -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        return names.map { dir.appendingPathComponent($0) }.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
