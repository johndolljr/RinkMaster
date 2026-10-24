import SwiftUI
import RinkMasterCore
import GameController

enum NavSection: String, CaseIterable, Identifiable {
    case machines = "MACHINES", games = "GAMES", scores = "HIGH SCORES", settings = "SETTINGS"
    var id: String { rawValue }
}

/// One caching decoder per master location, shared by every collect.
final class DecoderHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (root: String, java: String, decoder: CachingDecoder)?
    func decoder(for master: MasterLibrary, java: String) -> ScoreDecoder? {
        lock.lock(); defer { lock.unlock() }
        if let c = current, c.root == master.root.path, c.java == java { return c.decoder }
        guard let real = Hi2txtDecoder.inMaster(master, java: java) else { return nil }
        let caching = CachingDecoder(real)
        current = (master.root.path, java, caching)
        return caching
    }
}

enum CatalogError: Error, CustomStringConvertible {
    case masterNotMounted(String), notLoaded
    var description: String {
        switch self {
        case .masterNotMounted(let p): return "The master share is not mounted at \(p)"
        case .notLoaded: return "The game catalog is not loaded"
        }
    }
}

enum LoadState<Value> {
    case idle, loading, loaded(Value), failed(String)
}

@MainActor @Observable
final class AppModel {
    var settings: AppSettings { didSet { persist() } }
    var section: NavSection = .machines
    var selectedMachineID: String?
    var inventories: [String: LoadState<MachineInventory>] = [:]
    var inventorySources: [String: InventorySource] = [:]
    var connectionStatus: [String: String] = [:]
    private var providers: [String: (key: String, provider: InventoryProvider)] = [:]
    private(set) var saveError: String?

    // Game browser
    var catalog: LoadState<GameCatalog> = .idle
    var catalogRefreshing = false
    var catalogNote: String?
    var catalogCheckedAt: Date?
    private var catalogCache: CatalogCache?
    private var historyIndex = HistoryIndex(spans: [:])
    private var backgroundCatalog: Task<Void, Never>?
    var selectedGameName: String?
    var emulators: [String: MachineEmulators] = [:]
    /// Result line per "machine/game" for the add button, so the detail view can show progress and outcome.
    var emulatorErrors: [String: String] = [:]
    var addStatus: [String: String] = [:]
    var removeStatus: [String: String] = [:]
    /// Result of the last frontend restart per machine, and which machines are restarting now.
    var frontendStatus: [String: String] = [:]
    var frontendBusy: Set<String> = []
    var gamelistStatus: [String: String] = [:]
    var gamelistBusy: Set<String> = []
    var themeStatus: [String: String] = [:]
    var themeBusy: Set<String> = []

    // High scores
    var scores: LoadState<UnifiedScores> = .idle
    var scoresCollectedAt: Date?
    var scoresRefreshing = false
    private var scoreCache: ScoreCache?
    private var backgroundScores: Task<Void, Never>?
    var scoresNote: String?

    // MARK: playing on this Mac
    /// The game running here, by catalog id, with the emulator that runs it; `playNote` is the last launch problem.
    private(set) var playing: (id: String, emulator: String)?
    var playNote: String?
    private var playProcess: Process?
    private var playPID: Int32?

    var localPlayer: LocalPlayer {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let own = support.appendingPathComponent("RinkMaster")
        let native = own.appendingPathComponent("emulators/RetroArch.app")
        let nativeCores = own.appendingPathComponent("emulators/cores-arm64")
        let haveNative = FileManager.default.fileExists(atPath: native.path) && FileManager.default.fileExists(atPath: nativeCores.path)

        let customRetro = settings.retroArchPath.trimmingCharacters(in: .whitespaces)
        let retroArchURL: URL
        if !customRetro.isEmpty && FileManager.default.fileExists(atPath: customRetro) {
            retroArchURL = URL(fileURLWithPath: customRetro)
        } else if haveNative {
            retroArchURL = native
        } else {
            let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/RetroArch.app")
            if FileManager.default.fileExists(atPath: userApps.path) {
                retroArchURL = userApps
            } else {
                retroArchURL = URL(fileURLWithPath: "/Applications/RetroArch.app")
            }
        }

        return LocalPlayer(master: master, supportDirectory: own,
                           retroArchApp: retroArchURL,
                           coresDirectory: haveNative ? nativeCores : support.appendingPathComponent("RetroArch/cores"),
                           retroArchConfigDirectory: support.appendingPathComponent("RetroArch/config"))
    }

