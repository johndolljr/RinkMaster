import Foundation

public enum ServiceError: Error, Equatable {
    case http(Int)
    case badResponse
    case decoding(String)
}

public struct ServiceInventoryResponse: Equatable, Sendable {
    /// nil when the service answered 304 Not Modified.
    public let inventory: MachineInventory?
    public let etag: String?
    public var notModified: Bool { inventory == nil }
}

public struct ServiceHealth: Equatable, Sendable, Decodable {
    public let ok: Bool
    public let version: String
    public let machine: String

    public init(ok: Bool, version: String, machine: String) { self.ok = ok; self.version = version; self.machine = machine }
}

/// Talks to a cabinet's `rinkmasterd` over HTTP/JSON.
public struct ServiceClient: Sendable {
    public let baseURL: URL
    fileprivate let session: URLSession

    public init(host: String, port: Int, session: URLSession = .shared) {
        var parts = URLComponents()
        parts.scheme = "http"; parts.host = host; parts.port = port
        self.baseURL = parts.url ?? URL(string: "http://invalid.invalid")!
        self.session = session
    }

    private func get(_ path: String, etag: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 5
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.badResponse }
        return (data, http)
    }

    public func health() async throws -> ServiceHealth {
        let (data, http) = try await get("health")
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode) }
        do { return try JSONDecoder().decode(ServiceHealth.self, from: data) }
        catch { throw ServiceError.decoding("\(error)") }
    }

    public func inventory(ifNoneMatch etag: String?) async throws -> ServiceInventoryResponse {
        let (data, http) = try await get("v1/inventory", etag: etag)
        let newTag = http.value(forHTTPHeaderField: "ETag")
        switch http.statusCode {
        case 304:
            return ServiceInventoryResponse(inventory: nil, etag: newTag ?? etag)
        case 200..<300:
            do { return ServiceInventoryResponse(inventory: try JSONDecoder().decode(MachineInventory.self, from: data), etag: newTag) }
            catch { throw ServiceError.decoding("\(error)") }
        default:
            throw ServiceError.http(http.statusCode)
        }
    }
}

public struct RemovalOptions: Equatable, Sendable {
    public var art: Bool, saves: Bool, scores: Bool
    public init(art: Bool = false, saves: Bool = false, scores: Bool = false) { self.art = art; self.saves = saves; self.scores = scores }
}

public struct FrontendRefresh: Equatable, Sendable, Decodable {
    public let frontend: String
    public let refreshed: [String]
    public let errors: [String]
}

public struct FrontendRestart: Equatable, Sendable, Decodable {
    public let frontend: String
    public let restarted: Bool
    public let refreshed: [String]
    public let errors: [String]
    public let message: String
}

/// The answer to changing a system's default emulator or a game's pin.
public struct EmulatorChange: Equatable, Sendable, Decodable {
    public let system: String
    public let emulator: String?
    public let previous: String?
    public let changed: Bool
    public let dryRun: Bool
    public let file: String
    public let backup: String?
    public let game: String?
}

public struct GamelistUpsert: Equatable, Sendable, Decodable {
    public let added: Int
    public let updated: Int
    public let changed: Bool

    public init(added: Int, updated: Int, changed: Bool) { self.added = added; self.updated = updated; self.changed = changed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        updated = try c.decodeIfPresent(Int.self, forKey: .updated) ?? 0
        changed = try c.decodeIfPresent(Bool.self, forKey: .changed) ?? (added + updated > 0)
    }

    private enum CodingKeys: String, CodingKey { case added, updated, changed }
}

public struct RemovalPlan: Equatable, Sendable, Decodable {
    public let dryRun: Bool
    public let system: String
    public let name: String
    public let pin: Bool
    public let remove: [String]
    public let removed: [String]?
    public let frontend: FrontendRefresh?
}

