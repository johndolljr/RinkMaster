import Foundation

/// PlayStation Portable, PlayStation and PlayStation 2 games: disc images that may sit in the master as zip or 7z archives. They are unpacked
/// once into a local cache (the emulators cannot read an archive) and played with PPSSPP, DuckStation and PCSX2.
extension LocalPlayer {
    static let discSystems: Set<String> = ["psp", "ps1", "ps2"]

    /// Extensions tried in this order when an archive holds several files (a cue sheet beats the bin it points at).
    static let imageRank: [String: [String]] = [
        "ps1": ["cue", "chd", "pbp", "m3u", "iso", "ecm", "img", "bin"],
        "ps2": ["iso", "chd", "bin", "cso", "gz", "img"],
        "psp": ["iso", "cso", "pbp"],
    ]

    static let archiveExtensions: Set<String> = ["zip", "7z", "rar"]

    /// The best disc image among `names` (paths relative to the unpacked folder) for the system, or nil.
    static func pickImage(from names: [String], system: String) -> String? {
        let ranking = imageRank[system] ?? []
        let candidates = names.compactMap { name -> (rank: Int, name: String)? in
            guard !name.hasPrefix("."), !name.contains("/."), let rank = ranking.firstIndex(of: (name as NSString).pathExtension.lowercased()) else { return nil }
            return (rank, name)
        }
        return candidates.min { $0.rank != $1.rank ? $0.rank < $1.rank : $0.name.localizedStandardCompare($1.name) == .orderedAscending }?.name
    }

