import Foundation

/// One planned write: replace `to`'s score file for a game with the best file (from `from`).
public struct ScoreSyncItem: Equatable, Sendable {
    public let game: String
    public let core: String
    public let from: String
    public let to: String
    public let winnerScore: Int
    public let currentScore: Int
    public let data: Data

    public init(game: String, core: String, from: String, to: String, winnerScore: Int, currentScore: Int, data: Data) {
        self.game = game; self.core = core; self.from = from; self.to = to
        self.winnerScore = winnerScore; self.currentScore = currentScore; self.data = data
    }

    /// Path under the machine's ROM folder, e.g. `mame-libretro/mame2003/hi/tempest.hi`.
    public var relativePath: String { "\(core)/hi/\(game).hi" }

    public var summary: String { "\(game): \(from) (\(winnerScore)) -> \(to) (\(currentScore)) [\(core)]" }
}

public struct ScoreSyncPlan: Equatable, Sendable {
    public let items: [ScoreSyncItem]
    public init(items: [ScoreSyncItem]) { self.items = items }
}

/// Decides which score files to overwrite. Only strictly lower, decodable `.hi` files on the same core are replaced;
/// a machine without a file for the game, an NVRAM image, or an unreadable file is left alone.
public enum ScoreSyncPlanner {
    public static func plan(_ scores: UnifiedScores) -> ScoreSyncPlan {
        var items: [ScoreSyncItem] = []
        for game in scores.games {
            for core in scores.cores(for: game) {
                guard let winner = scores.best(for: game, core: core), winner.file.kind == "hi",
                      let winnerData = winner.data, let winnerScore = winner.topScore else { continue }
                for e in scores.entries(for: game) where e.file.core == core && e.file.kind == "hi" && e.machine != winner.machine {
                    guard let current = e.topScore, current < winnerScore, e.data != winnerData else { continue }
                    items.append(ScoreSyncItem(game: game, core: core, from: winner.machine, to: e.machine,
                                               winnerScore: winnerScore, currentScore: current, data: winnerData))
                }
            }
        }
        return ScoreSyncPlan(items: items.sorted { ($0.game, $0.to, $0.core) < ($1.game, $1.to, $1.core) })
    }
}

public struct ScoreSyncResult: Equatable, Sendable {
    public let item: ScoreSyncItem
    /// nil on success.
    public let error: String?
}

/// Where a replaced score file goes. The cabinet service does the write (it owns the files and keeps the backup).
public protocol ScoreWriter: Sendable {
    /// Replaces an existing `.hi` file; returns the name of the backup kept beside it.
    func replace(core: String, game: String, with data: Data) async throws -> String
}

extension ServiceClient: ScoreWriter {
    public func replace(core: String, game: String, with data: Data) async throws -> String {
        struct Reply: Decodable { let backup: String }
        let raw = try await sendRaw("PUT", "v1/scores/file", query: [URLQueryItem(name: "core", value: core), URLQueryItem(name: "kind", value: "hi"),
                                                                    URLQueryItem(name: "game", value: game)], body: data)
        do { return try JSONDecoder().decode(Reply.self, from: raw).backup } catch { throw ServiceError.decoding("\(error)") }
    }
}

/// Applies a plan, one file at a time. A failure is recorded and the rest continue.
public struct ScoreSyncRunner: Sendable {
    private let writers: [String: ScoreWriter]

    public init(writers: [String: ScoreWriter]) { self.writers = writers }

    public func dryRun(_ plan: ScoreSyncPlan) -> [String] { plan.items.map(\.summary) }

    public func apply(_ plan: ScoreSyncPlan) async -> [ScoreSyncResult] {
        var results: [ScoreSyncResult] = []
        for item in plan.items {
            guard let writer = writers[item.to] else { results.append(ScoreSyncResult(item: item, error: "\(item.to) is not configured")); continue }
            do {
                _ = try await writer.replace(core: item.core, game: item.game, with: item.data)
                results.append(ScoreSyncResult(item: item, error: nil))
            } catch ServiceError.http(let code) {
                results.append(ScoreSyncResult(item: item, error: "service answered \(code)"))
            } catch {
                results.append(ScoreSyncResult(item: item, error: "\(error)"))
            }
        }
        return results
    }
}

public enum ScoreSyncSchedule {
    /// The app only reminds; it never syncs in the background.
    public static func isDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= 7 * 86_400
    }
}
