import XCTest
@testable import RinkMasterCore

final class LocalPlayerTests: XCTestCase {
    private var base: URL!
    private var root: URL { base.appendingPathComponent("master") }
    private var support: URL { base.appendingPathComponent("support") }
    private var cores: URL { base.appendingPathComponent("cores") }
    private var retroArch: URL { base.appendingPathComponent("RetroArch.app") }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("lp-\(UUID().uuidString)")
        let fm = FileManager.default
        for d in ["master/roms/sets/0.172", "master/roms/sets/0.106", "master/roms/sets/0.198", "master/roms/other-systems/atari2600",
                  "master/emulators/mame0161", "master/emulators/mame0172", "master/emulators/mame0198",
                  "master/emulators/mame0181/plugins/hiscore", "master/emulators/mame0181/plugins/json",
                  "support/emulators/SDL2.framework", "cores", "RetroArch.app/Contents/MacOS"] {
            try fm.createDirectory(at: base.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try Data("dummy hiscore.dat".utf8).write(to: root.appendingPathComponent("emulators/mame0181/plugins/hiscore/hiscore.dat"))
        try Data("-- hiscore init.lua\n".utf8).write(to: root.appendingPathComponent("emulators/mame0181/plugins/hiscore/init.lua"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("emulators/mame0181/plugins/hiscore/plugin.json"))
        try Data("-- json init.lua\n".utf8).write(to: root.appendingPathComponent("emulators/mame0181/plugins/json/init.lua"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("emulators/mame0181/plugins/json/plugin.json"))
        for v in ["0161", "0172", "0198"] { try exec(root.appendingPathComponent("emulators/mame\(v)/mame64")) }
        try exec(retroArch.appendingPathComponent("Contents/MacOS/RetroArch"))
        // a folder that looks like a build but has no binary, and a stray name, are ignored
        try fm.createDirectory(at: root.appendingPathComponent("emulators/mame0210"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("emulators/ClrmamePro"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func exec(_ url: URL) throws {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func player() -> LocalPlayer {
        LocalPlayer(master: MasterLibrary(root: root), supportDirectory: support, retroArchApp: retroArch, coresDirectory: cores,
                    retroArchConfigDirectory: base.appendingPathComponent("raconfig"))
    }

    private func mame(_ name: String, sets: [String]? = nil) -> GameInfo {
        GameInfo(name: name, title: name, year: "1980", manufacturer: "x", cloneOf: nil, artTypes: [], hasHistory: false, romSets: sets ?? [name])
    }

    private func touch(_ path: String) throws { try Data().write(to: root.appendingPathComponent(path)) }

    func testMamePicksTheBuildMatchingTheSetAndPointsAtItsFolder() throws {
        try touch("roms/sets/0.172/pacman.zip")
        let plan = try player().plan(for: mame("pacman"))
        XCTAssertTrue(plan.executable.hasSuffix("mame0172/mame64"))
        XCTAssertEqual(plan.emulator, "MAME 0.172")
        XCTAssertEqual(plan.arguments[0], "-rompath")
        XCTAssertTrue(plan.arguments[1].hasSuffix("roms/sets/0.172"))
        XCTAssertEqual(plan.arguments.last, "pacman")
        XCTAssertTrue(plan.arguments.contains("-joystick"))
        XCTAssertTrue(plan.arguments.contains("-window"))
        XCTAssertEqual(plan.environment["SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"], "1")
        XCTAssertEqual(plan.environment["DYLD_FRAMEWORK_PATH"], support.appendingPathComponent("emulators").path)
    }

    func testOldSetFallsBackToTheNearestBuildAndIncludesParentFolders() throws {
        try touch("roms/sets/0.106/old.zip"); try touch("roms/sets/0.172/neogeo.zip")
        let plan = try player().plan(for: mame("old", sets: ["old", "neogeo", "missingdevice"]))
        XCTAssertEqual(plan.emulator, "MAME 0.161")
        XCTAssertTrue(plan.arguments[1].contains("0.106"))
        XCTAssertTrue(plan.arguments[1].contains("0.172"))
        XCTAssertTrue(plan.arguments[1].contains(";"))
    }

    func testNearestBuildBreaksTiesTowardNewer() {
        let builds = [(version: 100, binary: URL(fileURLWithPath: "/a")), (version: 200, binary: URL(fileURLWithPath: "/b"))]
        XCTAssertEqual(LocalPlayer.nearestBuild(to: 150, in: builds)?.version, 200)
        XCTAssertEqual(LocalPlayer.nearestBuild(to: 120, in: builds)?.version, 100)
        XCTAssertNil(LocalPlayer.nearestBuild(to: 1, in: []))
    }

    func testExtrasSetUsesTheCabinetVersion() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("roms/extras"), withIntermediateDirectories: true)
        try touch("roms/extras/custom.zip")
        XCTAssertEqual(try player().plan(for: mame("custom")).emulator, "MAME 0.172")
    }

    func testMissingRomsSDLAndMasterAreReported() throws {
        XCTAssertThrowsError(try player().plan(for: mame("nothere"))) { XCTAssertEqual($0 as? LocalPlayError, .missingRoms("nothere")) }
        try touch("roms/sets/0.172/pacman.zip")
        try FileManager.default.removeItem(at: support.appendingPathComponent("emulators/SDL2.framework"))
        XCTAssertThrowsError(try player().plan(for: mame("pacman"))) { XCTAssertEqual($0 as? LocalPlayError, .missingSDL) }
        let gone = LocalPlayer(master: MasterLibrary(root: base.appendingPathComponent("nope")), supportDirectory: support, coresDirectory: cores)
        XCTAssertThrowsError(try gone.plan(for: mame("pacman"))) { XCTAssertEqual($0 as? LocalPlayError, .masterUnavailable) }
    }

    func testNoBuildsIsReported() throws {
        try touch("roms/sets/0.172/pacman.zip")
        for v in ["0161", "0172", "0198"] { try FileManager.default.removeItem(at: root.appendingPathComponent("emulators/mame\(v)")) }
        XCTAssertThrowsError(try player().plan(for: mame("pacman"))) { error in
            guard case .noEmulator = error as? LocalPlayError else { return XCTFail("\(error)") }
        }
    }

    private var adventure: GameInfo {
        GameInfo(name: "Adventure", title: "Adventure", year: "", manufacturer: "", cloneOf: nil, artTypes: [], hasHistory: false, romSets: [],
                 system: "atari2600", sourcePath: "roms/other-systems/atari2600/Adventure.bin")
    }

    func testRetroArchGameNeedsItsCoreAndRom() throws {
        try touch("roms/other-systems/atari2600/Adventure.bin")
        XCTAssertTrue(player().isSupported(adventure))
        XCTAssertThrowsError(try player().plan(for: adventure)) { XCTAssertEqual($0 as? LocalPlayError, .missingCore("stella")) }
        try Data().write(to: cores.appendingPathComponent("stella_libretro.dylib"))
        let plan = try player().plan(for: adventure)
        XCTAssertEqual(plan.arguments[0], "--appendconfig")
        XCTAssertTrue(plan.arguments[1].hasSuffix("retroarch-atari2600.cfg"))
        XCTAssertEqual(plan.arguments[2], "-L")
        XCTAssertTrue(plan.arguments[3].hasSuffix("stella_libretro.dylib"))
        XCTAssertTrue(plan.arguments[4].hasSuffix("Adventure.bin"))
        player().prepare(plan)
        XCTAssertTrue(try String(contentsOf: support.appendingPathComponent("retroarch-atari2600.cfg"), encoding: .utf8).contains("pause_nonactive = \"false\""))
        XCTAssertTrue(LocalPlayer.retroArchSettings(system: "snes").contains("input_player1_analog_dpad_mode = \"1\""))
        XCTAssertFalse(LocalPlayer.retroArchSettings(system: "n64").contains("analog_dpad_mode"))
        XCTAssertEqual(plan.emulator, "RetroArch · stella")
        try FileManager.default.removeItem(at: root.appendingPathComponent("roms/other-systems/atari2600/Adventure.bin"))
        XCTAssertThrowsError(try player().plan(for: adventure)) { XCTAssertEqual($0 as? LocalPlayError, .missingRoms("Adventure")) }
    }

    func testN64UsesMupenNextAndKeepsTheAnalogStick() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("roms/other-systems/n64"), withIntermediateDirectories: true)
        try touch("roms/other-systems/n64/Mario Kart 64 (USA).n64")
        try Data().write(to: cores.appendingPathComponent("mupen64plus_next_libretro.dylib"))
        let game = GameInfo(name: "Mario Kart 64 (USA)", title: "Mario Kart 64", year: "", manufacturer: "", cloneOf: nil, artTypes: [], hasHistory: false, romSets: [],
                            system: "n64", sourcePath: "roms/other-systems/n64/Mario Kart 64 (USA).n64")
        let p = player(), plan = try p.plan(for: game)
        XCTAssertTrue(plan.arguments.contains { $0.hasSuffix("mupen64plus_next_libretro.dylib") })
        p.prepare(plan)
        let cfg = try String(contentsOf: support.appendingPathComponent("retroarch-n64.cfg"), encoding: .utf8)
        XCTAssertTrue(cfg.contains("pause_nonactive"))
        XCTAssertFalse(cfg.contains("analog_dpad_mode"))
        // the core's option file gets the software renderer; other options already there are kept
        let opt = base.appendingPathComponent("raconfig/Mupen64Plus-Next/Mupen64Plus-Next.opt")
        try "mupen64plus-rdp-plugin = \"gliden64\"\nmupen64plus-43screensize = \"640x480\"\n".write(to: opt, atomically: true, encoding: .utf8)
        p.prepare(plan)
        let text = try String(contentsOf: opt, encoding: .utf8)
        XCTAssertTrue(text.contains("mupen64plus-rdp-plugin = \"angrylion\""))
        XCTAssertFalse(text.contains("gliden64"))
        XCTAssertTrue(text.contains("mupen64plus-43screensize = \"640x480\""))
        XCTAssertTrue(text.contains("mupen64plus-ThreadedRenderer = \"False\""))
    }

    func testMergedOptionsAddsAndReplaces() {
        XCTAssertEqual(LocalPlayer.merged(options: ["a": "1", "b": "2"], into: ""), "a = \"1\"\nb = \"2\"\n")
        XCTAssertEqual(LocalPlayer.merged(options: ["a": "9"], into: "a = \"1\"\nc = \"3\"\n"), "a = \"9\"\nc = \"3\"\n")
    }

    func testMissingRetroArchIsReported() throws {
        try FileManager.default.removeItem(at: retroArch)
        XCTAssertThrowsError(try player().plan(for: adventure)) { XCTAssertEqual($0 as? LocalPlayError, .missingRetroArch) }
    }

    func testUnsupportedSystemAndMessages() throws {
        let n64 = GameInfo(name: "x", title: "x", year: "", manufacturer: "", cloneOf: nil, artTypes: [], hasHistory: false, romSets: [], system: "psx",
                           sourcePath: "roms/other-systems/psx/x")
        XCTAssertFalse(player().isSupported(n64))
        XCTAssertThrowsError(try player().plan(for: n64)) { XCTAssertEqual($0 as? LocalPlayError, .unsupportedSystem("psx")) }
        for e in [LocalPlayError.masterUnavailable, .missingRoms("a"), .noEmulator("b"), .missingSDL, .missingRetroArch, .missingCore("c"), .unsupportedSystem("d"), .missingHypseus, .missingEmulator("e"), .missingBIOS(system: "s", folder: "f", masterFolder: "m"), .extractionFailed("x"), .noDiscImage("n")] {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty)
        }
    }

    func testPrepareCreatesMameFolders() throws {
        try touch("roms/sets/0.172/pacman.zip")
        let p = player(), plan = try p.plan(for: mame("pacman"))
        p.prepare(plan)
        for sub in ["cfg", "nvram", "sta", "ini"] { XCTAssertTrue(FileManager.default.fileExists(atPath: plan.workingDirectory + "/" + sub)) }
    }

    func testNotWorkingComesFromTheDriverStatus() {
        XCTAssertTrue(LocalPlayer.isNotWorking(listxml: "<machine name=\"x\">\n<driver status=\"preliminary\" emulation=\"preliminary\"/>"))
        XCTAssertFalse(LocalPlayer.isNotWorking(listxml: "<driver status=\"imperfect\" emulation=\"good\"/>"))
        XCTAssertFalse(LocalPlayer.isNotWorking(listxml: "<driver status=\"good\"/>"))
        XCTAssertFalse(LocalPlayer.isNotWorking(listxml: "no driver here"))
    }

    func testListxmlCommandOnlyForTheMameGameBeingRun() throws {
        try touch("roms/sets/0.172/pacman.zip")
        let p = player(), plan = try p.plan(for: mame("pacman"))
        XCTAssertEqual(p.listxmlCommand(for: plan, game: mame("pacman"))?.arguments, ["-listxml", "pacman"])
        XCTAssertNil(p.listxmlCommand(for: plan, game: adventure))
        XCTAssertNil(p.listxmlCommand(for: plan, game: mame("other")))
    }

    func testDaphneRunsFromALocalMirrorSoTheMasterIsNeverWritten() throws {
        let fm = FileManager.default
        let folder = root.appendingPathComponent("roms/other-systems/daphne/lair.daphne")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for f in ["lair.m2v", "lair.ogg", "lair.txt", "lair.dat"] { try Data(f.utf8).write(to: folder.appendingPathComponent(f)) }
        let game = GameInfo(name: "lair", title: "Dragon's Lair", year: "", manufacturer: "", cloneOf: nil, artTypes: [], hasHistory: false, romSets: [],
                            system: "daphne", sourcePath: "roms/other-systems/daphne/lair.daphne")
        XCTAssertTrue(player().isSupported(game))
        XCTAssertThrowsError(try player().plan(for: game)) { XCTAssertEqual($0 as? LocalPlayError, .missingHypseus) }
        let hyp = support.appendingPathComponent("emulators/hypseus")
        try fm.createDirectory(at: hyp, withIntermediateDirectories: true)
        try exec(hyp.appendingPathComponent("hypseus"))
        let p = player(), plan = try p.plan(for: game)
        XCTAssertEqual(plan.arguments[0], "lair")
        XCTAssertTrue(plan.arguments.contains("vldp"))
        let frame = plan.arguments[plan.arguments.firstIndex(of: "-framefile")! + 1]
        XCTAssertTrue(frame.hasSuffix("daphne/lair.daphne/lair.txt"))
        p.prepare(plan)
        let work = support.appendingPathComponent("daphne/lair.daphne")
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: work.appendingPathComponent("lair.m2v").path), "video is linked, not copied")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: work.appendingPathComponent("lair.dat").path), "the index is a private copy")
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("lair.dat"), encoding: .utf8), "lair.dat")
        p.prepare(plan)   // running it again keeps what is there
        XCTAssertTrue(fm.fileExists(atPath: work.appendingPathComponent("lair.ogg").path))
        XCTAssertEqual(plan, try p.plan(for: game))
    }

    func testC64UsesViceAndTheStickAsDpad() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("roms/other-systems/c64"), withIntermediateDirectories: true)
        try touch("roms/other-systems/c64/Boulder Dash (USA).zip")
        try Data().write(to: cores.appendingPathComponent("vice_x64sc_libretro.dylib"))
        let game = GameInfo(name: "Boulder Dash (USA)", title: "Boulder Dash", year: "", manufacturer: "", cloneOf: nil, artTypes: [], hasHistory: false, romSets: [],
                            system: "c64", sourcePath: "roms/other-systems/c64/Boulder Dash (USA).zip")
        let plan = try player().plan(for: game)
        XCTAssertTrue(plan.arguments.contains { $0.hasSuffix("vice_x64sc_libretro.dylib") })
        XCTAssertTrue(LocalPlayer.retroArchSettings(system: "c64").contains("analog_dpad_mode"))
        let p = player()
        p.prepare(plan)
        let opt = try String(contentsOf: base.appendingPathComponent("raconfig/VICE x64sc/VICE x64sc.opt"), encoding: .utf8)
        XCTAssertTrue(opt.contains("vice_autoloadwarp = \"enabled\""))
    }

    private func scoreEntry(game: String, machine: String = "arcade2", score: Int, data: Data = Data([1, 2, 3])) -> CollectedScore {
        let file = ScoreFile(core: "mame-libretro/mame2010", kind: "hi", game: game, size: data.count, mtime: 100, md5: "md5")
        let table = ScoreTable(columns: ["RANK", "SCORE", "NAME"], rows: [["1", String(score), "JON"]])
        return CollectedScore(machine: machine, file: file, table: table, note: nil, data: data)
    }

    struct MockScoreDecoder: ScoreDecoder {
        let scores: [Data: Int]
        func decode(game: String, data: Data) async throws -> ScoreTable {
            let score = scores[data] ?? (data.count * 1000)
            return ScoreTable(columns: ["RANK", "SCORE", "NAME"], rows: [["1", String(score), "AAA"]])
        }
    }

    func testMamePlanIncludesHiscorePluginArgumentsForModernBuilds() throws {
        try touch("roms/sets/0.198/pacman.zip")
        let plan = try player().plan(for: mame("pacman"))
        XCTAssertTrue(plan.arguments.contains("-plugins"))
        XCTAssertTrue(plan.arguments.contains("-plugin"))
        guard let pIndex = plan.arguments.firstIndex(of: "-plugin") else { return XCTFail("no -plugin flag") }
        XCTAssertEqual(plan.arguments[pIndex + 1], "hiscore")
        guard let psIndex = plan.arguments.firstIndex(of: "-pluginspath") else { return XCTFail("no -pluginspath flag") }
        XCTAssertTrue(plan.arguments[psIndex + 1].hasSuffix("mame/plugins"))
    }

    func testMamePlanOmitsPluginsForBuildsOlderThan181() throws {
        try touch("roms/sets/0.172/pacman.zip")
        let plan = try player().plan(for: mame("pacman"))
        XCTAssertFalse(plan.arguments.contains("-plugins"))
    }

    func testPrepareMameCreatesHiDirectoryAndPlugins() throws {
        try touch("roms/sets/0.172/pacman.zip")
        let p = player(), plan = try p.plan(for: mame("pacman"))
        p.prepare(plan)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: plan.workingDirectory + "/hi"))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("mame/plugins/boot.lua").path))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("mame/plugins/hiscore/hiscore.dat").path))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("mame/plugins/hiscore/init.lua").path))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("mame/plugins/json/init.lua").path))
        XCTAssertTrue(fm.fileExists(atPath: plan.workingDirectory + "/ini/hiscore.ini"))
        let ini = try String(contentsOfFile: plan.workingDirectory + "/ini/hiscore.ini", encoding: .utf8)
        XCTAssertTrue(ini.contains("hi_path"))
    }

    func testStageHighScoreWritesArcadeScoreWhenNoLocalFileExists() async throws {
        try touch("roms/sets/0.172/pacman.zip")
        let p = player(), plan = try p.plan(for: mame("pacman"))
        p.prepare(plan)
        let scores = UnifiedScores(entries: [scoreEntry(game: "pacman", score: 100_000, data: Data([10, 20, 30]))])
        let staged = await p.stageHighScore(for: mame("pacman"), from: scores, in: plan)
        XCTAssertTrue(staged)
        let dest = URL(fileURLWithPath: plan.workingDirectory).appendingPathComponent("hi/pacman.hi")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try Data(contentsOf: dest), Data([10, 20, 30]))
    }

    func testStageHighScorePreservesHigherLocalScore() async throws {
        try touch("roms/sets/0.172/pacman.zip")
        let p = player(), plan = try p.plan(for: mame("pacman"))
        p.prepare(plan)
        let dest = URL(fileURLWithPath: plan.workingDirectory).appendingPathComponent("hi/pacman.hi")
        let localData = Data([99, 99])
        try localData.write(to: dest)
        let arcadeData = Data([10, 20, 30])
        let scores = UnifiedScores(entries: [scoreEntry(game: "pacman", score: 100_000, data: arcadeData)])
        let decoder = MockScoreDecoder(scores: [localData: 200_000, arcadeData: 100_000])
        let staged = await p.stageHighScore(for: mame("pacman"), from: scores, in: plan, decoder: decoder)
        XCTAssertFalse(staged)
        XCTAssertEqual(try Data(contentsOf: dest), localData)
    }

    func testStageHighScoreOverwritesLowerLocalScore() async throws {
        try touch("roms/sets/0.172/pacman.zip")
        let p = player(), plan = try p.plan(for: mame("pacman"))
        p.prepare(plan)
        let dest = URL(fileURLWithPath: plan.workingDirectory).appendingPathComponent("hi/pacman.hi")
        let localData = Data([99, 99])
        try localData.write(to: dest)
        let arcadeData = Data([10, 20, 30])
        let scores = UnifiedScores(entries: [scoreEntry(game: "pacman", score: 100_000, data: arcadeData)])
        let decoder = MockScoreDecoder(scores: [localData: 50_000, arcadeData: 100_000])
        let staged = await p.stageHighScore(for: mame("pacman"), from: scores, in: plan, decoder: decoder)
        XCTAssertTrue(staged)
        XCTAssertEqual(try Data(contentsOf: dest), arcadeData)
    }

    func testStageHighScoreHandlesNvramGame() async throws {
        try touch("roms/sets/0.172/nvgame.zip")
        let p = player(), plan = try p.plan(for: mame("nvgame"))
        p.prepare(plan)
        let nvData = Data([1, 2, 3, 4])
        let file = ScoreFile(core: "mame-libretro/mame2003", kind: "nv", game: "nvgame", size: nvData.count, mtime: 100)
        let entry = CollectedScore(machine: "arcade2", file: file, table: nil, note: nil, data: nvData)
        let scores = UnifiedScores(entries: [entry])
        let staged = await p.stageHighScore(for: mame("nvgame"), from: scores, in: plan)
        XCTAssertTrue(staged)
        let dest = URL(fileURLWithPath: plan.workingDirectory).appendingPathComponent("nvram/nvgame/nvgame.nv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try Data(contentsOf: dest), nvData)
        let stagedAgain = await p.stageHighScore(for: mame("nvgame"), from: scores, in: plan)
        XCTAssertFalse(stagedAgain)
    }
}