    private func discEmulatorApp(_ system: String) -> (name: String, binary: URL)? {
        let fm = FileManager.default
        func app(in folder: String, prefix: String, binary: String) -> URL? {
            let dir = emulatorsDirectory.appendingPathComponent(folder)
            guard let name = (try? fm.contentsOfDirectory(atPath: dir.path))?.sorted().last(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".app") }) else { return nil }
            let url = dir.appendingPathComponent(name).appendingPathComponent("Contents/MacOS/\(binary)")
            return fm.isExecutableFile(atPath: url.path) ? url : nil
        }
        switch system {
        case "psp": return app(in: "ppsspp", prefix: "PPSSPP", binary: "PPSSPPSDL").map { ("PPSSPP", $0) }
        case "ps1": return app(in: "duckstation", prefix: "DuckStation", binary: "DuckStation").map { ("DuckStation", $0) }
        case "ps2": return app(in: "pcsx2", prefix: "PCSX2", binary: "PCSX2").map { ("PCSX2", $0) }
        default: return nil
        }
    }

    /// Where an emulator looks for the console's BIOS, and the master folder a BIOS may be kept in (it is linked over, never modified).
    private func biosFolders(_ system: String) -> (emulator: URL, master: [URL])? {
        let support = emulatorsDirectory.deletingLastPathComponent().deletingLastPathComponent()   // ~/Library/Application Support
        let bios = master.root.appendingPathComponent("roms/other-systems/BIOS")
        switch system {
        case "ps1": return (support.appendingPathComponent("DuckStation/bios"), [bios.appendingPathComponent("ps1"), bios.appendingPathComponent("psx")])
        case "ps2": return (support.appendingPathComponent("PCSX2/bios"), [bios.appendingPathComponent("ps2")])
        default: return nil
        }
    }

    private static func hasFiles(_ dir: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { !$0.hasPrefix(".") }
    }

    /// A readable reason when an archive file is plainly incomplete (an interrupted copy), else nil. Looks only at the header of a 7z
    /// (which says how long the file must be) and the end of a zip (where its directory is written).
    static func incompleteArchiveReason(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 32), head.count >= 6 else { return nil }
        func mb(_ bytes: UInt64) -> String { "\(bytes / 1_000_000) MB" }
        if Array(head.prefix(6)) == [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], head.count == 32 {
            let word: (Int) -> UInt64 = { at in head.subdata(in: at..<at + 8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }
            let needed = 32 + word(12) + word(20)
            return size < needed ? "\(url.lastPathComponent) is incomplete: \(mb(size)) of \(mb(needed)) were copied. Copy it again." : nil
        }
        if Array(head.prefix(2)) == [0x50, 0x4B] {
            let tail = min(size, 70_000)
            try? handle.seek(toOffset: size - tail)
            let end = (try? handle.read(upToCount: Int(tail))) ?? Data()
            return end.range(of: Data([0x50, 0x4B, 0x05, 0x06])) == nil ? "\(url.lastPathComponent) is incomplete (\(mb(size)) copied, no end of archive). Copy it again." : nil
        }
        return nil
    }

    /// Copies the BIOS files in `source` into `destination`, never replacing a file that is there. Zip and 7z archives are unpacked and
    /// every file in them is put directly in the folder, since the emulators only look at the top level.
    static func provisionBIOS(from source: URL, to destination: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        func copy(_ file: URL) {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: file, to: target) }
        }
        for name in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] where !name.hasPrefix(".") {
            let file = source.appendingPathComponent(name)
            guard archiveExtensions.contains(file.pathExtension.lowercased()) else { copy(file); continue }
            let temp = fm.temporaryDirectory.appendingPathComponent("bios-\(UUID().uuidString)")
            try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temp) }
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            tar.arguments = ["-xf", file.path, "-C", temp.path]
            tar.standardError = FileHandle.nullDevice; tar.standardOutput = FileHandle.nullDevice
            guard (try? tar.run()) != nil else { continue }
            tar.waitUntilExit()
            for path in (fm.enumerator(atPath: temp.path)?.allObjects as? [String]) ?? [] {
                let url = temp.appendingPathComponent(path)
                var isDir: ObjCBool = false
                if !path.contains("/.") && !path.hasPrefix("."), fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue, url.lastPathComponent != ".DS_Store" { copy(url) }
            }
        }
    }

    func discPlan(_ game: GameInfo) throws -> LaunchPlan {
        let system = game.system
        guard let emulator = discEmulatorApp(system) else {
            throw LocalPlayError.missingEmulator(system == "psp" ? "PPSSPP" : (system == "ps1" ? "DuckStation" : "PCSX2"))
        }
        if let bios = biosFolders(system), !Self.hasFiles(bios.emulator) {
            // a BIOS kept in the master is copied into the emulator's folder (an archive is unpacked, its files side by side)
            for source in bios.master where Self.hasFiles(source) { Self.provisionBIOS(from: source, to: bios.emulator) }
            if !Self.hasFiles(bios.emulator) { throw LocalPlayError.missingBIOS(system: system == "ps1" ? "PlayStation" : "PlayStation 2", folder: bios.emulator.path, masterFolder: "roms/other-systems/BIOS/\(system)") }
        }
        guard let source = game.sourcePath.flatMap({ master.otherSystemURL(sourcePath: $0) }) else { throw LocalPlayError.missingRoms(game.name) }
        let image = "{DISC}"
        let arguments: [String]
        switch system {
        case "psp": arguments = [image]
        default: arguments = ["-batch", "-nofullscreen", "--", image]
        }
        let isArchive = Self.archiveExtensions.contains(source.pathExtension.lowercased())
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let cache = supportDirectory.appendingPathComponent("discs/\(system)/\(game.name)")
        let extraction = (isArchive || isFolder) ? DiscExtraction(archive: source, folder: cache, system: system) : nil
        var final = arguments
        if extraction == nil, let i = final.firstIndex(of: image) { final[i] = source.path }
        return LaunchPlan(executable: emulator.binary.path, arguments: final, environment: [:], workingDirectory: supportDirectory.path,
                          emulator: emulator.name, extraction: extraction)
    }

    /// Unpacks the archive (first launch only) and fills the image into the plan. Blocking: call it off the main thread.
    public func finalize(_ plan: LaunchPlan) throws -> LaunchPlan {
        guard let extraction = plan.extraction else { return plan }
        let fm = FileManager.default
        let marker = extraction.folder.appendingPathComponent(".rinkmaster-unpacked")
        func relativeFiles() -> [String] {
            (fm.enumerator(atPath: extraction.folder.path)?.allObjects as? [String]) ?? []
        }
        if !fm.fileExists(atPath: marker.path) {
            let isFolder = (try? extraction.archive.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isFolder, let reason = Self.incompleteArchiveReason(extraction.archive) { throw LocalPlayError.extractionFailed(reason) }
            try? fm.removeItem(at: extraction.folder)
            try fm.createDirectory(at: extraction.folder, withIntermediateDirectories: true)
            if isFolder {
                for name in (try? fm.contentsOfDirectory(atPath: extraction.archive.path)) ?? [] where !name.hasPrefix(".") {
                    try? fm.createSymbolicLink(at: extraction.folder.appendingPathComponent(name), withDestinationURL: extraction.archive.appendingPathComponent(name))
                }
            } else {
                // one more try if the first fails: an extraction once stopped on a folder it could not create, and worked the next time
                var failure = ""
                for attempt in 1...2 {
                    try? fm.removeItem(at: extraction.folder)
                    try fm.createDirectory(at: extraction.folder, withIntermediateDirectories: true)
                    let tar = Process(), err = Pipe()
                    tar.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
                    tar.arguments = ["-xf", extraction.archive.path, "-C", extraction.folder.path]
                    tar.standardError = err; tar.standardOutput = FileHandle.nullDevice
                    do { try tar.run() } catch { throw LocalPlayError.extractionFailed(error.localizedDescription) }
                    let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    tar.waitUntilExit()
                    if tar.terminationStatus == 0 { failure = ""; break }
                    failure = message.isEmpty ? "\(extraction.archive.lastPathComponent) is damaged or incomplete." : message
                    if attempt == 2 || message.contains("Truncated") || message.contains("not recognized") { break }
                }
                if !failure.isEmpty {
                    try? fm.removeItem(at: extraction.folder)
                    throw LocalPlayError.extractionFailed(failure)
                }
            }
            try? Data().write(to: marker)
        }
        guard let image = Self.pickImage(from: relativeFiles(), system: extraction.system) else { throw LocalPlayError.noDiscImage(extraction.archive.lastPathComponent) }
        var arguments = plan.arguments
        if let i = arguments.firstIndex(of: "{DISC}") { arguments[i] = extraction.folder.appendingPathComponent(image).path }
        return LaunchPlan(executable: plan.executable, arguments: arguments, environment: plan.environment, workingDirectory: plan.workingDirectory,
                          emulator: plan.emulator)
    }
}
