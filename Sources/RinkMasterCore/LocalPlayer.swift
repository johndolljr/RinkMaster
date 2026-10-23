import Foundation

/// How to start a game on this Mac: which program, with what arguments and environment.
public struct DiscExtraction: Equatable, Sendable {
    public let archive: URL
    public let folder: URL
    public let system: String
}

public struct LaunchPlan: Equatable, @unchecked Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    /// What is being run, for the status line: "MAME 0.172" or "RetroArch · stella".
    public let emulator: String
    /// A folder to mirror into a local working folder before launching (laser disc games).
    let mirror: (source: URL, work: URL)?
    /// A compressed disc image to unpack before launching; the argument `{DISC}` is replaced by the image found inside.
    public let extraction: DiscExtraction?

    init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, emulator: String,
         mirror: (source: URL, work: URL)? = nil, extraction: DiscExtraction? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.workingDirectory = workingDirectory; self.emulator = emulator; self.mirror = mirror; self.extraction = extraction
    }

    public static func == (a: LaunchPlan, b: LaunchPlan) -> Bool {
        a.executable == b.executable && a.arguments == b.arguments && a.environment == b.environment
            && a.workingDirectory == b.workingDirectory && a.emulator == b.emulator
    }
}

public enum LocalPlayError: Error, Equatable, LocalizedError {
    case masterUnavailable
    case missingRoms(String)
    case noEmulator(String)
    case missingSDL
    case missingRetroArch
    case missingCore(String)
    case unsupportedSystem(String)
    case missingHypseus
    case missingEmulator(String)
    case missingBIOS(system: String, folder: String, masterFolder: String)
    case extractionFailed(String)
    case noDiscImage(String)

    public var errorDescription: String? {
        switch self {
        case .masterUnavailable: return "The master collection is not reachable."
        case .missingRoms(let name): return "The master has no ROM set for \(name)."
        case .noEmulator(let why): return "No MAME build in the master: \(why)"
        case .missingSDL: return "SDL2.framework is missing from the RinkMaster emulators folder."
        case .missingRetroArch: return "RetroArch is not installed in Applications."
        case .missingCore(let core): return "The \(core) RetroArch core is not installed."
        case .unsupportedSystem(let system): return "There is no emulator for \(system) on this Mac yet."
        case .missingHypseus: return "Hypseus Singe is missing from the RinkMaster emulators folder."
        case .missingEmulator(let name): return "\(name) is missing from the RinkMaster emulators folder."
        case .missingBIOS(let system, let folder, let masterFolder): return "\(system) needs a BIOS file. Put your own dump in \(folder) (or in the master's \(masterFolder) folder) and try again."
        case .extractionFailed(let why): return "Could not unpack the disc image: \(why)"
        case .noDiscImage(let name): return "No disc image (cue, iso, chd, ...) found inside \(name)."
        }
    }
}

/// Plans running a master game on this Mac with the emulator version that matches its ROM set: the master's own MAME builds
/// (the ROM sets are version specific) and RetroArch with the cores the cabinets use. Nothing is copied; ROMs play from the NAS.
public struct LocalPlayer: Sendable {
    public let master: MasterLibrary
    /// `~/Library/Application Support/RinkMaster`: holds `emulators/SDL2.framework` and the per-game MAME state.
    public let supportDirectory: URL
    public let retroArchApp: URL
    public let coresDirectory: URL
    /// RetroArch's `config` folder, where per-core option files live.
    public let retroArchConfigDirectory: URL?

    public init(master: MasterLibrary, supportDirectory: URL, retroArchApp: URL = URL(fileURLWithPath: "/Applications/RetroArch.app"), coresDirectory: URL,
                retroArchConfigDirectory: URL? = nil) {
        self.master = master; self.supportDirectory = supportDirectory; self.retroArchApp = retroArchApp; self.coresDirectory = coresDirectory
        self.retroArchConfigDirectory = retroArchConfigDirectory
    }

    /// N64: the GPU renderers do not draw on this Mac (a black screen with sound), so the software renderer (Angrylion) is used.
    static let n64CoreOptions = ["mupen64plus-rdp-plugin": "angrylion", "mupen64plus-ThreadedRenderer": "False"]

