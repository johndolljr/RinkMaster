import XCTest
@testable import RinkMasterCore

final class DiscGamesTests: XCTestCase {
    private var base: URL!
    private var root: URL { base.appendingPathComponent("master") }
    private var support: URL { base.appendingPathComponent("support") }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("dg-\(UUID().uuidString)")
        let fm = FileManager.default
        for d in ["master/roms/other-systems/ps1", "master/roms/other-systems/ps2", "master/roms/other-systems/psp", "master/roms/sets", "master/roms/other-systems/BIOS"] {
            try fm.createDirectory(at: base.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func player() -> LocalPlayer {
        LocalPlayer(master: MasterLibrary(root: root), supportDirectory: support.appendingPathComponent("RinkMaster"), coresDirectory: support)
    }

    // the player's support directory is `support/RinkMaster`, so emulators live in `support/RinkMaster/emulators`
    private func install(_ folder: String, app: String, binary: String) throws {
        let dir = support.appendingPathComponent("RinkMaster/emulators/\(folder)/\(app).app/Contents/MacOS")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(binary)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func game(_ system: String, _ file: String) -> GameInfo {
        GameInfo(name: (file as NSString).deletingPathExtension, title: file, year: "", manufacturer: "", cloneOf: nil, artTypes: [], hasHistory: false,
                 romSets: [], system: system, sourcePath: "roms/other-systems/\(system)/\(file)")
    }

    func testPickImagePrefersTheCueSheetAndSkipsJunk() {
        XCTAssertEqual(LocalPlayer.pickImage(from: ["Game (Disc 1)/Game.bin", "Game (Disc 1)/Game.cue", "readme.txt"], system: "ps1"), "Game (Disc 1)/Game.cue")
        XCTAssertEqual(LocalPlayer.pickImage(from: ["a.sub", "a.ccd", "a.img.ecm"], system: "ps1"), "a.img.ecm")
        XCTAssertEqual(LocalPlayer.pickImage(from: ["Disc 2.cue", "Disc 1.cue"], system: "ps1"), "Disc 1.cue")
        XCTAssertEqual(LocalPlayer.pickImage(from: ["x.iso", "x.chd"], system: "ps2"), "x.iso")
        XCTAssertEqual(LocalPlayer.pickImage(from: [".hidden.iso", "game.CSO", "dir/.DS_Store"], system: "psp"), "game.CSO")
        XCTAssertNil(LocalPlayer.pickImage(from: ["notes.txt"], system: "psp"))
        XCTAssertNil(LocalPlayer.pickImage(from: ["a.iso"], system: "snes"))
    }

    func testSystemsAreSupportedAndNeedTheirEmulator() throws {
        let g = game("psp", "Lumines.iso")
        XCTAssertTrue(player().isSupported(g))
        XCTAssertThrowsError(try player().plan(for: g)) { XCTAssertEqual($0 as? LocalPlayError, .missingEmulator("PPSSPP")) }
        XCTAssertThrowsError(try player().plan(for: game("ps1", "x.cue"))) { XCTAssertEqual($0 as? LocalPlayError, .missingEmulator("DuckStation")) }
        XCTAssertThrowsError(try player().plan(for: game("ps2", "x.iso"))) { XCTAssertEqual($0 as? LocalPlayError, .missingEmulator("PCSX2")) }
    }

    func testPlainImagePlaysFromTheMasterWithoutUnpacking() throws {
        try install("ppsspp", app: "PPSSPPSDL", binary: "PPSSPPSDL")
        try Data().write(to: root.appendingPathComponent("roms/other-systems/psp/Lumines.iso"))
        let plan = try player().plan(for: game("psp", "Lumines.iso"))
        XCTAssertNil(plan.extraction)
        XCTAssertEqual(plan.emulator, "PPSSPP")
        XCTAssertTrue(plan.arguments[0].hasSuffix("psp/Lumines.iso"))
        XCTAssertEqual(try player().finalize(plan), plan)
    }

    func testPs1NeedsABiosAndLinksOneKeptInTheMaster() throws {
        try install("duckstation", app: "DuckStation", binary: "DuckStation")
        try Data().write(to: root.appendingPathComponent("roms/other-systems/ps1/Game.cue"))
        let g = game("ps1", "Game.cue")
        XCTAssertThrowsError(try player().plan(for: g)) { error in
            guard case .missingBIOS(let system, let folder, _) = error as? LocalPlayError else { return XCTFail("\(error)") }
            XCTAssertEqual(system, "PlayStation")
            XCTAssertTrue(folder.hasSuffix("DuckStation/bios"))
            XCTAssertFalse((error as? LocalPlayError)?.errorDescription?.isEmpty ?? true)
        }
        let masterBios = root.appendingPathComponent("roms/other-systems/BIOS/ps1")
        try FileManager.default.createDirectory(at: masterBios, withIntermediateDirectories: true)
        try Data("bios".utf8).write(to: masterBios.appendingPathComponent("scph5501.bin"))
        let plan = try player().plan(for: g)
        XCTAssertEqual(Array(plan.arguments.prefix(3)), ["-batch", "-nofullscreen", "--"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("DuckStation/bios/scph5501.bin").path))
    }

    func testBiosArchiveIsUnpackedFlatAndNothingIsOverwritten() throws {
        let work = base.appendingPathComponent("w"), nested = work.appendingPathComponent("bios/v1")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: nested.appendingPathComponent("A.BIN"))
        try Data("two".utf8).write(to: work.appendingPathComponent("bios/B.NVM"))
        try Data("x".utf8).write(to: work.appendingPathComponent("bios/.DS_Store"))
        let src = base.appendingPathComponent("src"), dest = base.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = work
        zip.arguments = ["-qr", src.appendingPathComponent("bios.zip").path, "bios"]
        try zip.run(); zip.waitUntilExit()
        try Data("plain".utf8).write(to: src.appendingPathComponent("SCPH1001.BIN"))
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: dest.appendingPathComponent("A.BIN"))
        LocalPlayer.provisionBIOS(from: src, to: dest)
        let names = try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
        XCTAssertEqual(names, ["A.BIN", "B.NVM", "SCPH1001.BIN"])
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("A.BIN"), encoding: .utf8), "mine", "an existing file is kept")
    }

    func testArchiveIsUnpackedOnceAndTheImageIsFound() throws {
        try install("pcsx2", app: "PCSX2-v2", binary: "PCSX2")
        try Data("b".utf8).write(to: { () -> URL in
            let d = support.appendingPathComponent("PCSX2/bios"); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d.appendingPathComponent("ps2.bin") }())
        let work = base.appendingPathComponent("work"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("iso-data".utf8).write(to: work.appendingPathComponent("GTA III.iso"))
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = work
        zip.arguments = ["-q", root.appendingPathComponent("roms/other-systems/ps2/GTA III.zip").path, "GTA III.iso"]
        try zip.run(); zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        let p = player(), plan = try p.plan(for: game("ps2", "GTA III.zip"))
        XCTAssertNotNil(plan.extraction)
        XCTAssertTrue(plan.arguments.contains("{DISC}"))
        let final = try p.finalize(plan)
        XCTAssertNil(final.extraction)
        let image = final.arguments.last!
        XCTAssertTrue(image.hasSuffix("discs/ps2/GTA III/GTA III.iso"))
        XCTAssertEqual(try String(contentsOfFile: image, encoding: .utf8), "iso-data")
        // a second launch reuses what is unpacked
        try Data("changed".utf8).write(to: URL(fileURLWithPath: image))
        XCTAssertEqual(try String(contentsOfFile: try p.finalize(plan).arguments.last!, encoding: .utf8), "changed")
    }

    func testIncompleteArchivesAreNamedAsSuch() throws {
        let fm = FileManager.default
        // a 7z header that promises more bytes than the file has (next header at offset 1000, 100 long)
        var seven = Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4, 0, 0, 0, 0])
        seven.append(withUnsafeBytes(of: UInt64(1000).littleEndian) { Data($0) })
        seven.append(withUnsafeBytes(of: UInt64(100).littleEndian) { Data($0) })
        seven.append(Data(count: 4 + 50))
        let short = base.appendingPathComponent("short.7z"); try seven.write(to: short)
        XCTAssertTrue(LocalPlayer.incompleteArchiveReason(short)?.contains("incomplete") ?? false)
        let zip = base.appendingPathComponent("cut.zip"); try (Data([0x50, 0x4B, 0x03, 0x04]) + Data(count: 500)).write(to: zip)
        XCTAssertTrue(LocalPlayer.incompleteArchiveReason(zip)?.contains("no end of archive") ?? false)
        let whole = base.appendingPathComponent("whole.zip"); try (Data([0x50, 0x4B, 0x03, 0x04]) + Data(count: 100) + Data([0x50, 0x4B, 0x05, 0x06]) + Data(count: 18)).write(to: whole)
        XCTAssertNil(LocalPlayer.incompleteArchiveReason(whole))
        let text = base.appendingPathComponent("a.txt"); try Data("hello world".utf8).write(to: text)
        XCTAssertNil(LocalPlayer.incompleteArchiveReason(text))
        XCTAssertNil(LocalPlayer.incompleteArchiveReason(base.appendingPathComponent("missing.zip")))
        XCTAssertTrue(fm.fileExists(atPath: short.path))
    }

    func testDamagedArchiveAndFolderGamesAreHandled() throws {
        try install("duckstation", app: "DuckStation", binary: "DuckStation")
        let bios = support.appendingPathComponent("DuckStation/bios"); try FileManager.default.createDirectory(at: bios, withIntermediateDirectories: true)
        try Data("b".utf8).write(to: bios.appendingPathComponent("b.bin"))
        try Data("not a zip at all".utf8).write(to: root.appendingPathComponent("roms/other-systems/ps1/Broken.zip"))
        let p = player(), broken = try p.plan(for: game("ps1", "Broken.zip"))
        XCTAssertThrowsError(try p.finalize(broken)) { error in
            guard case .extractionFailed = error as? LocalPlayError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("RinkMaster/discs/ps1/Broken").path), "no half-unpacked folder is left")
        // a folder game: its files are linked, and a folder without an image is reported
        let folder = root.appendingPathComponent("roms/other-systems/ps1/Folder Game")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let plan = try p.plan(for: game("ps1", "Folder Game"))
        XCTAssertThrowsError(try p.finalize(plan)) { XCTAssertEqual($0 as? LocalPlayError, .noDiscImage("Folder Game")) }
        try Data("cue".utf8).write(to: folder.appendingPathComponent("g.cue"))
        try FileManager.default.removeItem(at: support.appendingPathComponent("RinkMaster/discs/ps1/Folder Game"))
        XCTAssertTrue(try p.finalize(plan).arguments.last!.hasSuffix("Folder Game/g.cue"))
    }
}
