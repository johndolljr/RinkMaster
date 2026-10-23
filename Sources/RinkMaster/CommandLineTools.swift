import SwiftUI
import RinkMasterCore

/// Headless launch flags used for verification:
///   RinkMaster --snapshot-theme out.png          render the theme preview to a PNG and exit
///   RinkMaster --test-connection <machine>       run the Settings 'Test Connection' check and print the result
///   RinkMaster --dump-inventory <machine name>   read a machine's inventory over SSH, print it and exit
///   RinkMaster --add-game <machine> <system> <game> [emulator]
///                                                copy a game (plus parents, devices, art) from the master and refresh the frontend
///   RinkMaster --remove-game <machine> <system> <game> [--dry-run] [--art]
///                                                remove a game from a machine through its service
///   RinkMaster --collect-scores                 read and decode the score files of every machine, print the best per game
///   RinkMaster --sync-scores [--apply]           collect, then print (dry run) or perform the best-file sync
///   RinkMaster --refresh-catalog                 load the cached game list, check the master, print what changed and the timings
///   RinkMaster --snapshot-app <machine> <out.png> [machines|settings]
///                                                load a machine's real inventory, render the app window to a PNG, exit
enum CommandLineTools {
    /// Returns normally if no tool flag was given; otherwise runs the tool and exits the process.
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot-theme"), args.indices.contains(i + 1) {
            snapshotTheme(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot-app"), args.indices.contains(i + 2) {
            exit(snapshotApp(machineName: args[i + 1], path: args[i + 2], section: args.indices.contains(i + 3) ? args[i + 3] : "machines"))
        }
        if let i = args.firstIndex(of: "--test-connection"), args.indices.contains(i + 1) {
            exit(testConnection(machineName: args[i + 1]))
        }
        if args.contains("--refresh-catalog") { exit(refreshCatalog()) }
        if args.contains("--sync-scores") { exit(syncScores(apply: args.contains("--apply"))) }
        if args.contains("--collect-scores") { exit(collectScores()) }
        if let i = args.firstIndex(of: "--add-game"), args.indices.contains(i + 3) {
            exit(runInstaller(args: Array(args[(i + 1)...]), adding: true))
        }
        if let i = args.firstIndex(of: "--remove-game"), args.indices.contains(i + 3) {
            exit(runInstaller(args: Array(args[(i + 1)...]), adding: false))
        }
        if let i = args.firstIndex(of: "--dump-inventory"), args.indices.contains(i + 1) {
            exit(dumpInventory(machineName: args[i + 1]))
        }
    }

    private static func snapshotTheme(to path: String) {
        MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: ThemePreviewView().frame(width: 1280, height: 800))
            renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private static func snapshotApp(machineName: String, path: String, section: String) -> Int32 {
        MainActor.assumeIsolated {
            let model = AppModel()
            let machine = model.settings.machines.first(where: { $0.name.lowercased() == machineName.lowercased() })
            if let machine {
                model.selectedMachineID = machine.id
            } else if section != "settings" {
                print("No machine named '\(machineName)'"); return 2
            }
            model.section = section == "settings" ? .settings : section == "games" ? .games : .machines
            if let i = CommandLine.arguments.firstIndex(of: "--select-game"), CommandLine.arguments.indices.contains(i + 1) {
                model.selectedGameName = CommandLine.arguments[i + 1]
            }
            nonisolated(unsafe) var done = false
            Task { @MainActor in
                switch model.section {
                case .games:
                    await model.refreshCatalog()
                    for m in model.settings.machines { await model.refreshInventory(m); await model.loadEmulators(m) }
                case .machines:
                    if let machine { await model.refreshInventory(machine) }
                default:
                    if let machine { await model.testConnection(machine) }
                }
                done = true
            }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            let hosting = NSHostingView(rootView: RootView().environment(model))
            hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
            window.contentView = hosting
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                print("render failed: could not create bitmap"); return 1
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                print("render failed: png representation failed"); return 1
            }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { print("write failed: \(error)"); return 1 }
            print("wrote \(path)")
            return 0
        }
    }

    private static func testConnection(machineName: String) -> Int32 {
        MainActor.assumeIsolated {
            let model = AppModel()
            guard let machine = model.settings.machines.first(where: { $0.name.lowercased() == machineName.lowercased() }) else {
                print("No machine named '\(machineName)'"); return 2
            }
            nonisolated(unsafe) var done = false
            Task { @MainActor in await model.testConnection(machine); done = true }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            print("\(machine.name): \(model.connectionStatus[machine.id] ?? "?")")
            return 0
        }
    }

    private static func refreshCatalog() -> Int32 {
        MainActor.assumeIsolated {
            let started = Date()
            let model = AppModel()  // loads catalog-cache.json if there is one
            var cached = 0
            if case .loaded(let c) = model.catalog { cached = c.games.count }
            let cacheLoaded = Date().timeIntervalSince(started)
            nonisolated(unsafe) var done = false
            Task { @MainActor in await model.refreshCatalog(); done = true }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let total = Date().timeIntervalSince(started)
            guard case .loaded(let c) = model.catalog else { print("failed: \(model.catalogNote ?? "")"); return 1 }
            print(String(format: "cache: %d games ready in %.2fs; after the master check: %d games, total %.2fs", cached, cacheLoaded, c.games.count, total))
            if let note = model.catalogNote { print("note: \(note)") }
            if let g = c.game("galaga") { print("galaga: \(g.title), sets \(g.romSets), art \(g.artTypes), history \(model.historySections(for: "galaga")?.first?.body.prefix(50) ?? "-")") }
            return 0
        }
    }

    private static func syncScores(apply: Bool) -> Int32 {
        MainActor.assumeIsolated {
            let model = AppModel()
            nonisolated(unsafe) var done = false
            Task { @MainActor in
                await model.refreshScores()
                model.previewSync()
                if let plan = model.syncPlan {
                    print("\(plan.items.count) planned write(s)\(apply ? "" : " (dry run)")")
                    for item in plan.items { print("  " + item.summary) }
                    if apply { await model.applySync(); for r in model.syncResults ?? [] { print("  \(r.error == nil ? "ok" : "FAILED: " + (r.error ?? "")): \(r.item.summary)") } }
                }
                done = true
            }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return 0
        }
    }

    private static func collectScores() -> Int32 {
        MainActor.assumeIsolated {
            let model = AppModel()
            nonisolated(unsafe) var done = false
            Task { @MainActor in await model.refreshScores(); done = true }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard case .loaded(let unified) = model.scores else { print("failed"); return 1 }
            if let note = model.scoresNote { print("note: \(note)") }
            var decoded = 0, skipped = 0
            for game in unified.games {
                for e in unified.entries(for: game) { if e.table != nil { decoded += 1 } else { skipped += 1 } }
            }
            print("\(unified.games.count) games: \(decoded) files decoded, \(skipped) not decodable")
            for game in unified.games {
                guard let best = unified.best(for: game) else { continue }
                print("  \(game): \(best.topScore ?? 0) (\(best.machine), \(best.file.core))")
            }
            return 0
        }
    }

    private static func runInstaller(args: [String], adding: Bool) -> Int32 {
        do {
            let settings = try MachineStore.load()
            guard let machine = settings.machines.first(where: { $0.name.lowercased() == args[0].lowercased() }) else {
                print("No machine named '\(args[0])'"); return 2
            }
            let system = args[1], game = args[2]
            let flags = Set(args.dropFirst(3).filter { $0.hasPrefix("--") })
            let emulator = args.dropFirst(3).first { !$0.hasPrefix("--") }
            let master = MasterLibrary(root: URL(fileURLWithPath: settings.masterPath))
            let xml = try Data(contentsOf: master.root.appendingPathComponent("data/mame2016.xml"))
            let database = try MameDatabase.parse(xml)
            let installer = Installer(machine: machine, shell: SSHShell(target: machine.sshTarget),
                                      service: ServiceClient(host: machine.host, port: machine.servicePort),
                                      master: master, database: database)
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var output = ""
            nonisolated(unsafe) var failure: Error?
            Task.detached {
                do {
                    if adding {
                        let r = try await installer.add(game: game, system: system, emulator: emulator)
                        output = "added \(r.game) to \(machine.name) (\(r.system), \(r.emulator)); ROM sets \(r.romSets); frontend refreshed \(r.frontendRefreshed)"
                    } else {
                        let plan = try await installer.remove(game: game, system: system,
                                                              options: RemovalOptions(art: flags.contains("--art")), dryRun: flags.contains("--dry-run"))
                        output = (plan.dryRun ? "would remove" : "removed") + " from \(machine.name): \((plan.removed ?? plan.remove).joined(separator: ", ")); pin \(plan.pin); frontend \(plan.frontend?.refreshed ?? [])"
                    }
                } catch { failure = error }
                semaphore.signal()
            }
            semaphore.wait()
            if let failure { print("error: \(failure)"); return 1 }
            print(output)
            return 0
        } catch { print("error: \(error)"); return 1 }
    }

    private static func dumpInventory(machineName: String) -> Int32 {
        do {
            let settings = try MachineStore.load()
            guard let machine = settings.machines.first(where: { $0.name.lowercased() == machineName.lowercased() }) else {
                print("No machine named '\(machineName)'. Known: \(settings.machines.map(\.name).joined(separator: ", "))")
                return 2
            }
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var outcome: Result<LoadedInventory, Error> = .failure(CancellationError())
            let started = Date()
            Task.detached {
                let provider = InventoryProvider(
                    service: ServiceClient(host: machine.host, port: machine.servicePort),
                    fallback: InventoryReader(shell: SSHShell(target: machine.sshTarget), machine: machine))
                outcome = await Result { try await provider.load() }
                semaphore.signal()
            }
            semaphore.wait()
            let loaded = try outcome.get()
            let inventory = loaded.inventory
            print("\(machine.name): \(inventory.totalGames) games in \(inventory.systems.count) systems via \(loaded.source) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            for system in inventory.systems {
                let perEmulator = system.gamesByEmulator.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.count)" }.joined(separator: ", ")
                print("  \(system.name): \(system.games.count) games (default \(system.defaultEmulator ?? "-")) [\(perEmulator)]")
            }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
