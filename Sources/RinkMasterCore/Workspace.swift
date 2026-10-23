import Foundation

/// Plain-words descriptions of the errors the tools can meet.
public enum ErrorText {
    public static func describe(_ error: Error) -> String {
        switch error {
        case let e as MCPError: return e.message
        case InstallError.noEmulatorInstalled(let m, let s): return "\(m) has no emulator installed for \(s)"
        case InstallError.emulatorNotInstalled(let m, let e): return "\(e) is not installed on \(m)"
        case InstallError.missingRomSet(let s): return "ROM set \(s) is missing from the master"
        case InstallError.unknownGame(let g): return "no game named '\(g)' in the master catalog"
        case ServiceError.http(let code): return "the cabinet service answered \(code)"
        case ServiceError.decoding(let why): return "unreadable answer from the cabinet service (\(why))"
        case ServiceError.badResponse: return "unreadable answer from the cabinet service"
        case RemoteError.commandFailed(_, let stderr): return stderr.isEmpty ? "remote command failed" : stderr
        case ProcessError.timedOut: return "timed out"
        case let e as URLError:
            switch e.code {
            case .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost:
                return "cannot connect (is the cabinet on, and is this app allowed local network access?)"
            case .timedOut: return "timed out"
            default: return e.localizedDescription
            }
        default: return "\(error)"
        }
    }
}

public struct WorkspacePaths: Sendable {
    public let settings: URL
    public let catalogCache: URL
    public let scoreCache: URL

    public init(settings: URL, catalogCache: URL, scoreCache: URL) { self.settings = settings; self.catalogCache = catalogCache; self.scoreCache = scoreCache }

    /// The same files the app uses, so the app and the agent see one set of settings and caches.
    public static var live: WorkspacePaths { WorkspacePaths(settings: MachineStore.defaultURL, catalogCache: CatalogCache.defaultURL, scoreCache: ScoreCache.defaultURL) }
}

/// The ways the workspace reaches the outside world, replaceable in tests.
public struct WorkspaceHooks: Sendable {
    public var service: @Sendable (Machine) -> ServiceClient
    public var shell: @Sendable (Machine) -> RemoteShell
    public var decoder: @Sendable (MasterLibrary) -> ScoreDecoder?
    public var loadDatabase: @Sendable (URL) throws -> MameDatabase

    public init(service: @escaping @Sendable (Machine) -> ServiceClient, shell: @escaping @Sendable (Machine) -> RemoteShell,
                decoder: @escaping @Sendable (MasterLibrary) -> ScoreDecoder?, loadDatabase: @escaping @Sendable (URL) throws -> MameDatabase) {
        self.service = service; self.shell = shell; self.decoder = decoder; self.loadDatabase = loadDatabase
    }

    public static let live = WorkspaceHooks(
        service: { ServiceClient(host: $0.host, port: $0.servicePort) },
        shell: { SSHShell(target: $0.sshTarget) },
        decoder: { Hi2txtDecoder.inMaster($0, java: JavaLocator.path()) },
        loadDatabase: { try MameDatabase.parse(Data(contentsOf: $0)) })
}