    /// C64: disk loading runs in warp speed (a game takes about 10 s to load instead of over a minute).
    static let c64CoreOptions = ["vice_autoloadwarp": "enabled"]

    /// Adds the given `key = "value"` options to an option file's text, replacing a key that is already there and keeping the rest.
    static func merged(options: [String: String], into text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for (key, value) in options.sorted(by: { $0.key < $1.key }) {
            let line = "\(key) = \"\(value)\""
            if let i = lines.firstIndex(where: { $0.hasPrefix(key + " =") }) { lines[i] = line } else { lines.append(line) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The MAME build version used for sets outside the versioned folders (e.g. extras): MAME 0.181 is the earliest build with plugin and hiscore support.
    static let extrasVersion = 181

    /// Besides staying unpaused and windowed: for systems that only read a digital pad (SNES, Atari 2600) the left stick drives the D-pad,
    /// since an analog stick left as an analog stick steers nothing. The N64 has a real analog stick, so it keeps it.
    static func retroArchSettings(system: String) -> String {
        let base = "pause_nonactive = \"false\"\nvideo_fullscreen = \"false\"\nconfig_save_on_exit = \"false\"\n"
        return system == "n64" ? base : base + (1...4).map { "input_player\($0)_analog_dpad_mode = \"1\"\n" }.joined()
    }
    func retroArchOverrides(system: String) -> URL { supportDirectory.appendingPathComponent("retroarch-\(system).cfg") }

    /// RetroPie system → the libretro core the cabinets use for it.
    static let cores = ["snes": "snes9x", "atari2600": "stella", "n64": "mupen64plus_next", "c64": "vice_x64sc"]

    public func isSupported(_ game: GameInfo) -> Bool { game.isMame || game.system == "daphne" || Self.discSystems.contains(game.system) || Self.cores[game.system] != nil }

    public func plan(for game: GameInfo) throws -> LaunchPlan {
        guard master.isAvailable else { throw LocalPlayError.masterUnavailable }
        if game.isMame { return try mamePlan(game) }
        if game.system == "daphne" { return try daphnePlan(game) }
        return Self.discSystems.contains(game.system) ? try discPlan(game) : try retroArchPlan(game)
    }

    var emulatorsDirectory: URL { supportDirectory.appendingPathComponent("emulators") }
    private var sdlFolder: URL { emulatorsDirectory }

    // MARK: MAME

    /// The master's MAME builds, `mame0172` → 172, oldest first.
    func mameBuilds() -> [(version: Int, binary: URL)] {
        let dir = master.root.appendingPathComponent("emulators")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> (Int, URL)? in
            guard name.hasPrefix("mame"), let version = Int(name.dropFirst(4)) else { return nil }
            let binary = dir.appendingPathComponent(name).appendingPathComponent("mame64")
            return FileManager.default.isExecutableFile(atPath: binary.path) ? (version, binary) : nil
        }.sorted { $0.0 < $1.0 }
    }

    /// The build whose version is nearest the ROM set's (the newer one on a tie).
    static func nearestBuild(to version: Int, in builds: [(version: Int, binary: URL)]) -> (version: Int, binary: URL)? {
        builds.min { a, b in
            let da = abs(a.version - version), db = abs(b.version - version)
            return da != db ? da < db : a.version > b.version
        }
    }

    private func mamePlan(_ game: GameInfo) throws -> LaunchPlan {
        guard FileManager.default.fileExists(atPath: sdlFolder.appendingPathComponent("SDL2.framework").path) else { throw LocalPlayError.missingSDL }
        var folders: [URL] = []
        var versions: [Int] = []
        for set in Set(game.romSets + [game.name]).sorted() {
            guard let zip = master.locate(romSet: set) else {
                if set == game.name { throw LocalPlayError.missingRoms(game.name) }
                continue  // a device or BIOS set the master may not need to hold
            }
            let folder = zip.deletingLastPathComponent()
            if !folders.contains(folder) { folders.append(folder) }
            if set == game.name, let v = Double(folder.lastPathComponent) { versions.append(Int((v * 1000).rounded())) }
        }
        let builds = mameBuilds()
        guard !builds.isEmpty else { throw LocalPlayError.noEmulator("emulators/mameNNNN/mame64 not found") }
        let wanted = versions.first ?? Self.extrasVersion   // hand-picked extras have no version: use the cabinets' own
        guard let build = Self.nearestBuild(to: wanted, in: builds) else { throw LocalPlayError.noEmulator("none usable") }
        let state = supportDirectory.appendingPathComponent("mame/\(build.version)")
        var args = ["-rompath", folders.map(\.path).joined(separator: ";"),
                    "-cfg_directory", state.appendingPathComponent("cfg").path, "-nvram_directory", state.appendingPathComponent("nvram").path,
                    "-state_directory", state.appendingPathComponent("sta").path, "-snapshot_directory", state.appendingPathComponent("snap").path,
                    "-diff_directory", state.appendingPathComponent("diff").path, "-comment_directory", state.appendingPathComponent("comments").path,
                    "-inipath", state.appendingPathComponent("ini").path]
        if build.version >= 181 {
            let pluginsDir = supportDirectory.appendingPathComponent("mame/plugins")
            args.append(contentsOf: ["-plugins", "-plugin", "hiscore", "-pluginspath", pluginsDir.path])
        }
        args.append(contentsOf: ["-window", "-nomaximize", "-resolution", "1280x960", "-joystick", game.name])
        return LaunchPlan(executable: build.binary.path, arguments: args, // SDL drops controller input while the window is not focused, and a game started from the app opens unfocused
                          environment: ["DYLD_FRAMEWORK_PATH": sdlFolder.path, "SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS": "1"],
                          workingDirectory: state.path, emulator: "MAME 0.\(build.version)")
    }

    // MARK: Laser disc (Hypseus Singe)

    private var hypseusFolder: URL { emulatorsDirectory.appendingPathComponent("hypseus") }
    /// The laser disc game's folder is mirrored here (links to the master's video and audio, a private copy of the small index files),
    /// because Hypseus rewrites an index it finds out of date and the master must not be written to.
    private func daphneWorkFolder(_ name: String) -> URL { supportDirectory.appendingPathComponent("daphne/\(name).daphne") }

    private func daphnePlan(_ game: GameInfo) throws -> LaunchPlan {
        let binary = hypseusFolder.appendingPathComponent("hypseus")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw LocalPlayError.missingHypseus }
        guard let source = game.sourcePath.flatMap({ master.otherSystemURL(sourcePath: $0) }) else { throw LocalPlayError.missingRoms(game.name) }
        let name = source.deletingPathExtension().lastPathComponent
        let work = daphneWorkFolder(name)
        let args = [name, "vldp", "-framefile", work.appendingPathComponent("\(name).txt").path, "-homedir", hypseusFolder.path,
                    "-romdir", master.root.appendingPathComponent("roms/other-systems/daphne/roms").path, "-x", "1280", "-y", "720"]
        return LaunchPlan(executable: binary.path, arguments: args, environment: [:], workingDirectory: hypseusFolder.path, emulator: "Hypseus Singe",
                          mirror: (source, work))
    }

    /// Links everything in `source` into `work`, except `.dat` index files, which are copied.
    static func mirror(_ source: URL, to work: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] where !name.hasPrefix(".") {
            let from = source.appendingPathComponent(name), to = work.appendingPathComponent(name)
            if (try? to.checkResourceIsReachable()) == true || (try? fm.destinationOfSymbolicLink(atPath: to.path)) != nil { continue }
            if name.hasSuffix(".dat") || name.hasSuffix(".txt") { try? fm.copyItem(at: from, to: to) } else { try? fm.createSymbolicLink(at: to, withDestinationURL: from) }
        }
    }