    /// Names of the game controllers macOS sees right now (an Xbox pad shows as "Xbox Wireless Controller").
    var controllerNames: [String] { GCController.controllers().map { $0.vendorName ?? "Controller" } }

    func play(_ game: GameInfo) {
        playNote = nil
        if let pid = playPID, kill(pid, 0) != 0 { finishedPlaying(pid) }
        guard playing == nil else { playNote = "A game is already running. Quit it first."; return }
        let player = localPlayer
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let plan = try player.plan(for: game)
                if game.isMame, let scores = self.unifiedScores ?? ScoreCache.load().map({ UnifiedScores(entries: $0.entries) }) {
                    await player.stageHighScore(for: game, from: scores, in: plan, decoder: self.decoderCache.decoder(for: self.master, java: self.javaPath()))
                }
                guard plan.extraction != nil else { self.launch(plan, game: game, player: player); return }
                // a disc image in an archive is unpacked once into a local cache, which can take a minute for a big game
                self.playing = (game.id, "UNPACKING THE DISC IMAGE (FIRST PLAY ONLY)")
                Task.detached { [weak self] in
                    let result = Result { try player.finalize(plan) }
                    await MainActor.run {
                        guard let self else { return }
                        self.playing = nil
                        switch result {
                        case .success(let final): self.launch(final, game: game, player: player)
                        case .failure(let error): self.playNote = error.localizedDescription
                        }
                    }
                }
            } catch {
                self.playNote = error.localizedDescription
            }
        }
    }

    /// True while a disc image is being unpacked, before any emulator runs.
    var playPreparing: Bool { playing != nil && playPID == nil }

    private func launch(_ plan: LaunchPlan, game: GameInfo, player: LocalPlayer) {
        do {
            player.prepare(plan)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: plan.executable)
            process.arguments = plan.arguments
            process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory)
            process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { $1 }
            let log = Pipe()
            process.standardOutput = log; process.standardError = log
            process.terminationHandler = { [weak self] p in
                let tail = String(decoding: log.fileHandleForReading.availableData.suffix(600), as: UTF8.self)
                Task { @MainActor in
                    guard let self else { return }
                    self.finishedPlaying(p.processIdentifier)
                    if p.terminationStatus != 0 { self.playNote = "\(plan.emulator) stopped (\(p.terminationStatus)). \(tail.trimmingCharacters(in: .whitespacesAndNewlines))" }
                }
            }
            try process.run()
            playProcess = process; playPID = process.processIdentifier
            if let check = player.listxmlCommand(for: plan, game: game) { warnIfNotWorking(check, environment: plan.environment, game: game, emulator: plan.emulator) }
            playing = (game.id, plan.emulator)
            // a program started by another app opens behind it; bring the emulator's window forward once it has one
            let pid = process.processIdentifier
            Task { @MainActor in
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if let app = NSRunningApplication(processIdentifier: pid) { app.activate(from: NSRunningApplication.current, options: [.activateAllWindows]); if app.isActive { break } } else { break }
                }
            }
        } catch {
            playNote = error.localizedDescription
        }
    }

    /// MAME knows some games do not work yet (they reboot or hang); say so instead of leaving a boot loop unexplained.
    private func warnIfNotWorking(_ check: (executable: String, arguments: [String]), environment: [String: String], game: GameInfo, emulator: String) {
        Task.detached { [weak self] in
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: check.executable); p.arguments = check.arguments
            p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let xml = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard LocalPlayer.isNotWorking(listxml: xml) else { return }
            await MainActor.run { self?.playNote = "\(emulator) lists \(game.title) as NOT WORKING; it may reboot or hang. Try another revision or a clone of it." }
        }
    }

    func stopPlaying() {
        guard let pid = playPID else { playing = nil; return }
        kill(pid, SIGTERM)
        Task { @MainActor [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if kill(pid, 0) != 0 { self?.finishedPlaying(pid); return }
            }
            kill(pid, SIGKILL)
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.finishedPlaying(pid)
        }
    }

    /// An adopted game is not our child, so nothing reports its exit: look for it every second until it is gone.
    private func watchAdopted(_ pid: Int32) {
        Task { @MainActor [weak self] in
            while kill(pid, 0) == 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            self?.finishedPlaying(pid)
        }
    }

    private func finishedPlaying(_ pid: Int32) { if playPID == pid { playing = nil; playPID = nil; playProcess = nil } }

    /// Picks up a master MAME that is already running (the app was restarted mid-game) so its game shows as running and can be quit.
    func adoptRunningGame() {
        guard playing == nil else { return }
        let marker = master.root.appendingPathComponent("emulators").path + "/mame"
        let pipe = Pipe(), ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-axo", "pid=,command="]
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        for line in output.split(separator: "\n") where line.contains(marker) && line.contains("mame64") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pid = Int32(parts[0].trimmingCharacters(in: .whitespaces)), let name = parts[1].split(separator: " ").last else { continue }
            playPID = pid; playing = (String(name), "MAME")
            watchAdopted(pid)
            return
        }
    }
    var selectedScoreGame: String?
    private let decoderCache = DecoderHolder()
    var syncPlan: ScoreSyncPlan?
    var syncResults: [ScoreSyncResult]?
    var syncRunning = false
    var lastScoreSync: Date? = UserDefaults.standard.object(forKey: "lastScoreSync") as? Date
    var syncDue: Bool { ScoreSyncSchedule.isDue(last: lastScoreSync, now: Date()) }

    var master: MasterLibrary { MasterLibrary(root: URL(fileURLWithPath: settings.masterPath)) }

    /// Which cabinets have each game; rebuilt whenever an inventory loads, so lists can ask it per row cheaply.
    private(set) var installedIndex = InstalledIndex(inventories: [:])
    private(set) var inventoryRevision = 0
    var installedIndexVersion: Int { inventoryRevision }

    private func rebuildInstalledIndex() {
        var loaded: [String: MachineInventory] = [:]
        for m in settings.machines { if case .loaded(let inv) = inventories[m.id] ?? .idle { loaded[m.name] = inv } }
        installedIndex = InstalledIndex(inventories: loaded)
        inventoryRevision += 1
    }

    var unifiedScores: UnifiedScores? { if case .loaded(let u) = scores { return u }; return nil }

    init() {
        let loaded = (try? MachineStore.load()) ?? .defaults
        settings = loaded
        selectedMachineID = loaded.machines.first?.id
        if loaded.machines.isEmpty && loaded.masterPath.isEmpty { section = .settings }
        if let cached = CatalogCache.load(), !cached.games.isEmpty {
            catalogCache = cached
            historyIndex = cached.historyIndex
            catalog = .loaded(GameCatalog(games: cached.games))
            catalogCheckedAt = cached.builtAt
        }
        if let cached = ScoreCache.load()?.keeping(machines: Set(loaded.machines.map(\.name))), !cached.entries.isEmpty {
            scoreCache = cached
            scores = .loaded(UnifiedScores(entries: cached.entries))
            scoresCollectedAt = cached.collectedAt
        }
        // `--section settings` opens the app on that section (handy for verification)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--section"), args.indices.contains(i + 1),
           let s = NavSection.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(args[i + 1].lowercased()) }) { section = s }
        if let i = args.firstIndex(of: "--select-game"), args.indices.contains(i + 1) { selectedGameName = args[i + 1]; selectedScoreGame = args[i + 1] }
    }

    var selectedMachine: Machine? { settings.machines.first { $0.id == selectedMachineID } }

    private func persist() {
        guard settings.validationError == nil else { return }  // never save a half-edited machine
        do { try MachineStore.save(settings); saveError = nil } catch { saveError = "Could not save settings: \(error)" }
    }

    /// One provider per machine so the service's ETag cache survives between refreshes; rebuilt if the connection settings change.
    private func provider(for machine: Machine) -> InventoryProvider {
        let key = "\(machine.user)@\(machine.host):\(machine.servicePort)|\(machine.romsPath)"
        if let existing = providers[machine.id], existing.key == key { return existing.provider }
        let provider = InventoryProvider(
            service: ServiceClient(host: machine.host, port: machine.servicePort),
            fallback: InventoryReader(shell: SSHShell(target: machine.sshTarget), machine: machine))
        providers[machine.id] = (key, provider)
        return provider
    }

    func refreshInventory(_ machine: Machine) async {
        inventories[machine.id] = .loading
        do {
            let loaded = try await provider(for: machine).load()
            inventories[machine.id] = .loaded(loaded.inventory)
            inventorySources[machine.id] = loaded.source
            rebuildInstalledIndex()
        } catch {
            inventories[machine.id] = .failed(Self.describe(error))
            inventorySources[machine.id] = nil
            rebuildInstalledIndex()
        }
    }

    /// Brings the game catalog up to date with the master. With a cache on disk the list is already showing; this only
    /// applies what changed (added or removed games, new art). The 52 MB XML is parsed only when it is needed.
    func refreshCatalog() async {
        guard !catalogRefreshing else { return }
        catalogRefreshing = true
        defer { catalogRefreshing = false }
        let master = self.master
        guard master.isAvailable else {
            if case .loaded = catalog { catalogNote = "Master share not mounted; showing the cached list" }
            else { catalog = .failed(CatalogError.masterNotMounted(master.root.path).description) }
            return
        }
        if case .loaded = catalog {} else { catalog = .loading }
        let previous = catalogCache
        let result: Result<CatalogUpdate, Error> = await Task.detached {
            Result { try CatalogUpdater(master: master).refresh(previous: previous) }
        }.value
        switch result {
        case .success(let update):
            catalogCache = update.cache
            historyIndex = update.cache.historyIndex
            if update.changed || previous == nil {
                try? CatalogCache.save(update.cache)
                catalog = .loaded(GameCatalog(games: update.cache.games))
            } else if case .loaded = catalog {} else {
                catalog = .loaded(GameCatalog(games: update.cache.games))
            }
            catalogCheckedAt = Date()
            catalogNote = update.rebuilt && previous != nil ? "Rebuilt: the MAME database changed"
                : (update.added.isEmpty && update.removed.isEmpty) ? nil
                : "\(update.added.count) added, \(update.removed.count) removed since the last check"
        case .failure(let error):
            if case .loaded = catalog { catalogNote = "Could not check the master: \(Self.describe(error))" }
            else { catalog = .failed(Self.describe(error)) }
        }
    }

    func reloadCatalog() async { if case .failed = catalog { catalog = .idle }; await refreshCatalog() }

    /// Starts checking the master for new or removed games: now, then every `interval` while the app is open.
    func startBackgroundCatalog(interval: Duration = .seconds(900)) {
        guard backgroundCatalog == nil else { return }
        backgroundCatalog = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshCatalog()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private var gamelists: [String: [String: GamelistEntry]] = [:]

    /// A non-MAME game's scraped details, from its system's gamelist.xml (read once per system, off the main thread).
    func loadGamelistEntry(for game: GameInfo) async -> GamelistEntry? {
        guard !game.isMame else { return nil }
        if gamelists[game.system] == nil {
            let url = master.root.appendingPathComponent("roms/other-systems/\(game.system)/gamelist.xml")
            gamelists[game.system] = await Task.detached(priority: .userInitiated) { Gamelist.load(from: url) }.value
        }
        return gamelists[game.system]?[game.name]
    }

    /// The same, read off the main thread (history.dat lives on the NAS).
    func loadHistorySections(for game: String) async -> [HistoryDatabase.Section]? {
        let index = historyIndex, file = master.root.appendingPathComponent("data/history.dat")
        return await Task.detached(priority: .userInitiated) { index.sections(for: game, in: file) }.value
    }

    /// A game's write-up, read from history.dat on demand.
    func historySections(for game: String) -> [HistoryDatabase.Section]? {
        historyIndex.sections(for: game, in: master.root.appendingPathComponent("data/history.dat"))
    }

    func loadEmulators(_ machine: Machine) async {
        do {
            emulators[machine.id] = try await ServiceClient(host: machine.host, port: machine.servicePort).emulators()
            emulatorErrors[machine.id] = nil
        } catch {
            emulatorErrors[machine.id] = Self.describeNetwork(error)
        }
    }

    /// URLSession errors in plain words; "not connected" on a LAN host usually means macOS is blocking Local Network access.
    nonisolated static func describeNetwork(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost:
                return "cannot connect (if this app was just installed, allow it under System Settings > Privacy & Security > Local Network)"
            case .timedOut: return "timed out"
            default: return e.localizedDescription
            }
        }
        return describeInstall(error)
    }

    /// Why Add is unavailable for this machine and system, or nil when it can be added.
    func cannotAdd(to machine: Machine, system: String) -> String? {
        guard let e = emulators[machine.id] else { return "\(machine.name): \(emulatorErrors[machine.id] ?? "checking...")" }
        return e.cannotInstallReason(system: system, machine: machine.name)
    }

    func add(game: GameInfo, to machine: Machine, system: String, emulator: String?) async {
        let key = "\(machine.name)/\(game.id)"
        addStatus[key] = "Copying..."
        do {
            let installer = Installer(machine: machine, shell: SSHShell(target: machine.sshTarget),
                                      service: ServiceClient(host: machine.host, port: machine.servicePort), master: master, database: nil)
            let report = try await installer.add(game: game.name, system: system, emulator: emulator, romSets: game.romSets, sourcePath: game.sourcePath)
            addStatus[key] = "Added (\(report.emulator), \(report.romSets.count) ROM set\(report.romSets.count == 1 ? "" : "s"))"
            await refreshInventory(machine)
            if machine.frontend == .emulationStation { await syncGamelist(machine, only: [game.id]) }
        } catch {
            addStatus[key] = "Failed: " + Self.describeInstall(error)
        }
    }

    func removePlan(game: String, system: String, from machine: Machine, options: RemovalOptions) async throws -> RemovalPlan {
        try await ServiceClient(host: machine.host, port: machine.servicePort).removeGame(system: system, name: game, options: options, dryRun: true)
    }

    func remove(game: String, system: String, from machine: Machine, options: RemovalOptions) async -> String {
        let key = "\(machine.name)/\(game)"
        do {
            let plan = try await ServiceClient(host: machine.host, port: machine.servicePort).removeGame(system: system, name: game, options: options, dryRun: false)
            await refreshInventory(machine)
            removeStatus[key] = "Removed \((plan.removed ?? []).count) file\((plan.removed ?? []).count == 1 ? "" : "s")"
        } catch {
            removeStatus[key] = "Failed: " + Self.describeInstall(error)
        }
        return removeStatus[key] ?? ""
    }

    /// Changes a system's default emulator on the cabinet (the service keeps a .bak of the config), then re-reads the cabinet.
    func setDefaultEmulator(_ emulator: String, system: String, on machine: Machine) async -> String {
        do {
            let r = try await ServiceClient(host: machine.host, port: machine.servicePort).setDefaultEmulator(system: system, emulator: emulator, dryRun: false)
            await loadEmulators(machine); await refreshInventory(machine)
            return r.changed ? "\(system) now defaults to \(emulator)" : "\(system) already defaulted to \(emulator)"
        } catch { return "Failed: " + Self.describeInstall(error) }
    }

    /// Pins one installed game to an emulator, or clears its pin with nil.
    func pinEmulator(_ emulator: String?, game: String, system: String, on machine: Machine) async -> String {
        do {
            let r = try await ServiceClient(host: machine.host, port: machine.servicePort).pinEmulator(system: system, game: game, emulator: emulator, dryRun: false)
            await refreshInventory(machine)
            return r.changed ? (emulator.map { "\(game) now runs with \($0)" } ?? "\(game) uses the system default again") : "Nothing to change"
        } catch { return "Failed: " + Self.describeInstall(error) }
    }

    /// Fills EmulationStation's game list for the games installed on a cabinet (title, year, maker, description, and whatever art is
    /// there) without overwriting anything the list already has. `only` limits it to a few catalog keys, e.g. a game just added.
    @discardableResult
    func syncGamelist(_ machine: Machine, only: Set<String>? = nil) async -> String {
        guard case .loaded(let inventory) = inventories[machine.id] ?? .idle else { return "Failed: the cabinet's games are not loaded yet" }
        let catalog: GameCatalog? = { if case .loaded(let c) = self.catalog { return c }; return nil }()
        let master = self.master, index = historyIndex
        let historyFile = master.root.appendingPathComponent("data/history.dat")
        let service = ServiceClient(host: machine.host, port: machine.servicePort)
        gamelistBusy.insert(machine.id)
        defer { gamelistBusy.remove(machine.id) }
        do {
            let groups = await Task.detached(priority: .userInitiated) { () -> [(system: String, games: [[String: String]])] in
                var lists: [String: [String: GamelistEntry]] = [:]
                return GamelistSync.entries(inventory: inventory, catalog: catalog, only: only,
                    description: { GamelistSync.shortDescription(index.text(for: $0.name, in: historyFile)) },
                    scraped: { system, name in
                        if lists[system] == nil { lists[system] = Gamelist.load(from: master.root.appendingPathComponent("roms/other-systems/\(system)/gamelist.xml")) }
                        return lists[system]?[name]
                    })
            }.value
            var added = 0, updated = 0
            for group in groups {
                var start = 0
                while start < group.games.count {
                    let batch = Array(group.games[start..<min(group.games.count, start + GamelistSync.batchSize)])
                    let r = try await service.upsertGamelist(system: group.system, games: batch, autoMedia: true, onlyMissing: true)
                    added += r.added; updated += r.updated
                    start += GamelistSync.batchSize
                }
            }
            let note = added + updated == 0 ? "Game list already up to date" : "Game list: \(added) added, \(updated) filled in"
            gamelistStatus[machine.id] = machine.frontend == .emulationStation && added + updated > 0 ? note + ". Restart EmulationStation to see it." : note
        } catch {
            gamelistStatus[machine.id] = "Failed: " + Self.describeInstall(error)
        }
        return gamelistStatus[machine.id] ?? ""
    }

    /// Restarts EmulationStation (or rebuilds Attract-Mode's lists) so newly added games show up. Never done automatically.
    /// Returns false when a game is running so the caller can offer to force it.
    @discardableResult
    func restartFrontend(_ machine: Machine, force: Bool = false) async -> Bool {
        frontendBusy.insert(machine.id)
        defer { frontendBusy.remove(machine.id) }
        do {
            let r = try await ServiceClient(host: machine.host, port: machine.servicePort).restartFrontend(force: force)
            frontendStatus[machine.id] = r.errors.isEmpty ? r.message : "Failed: " + r.errors.joined(separator: "; ")
        } catch ServiceError.http(409) {
            frontendStatus[machine.id] = "A game is running on \(machine.name)"
            return false
        } catch {
            frontendStatus[machine.id] = "Failed: " + Self.describeInstall(error)
        }
        return true
    }

    /// Installs and activates the matching theme (dll-arcade for EmulationStation, rink for Attract-Mode) on the machine.
    @discardableResult
    func installTheme(_ machine: Machine) async -> Bool {
        themeBusy.insert(machine.id)
        defer { themeBusy.remove(machine.id) }
        themeStatus[machine.id] = "Installing theme on \(machine.name)..."
        let installer = ThemeInstaller(
            machine: machine,
            shell: SSHShell(target: machine.sshTarget),
            service: ServiceClient(host: machine.host, port: machine.servicePort)
        )
        do {
            let report = try await installer.install(activate: true, restartFrontend: false)
            themeStatus[machine.id] = report.message
            return true
        } catch {
            themeStatus[machine.id] = "Failed: " + Self.describeInstall(error)
            return false
        }
    }

    nonisolated static func describeInstall(_ error: Error) -> String {
        switch error {
        case InstallError.noEmulatorInstalled(let m, let s): return "\(m) has no emulator installed for \(s)"
        case InstallError.emulatorNotInstalled(let m, let e): return "\(e) is not installed on \(m)"
        case InstallError.missingRomSet(let s): return "ROM set \(s) is missing from the master"
        case InstallError.unknownGame(let g): return "\(g) is not in the MAME database"
        case ServiceError.http(let code): return "service answered \(code)"
        default: return describe(error)
        }
    }

    /// Re-reads every cabinet's score files, downloading and decoding only the ones whose MD5 changed, and keeps the result on
    /// disk. Unreachable cabinets keep their last known scores. Safe to call at any time; overlapping calls are ignored.
    func refreshScores() async {
        guard !scoresRefreshing else { return }
        scoresRefreshing = true
        defer { scoresRefreshing = false }
        if case .loaded = scores {} else { scores = .loading }
        let machines = settings.machines
        let master = self.master
        let decoderCache = self.decoderCache
        var cache = (scoreCache ?? ScoreCache(entries: [], collectedAt: Date())).keeping(machines: Set(machines.map(\.name)))
        let before = cache
        let java = self.javaPath()
        let result = await Task.detached { () -> (ScoreCache, [String], Bool) in
            let decoder = decoderCache.decoder(for: master, java: java)
            var working = before, failures: [String] = []
            for m in machines {
                do {
                    let collector = ScoreCollector(service: ServiceClient(host: m.host, port: m.servicePort), decoder: decoder)
                    working = working.replacing(machine: m.name, with: try await collector.collect(machine: m.name, previous: working.entries(for: m.name)))
                } catch { failures.append("\(m.name): \(Self.describeNetwork(error))") }
            }
            return (ScoreCache(entries: working.entries, collectedAt: Date()), failures, decoder != nil)
        }.value
        cache = result.0
        scoreCache = cache
        try? ScoreCache.save(cache)
        let unified = UnifiedScores(entries: cache.entries)
        scores = .loaded(unified)
        scoresCollectedAt = cache.collectedAt
        var notes = result.1.map { "\($0) (showing last known scores)" }
        if !result.2 { notes.append("Score decoder not found in the master (tools/hi2txt), so tables cannot be shown") }
        scoresNote = notes.isEmpty ? nil : notes.joined(separator: "; ")
        if selectedScoreGame == nil { selectedScoreGame = unified.games.first { unified.best(for: $0) != nil } }
    }

    /// Starts the background refresh: once now, then every `interval` while the app is open. Calling it again does nothing.
    func startBackgroundScores(interval: Duration = .seconds(600)) {
        guard backgroundScores == nil else { return }
        backgroundScores = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshScores()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// What a sync would write, from the scores collected so far. Nothing is written.
    func previewSync() {
        guard case .loaded(let unified) = scores else { return }
        syncResults = nil
        syncPlan = ScoreSyncPlanner.plan(unified)
    }

    func applySync() async {
        guard let plan = syncPlan, !plan.items.isEmpty else { return }
        syncRunning = true
        var writers: [String: ScoreWriter] = [:]
        for m in settings.machines { writers[m.name] = ServiceClient(host: m.host, port: m.servicePort) }
        let runner = ScoreSyncRunner(writers: writers)
        let results = await runner.apply(plan)
        syncResults = results
        syncPlan = nil
        syncRunning = false
        if results.contains(where: { $0.error == nil }) {
            lastScoreSync = Date()
            UserDefaults.standard.set(lastScoreSync, forKey: "lastScoreSync")
        }
        await refreshScores()
    }

    func javaPath() -> String {
        let custom = settings.javaPath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty && FileManager.default.isExecutableFile(atPath: custom) { return custom }
        return JavaLocator.path()
    }

    func testConnection(_ machine: Machine) async {
        connectionStatus[machine.id] = "Testing..."
        if let health = try? await ServiceClient(host: machine.host, port: machine.servicePort).health(), health.ok {
            connectionStatus[machine.id] = "Reachable (service \(health.version))"
            return
        }
        do {
            _ = try await SSHShell(target: machine.sshTarget).run("echo ok")
            connectionStatus[machine.id] = "Reachable over SSH; service not running"
        } catch {
            connectionStatus[machine.id] = "Unreachable: " + Self.describe(error)
        }
    }

    func addMachine() {
        var n = settings.machines.count + 1
        while settings.machines.contains(where: { $0.name.lowercased() == "machine\(n)" }) { n += 1 }
        settings.machines.append(Machine(name: "machine\(n)", user: "pi", host: "host.lan", frontend: .emulationStation))
        selectedMachineID = settings.machines.last?.id
    }

    func removeMachine(_ machine: Machine) {
        settings.machines.removeAll { $0.id == machine.id }
        inventories[machine.id] = nil
        inventorySources[machine.id] = nil
        providers[machine.id] = nil
        rebuildInstalledIndex()
        if selectedMachineID == machine.id { selectedMachineID = settings.machines.first?.id }
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case RemoteError.commandFailed(_, let stderr): return stderr.isEmpty ? "command failed" : stderr
        case ProcessError.timedOut: return "timed out"
        default: return "\(error)"
        }
    }
}