extension ServiceClient {
    func sendRaw(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, timeout: TimeInterval = 30) async throws -> Data {
        try await send(method, path, query: query, body: body, timeout: timeout)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, timeout: TimeInterval = 30) async throws -> Data {
        var parts = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body { request.httpBody = body; request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode) }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw ServiceError.decoding("\(error)") }
    }

    public func emulators() async throws -> MachineEmulators {
        try decode(MachineEmulators.self, await send("GET", "v1/emulators", timeout: 10))
    }

    public func removeGame(system: String, name: String, options: RemovalOptions, dryRun: Bool) async throws -> RemovalPlan {
        var query: [URLQueryItem] = []
        if dryRun { query.append(URLQueryItem(name: "dryRun", value: "1")) }
        if options.art { query.append(URLQueryItem(name: "withArt", value: "1")) }
        if options.saves { query.append(URLQueryItem(name: "withSaves", value: "1")) }
        if options.scores { query.append(URLQueryItem(name: "withScores", value: "1")) }
        let data = try await send("DELETE", "v1/games/\(system)/\(name)", query: query)
        return try decode(RemovalPlan.self, data)
    }

    public func refreshFrontend(system: String) async throws -> FrontendRefresh {
        try decode(FrontendRefresh.self, await send("POST", "v1/frontend/refresh", query: [URLQueryItem(name: "system", value: system)], timeout: 120))
    }

    /// EmulationStation: restarts it so new games are listed. Attract-Mode: rebuilds every romlist. A running game makes the
    /// service answer 409 (`ServiceError.http(409)`) unless `force`.
    public func restartFrontend(force: Bool = false) async throws -> FrontendRestart {
        try decode(FrontendRestart.self, await send("POST", "v1/frontend/restart", query: force ? [URLQueryItem(name: "force", value: "1")] : [], timeout: 180))
    }

    /// Sets the system's default emulator (`default = "x"` in its emulators.cfg). The service keeps a .bak of the file.
    public func setDefaultEmulator(system: String, emulator: String, dryRun: Bool) async throws -> EmulatorChange {
        let body = try JSONSerialization.data(withJSONObject: ["system": system, "emulator": emulator])
        return try decode(EmulatorChange.self, await send("POST", "v1/emulators/default", query: dryRun ? [URLQueryItem(name: "dryRun", value: "1")] : [], body: body))
    }

    /// Pins one game to an emulator; `emulator: nil` clears the pin so the system default applies again.
    public func pinEmulator(system: String, game: String, emulator: String?, dryRun: Bool) async throws -> EmulatorChange {
        let payload: [String: Any] = ["system": system, "game": game, "emulator": emulator ?? NSNull()]
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try decode(EmulatorChange.self, await send("POST", "v1/emulators/pin", query: dryRun ? [URLQueryItem(name: "dryRun", value: "1")] : [], body: body))
    }

    /// Adds or updates games in the cabinet's EmulationStation game list for a system (merged by path, with a .bak).
    /// `autoMedia` fills each game's art from the files that exist on the cabinet; `onlyMissing` leaves values the list already has.
    @discardableResult
    public func upsertGamelist(system: String, games: [[String: String]], dryRun: Bool = false, autoMedia: Bool = false, onlyMissing: Bool = false) async throws -> GamelistUpsert {
        let payload: [String: Any] = ["system": system, "games": games, "autoMedia": autoMedia, "onlyMissing": onlyMissing]
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try decode(GamelistUpsert.self, await send("POST", "v1/gamelist", query: dryRun ? [URLQueryItem(name: "dryRun", value: "1")] : [], body: body, timeout: 120))
    }

    public func refreshInventory() async throws { _ = try await send("POST", "v1/refresh") }
}

public enum InventorySource: Equatable, Sendable {
    /// From the cabinet service; `cached` means the service said 304 and the app reused its copy.
    case service(cached: Bool)
    /// Read over SSH because the service was not reachable.
    case ssh
}

public struct LoadedInventory: Sendable {
    public let inventory: MachineInventory
    public let source: InventorySource
}

/// Prefers the cabinet service (with ETag caching) and falls back to reading over SSH.
public actor InventoryProvider {
    private let service: ServiceClient
    private let fallback: InventoryReader
    private var cache: (etag: String?, inventory: MachineInventory)?

    public init(service: ServiceClient, fallback: InventoryReader) {
        self.service = service
        self.fallback = fallback
    }

    public func load() async throws -> LoadedInventory {
        do {
            let response = try await service.inventory(ifNoneMatch: cache?.etag)
            if let inventory = response.inventory {
                cache = (response.etag, inventory)
                return LoadedInventory(inventory: inventory, source: .service(cached: false))
            }
            if let cached = cache {
                return LoadedInventory(inventory: cached.inventory, source: .service(cached: true))
            }
            throw ServiceError.badResponse  // 304 with nothing cached: treat like an unreachable service
        } catch {
            return LoadedInventory(inventory: try await fallback.read(), source: .ssh)
        }
    }
}