    // MARK: RetroArch

    private func retroArchPlan(_ game: GameInfo) throws -> LaunchPlan {
        guard let core = Self.cores[game.system] else { throw LocalPlayError.unsupportedSystem(game.system) }
        let binary = retroArchApp.appendingPathComponent("Contents/MacOS/RetroArch")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw LocalPlayError.missingRetroArch }
        let dylib = coresDirectory.appendingPathComponent("\(core)_libretro.dylib")
        guard FileManager.default.fileExists(atPath: dylib.path) else { throw LocalPlayError.missingCore(core) }
        guard let rom = game.sourcePath.flatMap({ master.otherSystemURL(sourcePath: $0) }) else { throw LocalPlayError.missingRoms(game.name) }
        // RetroArch pauses the game (no sound, no input) whenever its window is not the active one, and a game started from the app
        // opens behind it; the appended config keeps it running and windowed whatever has focus
        return LaunchPlan(executable: binary.path, arguments: ["--appendconfig", retroArchOverrides(system: game.system).path, "-L", dylib.path, rom.path], environment: [:],
                          workingDirectory: supportDirectory.path, emulator: "RetroArch · \(core)")
    }

    /// True when MAME's own `-listxml` output marks the game's driver as not working (`status="preliminary"`): such a game loads but
    /// misbehaves (reboots, hangs), and MAME says so on its warning screen.
    public static func isNotWorking(listxml: String) -> Bool {
        guard let range = listxml.range(of: "<driver ") else { return false }
        let tag = listxml[range.lowerBound...].prefix { $0 != ">" }
        return tag.contains("status=\"preliminary\"")
    }

    /// The program and environment that print the XML description of one MAME game (so the app can warn before a game that cannot work).
    public func listxmlCommand(for plan: LaunchPlan, game: GameInfo) -> (executable: String, arguments: [String])? {
        game.isMame && plan.arguments.last == game.name ? (plan.executable, ["-listxml", game.name]) : nil
    }

    /// Creates the folders MAME writes its settings and saves to.
    public func prepare(_ plan: LaunchPlan) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: plan.workingDirectory, withIntermediateDirectories: true)
        if let mirror = plan.mirror { Self.mirror(mirror.source, to: mirror.work) }
        if let config = retroArchConfigDirectory {
            for (suffix, folder, options) in [("mupen64plus_next", "Mupen64Plus-Next", Self.n64CoreOptions), ("vice_x64sc", "VICE x64sc", Self.c64CoreOptions)]
            where plan.emulator.hasSuffix(suffix) {
                let dir = config.appendingPathComponent(folder)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("\(folder).opt")
                let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                try? Self.merged(options: options, into: existing).write(to: file, atomically: true, encoding: .utf8)
            }
        }
        if plan.emulator.hasPrefix("RetroArch"), let i = plan.arguments.firstIndex(of: "--appendconfig"), i + 1 < plan.arguments.count {
            let url = URL(fileURLWithPath: plan.arguments[i + 1])
            let system = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "retroarch-", with: "")
            try? Self.retroArchSettings(system: system).write(to: url, atomically: true, encoding: .utf8)
        }
        for sub in ["cfg", "nvram", "sta", "snap", "diff", "comments", "ini", "hi"] {
            try? fm.createDirectory(atPath: plan.workingDirectory + "/" + sub, withIntermediateDirectories: true)
        }
        if plan.emulator.hasPrefix("MAME") {
            prepareMamePlugins()
            let iniFile = URL(fileURLWithPath: plan.workingDirectory).appendingPathComponent("ini/hiscore.ini")
            if !fm.fileExists(atPath: iniFile.path) {
                try? "hi_path hi\n".write(to: iniFile, atomically: true, encoding: .utf8)
            } else if let content = try? String(contentsOf: iniFile, encoding: .utf8), content.contains("hi_path   ") {
                try? "hi_path hi\n".write(to: iniFile, atomically: true, encoding: .utf8)
            }
        }
    }

    static let mameBootLua = """
require('lfs')

function lfs.env_replace(str)
\tlocal pathsep = package.config:sub(1,1)
\tlocal function dorep(val)
\t\tret = os.getenv(val)
\t\tif ret then return ret end
\t\treturn val
\tend
\tif pathsep == '\\\\' then
\t\tstr = str:gsub("%%(%w+)%%", dorep)
\telse
\t\tstr = str:gsub("%$(%w+)", dorep)
\tend
\treturn str
end

local dir = lfs.env_replace(manager:options().entries.pluginspath:value())
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua"
local json = require('json')

local function readAll(file)
\tlocal f = io.open(file, "rb")
\tif not f then return nil end
\tlocal content = f:read("*all")
\tf:close()
\treturn content
end

local plugins_obj = nil
if type(mame_manager) == "userdata" and mame_manager.plugins then
\tplugins_obj = mame_manager:plugins()
elseif type(manager) == "userdata" and manager.plugins then
\tplugins_obj = manager:plugins()
end

for file in lfs.dir(dir) do
\tif (file~="." and file~=".." and lfs.attributes(dir .. "/" .. file,"mode")=="directory") then
\t\tlocal filename = dir .. "/" .. file .. "/plugin.json"
\t\tlocal raw = readAll(filename)
\t\tif raw then
\t\t\tlocal meta = json.parse(raw)
\t\t\tif meta and meta["plugin"] and meta["plugin"]["type"]=="plugin" then
\t\t\t\tlocal name = meta["plugin"]["name"]
\t\t\t\tlocal entry = plugins_obj and plugins_obj.entries and plugins_obj.entries[name]
\t\t\t\tif (entry and entry:value() == true) or (name == "hiscore") then
\t\t\t\t\tlocal ok, plugin = pcall(require, name)
\t\t\t\t\tif ok and plugin then
\t\t\t\t\t\tif plugin.set_folder then plugin.set_folder(dir .. "/" .. file) end
\t\t\t\t\t\tif plugin.startplugin then plugin.startplugin() end
\t\t\t\t\tend
\t\t\t\tend
\t\t\tend
\t\tend
\tend
end
"""

    /// Sets up the MAME Lua plugins directory so hiscore saving works out of the box.
    public func prepareMamePlugins() {
        let fm = FileManager.default
        let pluginsDir = supportDirectory.appendingPathComponent("mame/plugins")
        let hiscoreDir = pluginsDir.appendingPathComponent("hiscore")
        let jsonDir = pluginsDir.appendingPathComponent("json")
        try? fm.createDirectory(at: hiscoreDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: jsonDir, withIntermediateDirectories: true)

        let bootLua = pluginsDir.appendingPathComponent("boot.lua")
        try? Self.mameBootLua.write(to: bootLua, atomically: true, encoding: .utf8)

        let masterHiscoreCandidates = [
            master.root.appendingPathComponent("emulators/mame0181/plugins/hiscore"),
            master.root.appendingPathComponent("roms/other-systems/BIOS/mame/plugins/hiscore")
        ]
        for candidate in masterHiscoreCandidates where fm.fileExists(atPath: candidate.path) {
            for file in ["init.lua", "plugin.json", "hiscore.dat"] {
                let src = candidate.appendingPathComponent(file)
                let dst = hiscoreDir.appendingPathComponent(file)
                if !fm.fileExists(atPath: dst.path) && fm.fileExists(atPath: src.path) {
                    try? fm.copyItem(at: src, to: dst)
                }
            }
            break
        }

        let hiscoreDat = hiscoreDir.appendingPathComponent("hiscore.dat")
        if !fm.fileExists(atPath: hiscoreDat.path) {
            for datPath in ["emulators/mame0161/hiscore.dat", "roms/other-systems/BIOS/mame2016/hiscore.dat", "roms/other-systems/BIOS/mame2003/hiscore.dat"] {
                let candidate = master.root.appendingPathComponent(datPath)
                if fm.fileExists(atPath: candidate.path) {
                    try? fm.copyItem(at: candidate, to: hiscoreDat)
                    break
                }
            }
        }

        let masterJsonCandidates = [
            master.root.appendingPathComponent("emulators/mame0181/plugins/json"),
            master.root.appendingPathComponent("roms/other-systems/BIOS/mame/plugins/json")
        ]
        for candidate in masterJsonCandidates where fm.fileExists(atPath: candidate.path) {
            for file in ["init.lua", "plugin.json"] {
                let src = candidate.appendingPathComponent(file)
                let dst = jsonDir.appendingPathComponent(file)
                if !fm.fileExists(atPath: dst.path) && fm.fileExists(atPath: src.path) {
                    try? fm.copyItem(at: src, to: dst)
                }
            }
            break
        }

        let initLua = hiscoreDir.appendingPathComponent("init.lua")
        if let content = try? String(contentsOf: initLua, encoding: .utf8) {
            var patched = content
            if patched.contains("emu.print_verbose") {
                patched = patched.replacingOccurrences(of: "(emu.print_verbose or function(...) end)(", with: "emu.print_verbose(")
                patched = patched.replacingOccurrences(of: "emu.print_verbose(", with: "(type(emu.print_verbose) == 'function' and emu.print_verbose or function(...) end)(")
            }
            if patched.contains("emu.print_error") {
                patched = patched.replacingOccurrences(of: "(emu.print_error or print)(", with: "emu.print_error(")
                patched = patched.replacingOccurrences(of: "emu.print_error(", with: "(type(emu.print_error) == 'function' and emu.print_error or print)(")
            }
            if patched.contains("'([^ ]+) ([^ ]+)'") {
                patched = patched.replacingOccurrences(of: "'([^ ]+) ([^ ]+)'", with: "'(%S+)%s+(%S+)'")
            }
            if patched.contains("emu.softname()") {
                patched = patched.replacingOccurrences(of: "emu.softname()", with: "(type(emu.softname) == 'function' and emu.softname() or tostring(emu.softname or ''))")
            }
            if patched.contains("emu.romname()") {
                patched = patched.replacingOccurrences(of: "emu.romname()", with: "(type(emu.romname) == 'function' and emu.romname() or tostring(emu.romname or ''))")
            }
            if patched.contains("emu.gamename()") {
                patched = patched.replacingOccurrences(of: "emu.gamename()", with: "(type(emu.gamename) == 'function' and emu.gamename() or tostring(emu.gamename or ''))")
            }
            if patched != content {
                try? patched.write(to: initLua, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Stages the winning score file for `game` from `scores` (arcade machines) into the plan's working directory.
    /// For `.hi` files: written to `<workingDirectory>/hi/<game.name>.hi` (if no local score exists or if the arcade score is higher).
    /// For `.nv` files: written to `<workingDirectory>/nvram/<game.name>/<game.name>.nv` (if no local NVRAM exists yet).
    /// Returns true if a score was staged.
    @discardableResult
    public func stageHighScore(for game: GameInfo, from scores: UnifiedScores, in plan: LaunchPlan, decoder: ScoreDecoder? = nil) async -> Bool {
        guard game.isMame else { return false }
        let winner = scores.best(for: game.name) ?? scores.entries(for: game.name).filter { $0.data != nil }.max(by: { $0.file.mtime < $1.file.mtime })
        guard let winner, let winnerData = winner.data else { return false }

        let fm = FileManager.default
        let workURL = URL(fileURLWithPath: plan.workingDirectory)

        if winner.file.kind == "hi" {
            let hiDir = workURL.appendingPathComponent("hi")
            try? fm.createDirectory(at: hiDir, withIntermediateDirectories: true)
            let hiFile = hiDir.appendingPathComponent("\(game.name).hi")

            if fm.fileExists(atPath: hiFile.path) {
                guard let localData = try? Data(contentsOf: hiFile), localData != winnerData else {
                    return false
                }
                if let decoder {
                    let localTable = try? await decoder.decode(game: game.name, data: localData)
                    let winnerScore: Int?
                    if let s = winner.topScore {
                        winnerScore = s
                    } else {
                        winnerScore = (try? await decoder.decode(game: game.name, data: winnerData))?.topScore
                    }
                    if let localScore = localTable?.topScore, let winScore = winnerScore, localScore > winScore {
                        return false
                    }
                }
            }
            do {
                try winnerData.write(to: hiFile, options: .atomic)
                return true
            } catch {
                return false
            }
        } else if winner.file.kind == "nv" {
            let nvDir = workURL.appendingPathComponent("nvram/\(game.name)")
            let nvFile = nvDir.appendingPathComponent("\(game.name).nv")
            if !fm.fileExists(atPath: nvDir.path) && !fm.fileExists(atPath: nvFile.path) {
                try? fm.createDirectory(at: nvDir, withIntermediateDirectories: true)
                do {
                    try winnerData.write(to: nvFile, options: .atomic)
                    return true
                } catch {
                    return false
                }
            }
        }
        return false
    }
}