/// Everything the app does, without a window: settings, per-cabinet connections, the cached game catalog and score cache.
/// The MCP tools are thin wrappers over this.
public actor Workspace {
    public typealias Paths = WorkspacePaths
    public typealias Hooks = WorkspaceHooks

    public let paths: WorkspacePaths
    public let hooks: WorkspaceHooks
    private var providers: [String: (key: String, provider: InventoryProvider)] = [:]
    private var catalogCache: CatalogCache?
    private var catalogStamp: Date?
    private var scoreCache: ScoreCache?
    private var caching: (root: String, decoder: CachingDecoder)?

    public init(paths: WorkspacePaths = .live, hooks: WorkspaceHooks = .live) { self.paths = paths; self.hooks = hooks }

    // MARK: settings

    public func settings() throws -> AppSettings { try MachineStore.load(from: paths.settings) }

    public func saveSettings(_ settings: AppSettings) throws {
        if let e = settings.validationError { throw MCPError("invalid settings: \(e)") }
        try MachineStore.save(settings, to: paths.settings)
    }

    public func machine(_ name: String) throws -> Machine {
        let all = try settings().machines
        guard let m = all.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw MCPError("unknown machine '\(name)'; known machines: \(all.map(\.name).joined(separator: ", "))")
        }
        return m
    }

    public func master() throws -> MasterLibrary { MasterLibrary(root: URL(fileURLWithPath: try settings().masterPath)) }

    // MARK: cabinets

    public func inventory(_ machine: Machine, refresh: Bool = false) async throws -> LoadedInventory {
        let key = "\(machine.user)@\(machine.host):\(machine.servicePort)|\(machine.romsPath)"
        let provider: InventoryProvider
        if let existing = providers[machine.id], existing.key == key { provider = existing.provider }
        else {
            provider = InventoryProvider(service: hooks.service(machine), fallback: InventoryReader(shell: hooks.shell(machine), machine: machine))
            providers[machine.id] = (key, provider)
        }
        if refresh { try? await hooks.service(machine).refreshInventory() }
        return try await provider.load()
    }

    /// Where every game is installed, plus the reason for any cabinet that could not be read.
    public func installedIndex() async throws -> (index: InstalledIndex, failures: [String: String]) {
        let machines = try settings().machines
        var loaded: [String: MachineInventory] = [:], failures: [String: String] = [:]
        await withTaskGroup(of: (String, Result<MachineInventory, Error>).self) { group in
            for m in machines { group.addTask { (m.name, await Result { try await self.inventory(m).inventory }) } }
            for await (name, result) in group {
                switch result { case .success(let inv): loaded[name] = inv; case .failure(let e): failures[name] = ErrorText.describe(e) }
            }
        }
        return (InstalledIndex(inventories: loaded), failures)
    }

    // MARK: catalog

    private func stamp(_ url: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }

    /// The cached catalog (read from disk again if the app rewrote it); built from the master the first time.
    public func catalog() async throws -> (catalog: GameCatalog, history: HistoryIndex, historyFile: URL) {
        let master = try master()
        let historyFile = master.root.appendingPathComponent("data/history.dat")
        if let cache = catalogCache, stamp(paths.catalogCache) == catalogStamp, catalogStamp != nil {
            return (GameCatalog(games: cache.games), cache.historyIndex, historyFile)
        }
        if let cache = CatalogCache.load(from: paths.catalogCache) {
            catalogCache = cache; catalogStamp = stamp(paths.catalogCache)
            return (GameCatalog(games: cache.games), cache.historyIndex, historyFile)
        }
        let update = try await refreshCatalog()
        return (GameCatalog(games: update.cache.games), update.cache.historyIndex, historyFile)
    }

    @discardableResult
    public func refreshCatalog() async throws -> CatalogUpdate {
        let master = try master()
        guard master.isAvailable else { throw MCPError("the master share is not mounted at \(master.root.path)") }
        let previous = catalogCache ?? CatalogCache.load(from: paths.catalogCache)
        let update = try CatalogUpdater(master: master, loadDatabase: hooks.loadDatabase).refresh(previous: previous)
        if update.changed || previous == nil { try? CatalogCache.save(update.cache, to: paths.catalogCache) }
        catalogCache = update.cache; catalogStamp = stamp(paths.catalogCache)
        return update
    }

    // MARK: scores

    public func scores() -> ScoreCache? {
        if scoreCache == nil { scoreCache = ScoreCache.load(from: paths.scoreCache) }
        return scoreCache
    }

    public func unifiedScores() -> UnifiedScores { UnifiedScores(entries: scores()?.entries ?? []) }

    private func decoder(for master: MasterLibrary) -> ScoreDecoder? {
        if let c = caching, c.root == master.root.path { return c.decoder }
        guard let real = hooks.decoder(master) else { return nil }
        let cache = CachingDecoder(real)
        caching = (master.root.path, cache)
        return cache
    }

    /// Re-reads every cabinet, downloading and decoding only files whose MD5 changed; unreachable cabinets keep their last scores.
    public func refreshScores() async throws -> (cache: ScoreCache, failures: [String: String], decoderAvailable: Bool) {
        let settings = try settings()
        let master = MasterLibrary(root: URL(fileURLWithPath: settings.masterPath))
        let decoder = decoder(for: master)
        var cache = (scores() ?? ScoreCache(entries: [], collectedAt: Date())).keeping(machines: Set(settings.machines.map(\.name)))
        var failures: [String: String] = [:]
        for m in settings.machines {
            do {
                let collector = ScoreCollector(service: hooks.service(m), decoder: decoder)
                cache = cache.replacing(machine: m.name, with: try await collector.collect(machine: m.name, previous: cache.entries(for: m.name)))
            } catch { failures[m.name] = ErrorText.describe(error) }
        }
        cache = ScoreCache(entries: cache.entries, collectedAt: Date())
        try? ScoreCache.save(cache, to: paths.scoreCache)
        scoreCache = cache
        return (cache, failures, decoder != nil)
    }
}

private extension Result where Failure == Error {
    init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
