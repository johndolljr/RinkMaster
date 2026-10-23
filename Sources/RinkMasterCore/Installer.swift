import Foundation

public enum InstallError: Error, Equatable {
    case noEmulatorInstalled(machine: String, system: String)
    case emulatorNotInstalled(machine: String, emulator: String)
    case unknownGame(String)
    case missingRomSet(String)
}

/// What adding a game to a machine would copy and configure.
public struct AddPlan: Equatable, Sendable {
    public let game: String
    public let system: String
    public let emulator: String
    /// True when the chosen emulator is not the system default, so a per-game pin would be written.
    public let pinsEmulator: Bool
    public let romSets: [String]
    public let romFiles: [String]
    public let artFiles: [(type: String, path: String)]

    public static func == (a: AddPlan, b: AddPlan) -> Bool {
        a.game == b.game && a.system == b.system && a.emulator == b.emulator && a.pinsEmulator == b.pinsEmulator && a.romSets == b.romSets
            && a.romFiles == b.romFiles && a.artFiles.map { "\($0.type)|\($0.path)" } == b.artFiles.map { "\($0.type)|\($0.path)" }
    }
}

public struct AddReport: Equatable, Sendable {
    public let game: String
    public let system: String
    public let emulator: String
    public let romSets: [String]
    public let frontendRefreshed: [String]
}

/// Adds games to a cabinet from the master (rsync) and removes them through the cabinet service.
public struct Installer: Sendable {
    public let machine: Machine
    private let shell: RemoteShell
    private let service: ServiceClient
    private let master: MasterLibrary
    private let database: MameDatabase?

    static let globalEmulatorsCfg = "/opt/retropie/configs/all/emulators.cfg"

    public init(machine: Machine, shell: RemoteShell, service: ServiceClient, master: MasterLibrary, database: MameDatabase?) {
        self.machine = machine; self.shell = shell; self.service = service; self.master = master; self.database = database
    }

    /// Everything an add would do, worked out and checked without copying anything: an emulator must be installed for
    /// the system and every needed ROM set must exist in the master. `romSets` (from the catalog) skips the XML lookup.
    public func plan(game: String, system: String, emulator requested: String?, romSets: [String]? = nil, sourcePath: String? = nil) async throws -> AddPlan {
        let emulators = try await service.emulators()
        let installed = emulators.installedEmulators(for: system)
        guard !installed.isEmpty else { throw InstallError.noEmulatorInstalled(machine: machine.name, system: system) }
        if let requested, !installed.contains(requested) {
            throw InstallError.emulatorNotInstalled(machine: machine.name, emulator: requested)
        }
        let emulator = requested ?? emulators.preferredEmulator(for: system) ?? installed[0]

        if let sourcePath {  // a non-MAME game: one file or folder from roms/other-systems, no parents and no artwork
            guard let url = master.otherSystemURL(sourcePath: sourcePath) else { throw InstallError.missingRomSet(sourcePath) }
            return AddPlan(game: game, system: system, emulator: emulator, pinsEmulator: emulator != emulators.preferredEmulator(for: system),
                           romSets: [sourcePath], romFiles: [url.path],
                           artFiles: master.otherArtFiles(system: system, name: game).map { ($0.type, $0.url.path) })
        }
        let sets: [String]
        if let romSets, !romSets.isEmpty { sets = romSets }
        else if let database, let needed = try? database.requiredRomSets(for: game) { sets = needed }
        else { throw InstallError.unknownGame(game) }
        var sources: [URL] = []
        for set in sets {
            guard let url = master.locate(romSet: set, emulator: emulator) else { throw InstallError.missingRomSet(set) }
            sources.append(url)
        }
        return AddPlan(game: game, system: system, emulator: emulator, pinsEmulator: emulator != emulators.preferredEmulator(for: system),
                       romSets: sets, romFiles: sources.map(\.path), artFiles: master.artFiles(for: game).map { ($0.type, $0.url.path) })
    }

    /// `romSets` (from the catalog) skips the XML lookup; without it the database must be given.
    public func add(game: String, system: String, emulator requested: String?, romSets: [String]? = nil, sourcePath: String? = nil) async throws -> AddReport {
        let plan = try await plan(game: game, system: system, emulator: requested, romSets: romSets, sourcePath: sourcePath)
        let sets = plan.romSets, emulator = plan.emulator
        let systemDir = "\(machine.romsPath)/\(system)"
        _ = try await shell.run("mkdir -p \(ShellQuote.quote(systemDir))")
        for file in plan.romFiles {
            _ = try await shell.push(localPath: file, toRemotePath: systemDir + "/")
        }
        for art in plan.artFiles {
            let folder = "\(systemDir)/\(MasterLibrary.cabinetArtFolder(forMasterType: art.type))"
            _ = try await shell.run("mkdir -p \(ShellQuote.quote(folder))")
            _ = try await shell.push(localPath: art.path, toRemotePath: folder + "/")
        }
        if machine.frontend == .emulationStation, sourcePath != nil {
            let entry = gamelistEntry(game: game, system: system, sourcePath: sourcePath!, art: plan.artFiles)
            try await service.upsertGamelist(system: system, games: [entry])
        }
        if plan.pinsEmulator {
            let key = "\(system)_\(game)"
            let line = "\(key) = \"\(emulator)\""
            let cfg = ShellQuote.quote(Self.globalEmulatorsCfg)
            _ = try await shell.run("grep -q \(ShellQuote.quote("^\(key) = ")) \(cfg) || echo \(ShellQuote.quote(line)) >> \(cfg)")
        }
        let refreshed = try await service.refreshFrontend(system: system)
        try await service.refreshInventory()
        return AddReport(game: game, system: system, emulator: emulator, romSets: sets, frontendRefreshed: refreshed.refreshed)
    }

    /// The EmulationStation list entry for a copied game: scraped name and details from the master's gamelist.xml, art as paths
    /// relative to the system's ROM folder (where the art was copied).
    func gamelistEntry(game: String, system: String, sourcePath: String, art: [(type: String, path: String)]) -> [String: String] {
        let meta = master.gamelistEntry(system: system, name: game)
        var entry: [String: String] = ["path": "./" + (sourcePath as NSString).lastPathComponent, "name": (meta?.name.isEmpty ?? true) ? game : meta!.name]
        if let meta {
            if !meta.desc.isEmpty { entry["desc"] = meta.desc }
            if !meta.releaseDate.isEmpty { entry["releasedate"] = meta.releaseDate }
            if !meta.developer.isEmpty { entry["developer"] = meta.developer }
            if !meta.publisher.isEmpty { entry["publisher"] = meta.publisher }
            if !meta.genre.isEmpty { entry["genre"] = meta.genre }
        }
        for a in art {
            let folder = MasterLibrary.cabinetArtFolder(forMasterType: a.type)
            let rel = "./\(folder)/" + (a.path as NSString).lastPathComponent
            switch folder {
            case "flyer": entry["image"] = rel
            case "marquee": entry["marquee"] = rel
            case "wheel": if entry["marquee"] == nil { entry["marquee"] = rel }
            case "snap": if (a.path as NSString).pathExtension.lowercased() != "mp4" { entry["thumbnail"] = rel }  // never <video>: it switches ES to its video view, which crashed
            default: break
            }
        }
        return entry
    }

    /// Removes the machine's copy only; the service never touches the master.
    public func remove(game: String, system: String, options: RemovalOptions, dryRun: Bool) async throws -> RemovalPlan {
        try await service.removeGame(system: system, name: game, options: options, dryRun: dryRun)
    }
}
