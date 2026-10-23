import Foundation

public struct PlayerResult: Equatable, Sendable {
    public let game: String
    public let rank: Int
    public let score: Int
    public let machine: String
    public let core: String
}

public struct PlayerStanding: Equatable, Sendable {
    public let name: String
    public let points: Int
    public let firstPlaces: Int
    public let games: [PlayerResult]
}

/// Ranks the people behind the initials: each player's best score per game (across every cabinet and core) is ranked
/// against the others in that game, and a placement earns points (1st = 10 down to 10th = 1).
public enum PlayerRankings {
    public static func points(forRank rank: Int) -> Int { max(0, 11 - rank) }

    /// Factory-default initials such as AAA, A.A, N.N or "...": no letters at all, or a single letter repeated.
    public static func isPlaceholder(_ name: String) -> Bool {
        let letters = name.filter(\.isLetter)
        if letters.isEmpty { return true }
        return letters.count >= 2 && Set(letters).count == 1
    }

    public static func build(from scores: UnifiedScores, machine: String? = nil) -> [PlayerStanding] {
        var results: [String: [PlayerResult]] = [:]
        for game in scores.games {
            var best: [String: (score: Int, machine: String, core: String)] = [:]
            for entry in scores.entries(for: game) where machine == nil || entry.machine == machine {
                guard let table = entry.table, let nameCol = table.columns.firstIndex(of: "NAME"),
                      let scoreCol = table.columns.firstIndex(of: "SCORE") else { continue }
                for row in table.rows where row.indices.contains(nameCol) && row.indices.contains(scoreCol) {
                    let name = row[nameCol].trimmingCharacters(in: .whitespaces).uppercased()
                    guard !name.isEmpty, !isPlaceholder(name), let score = Int(row[scoreCol].filter(\.isNumber)) else { continue }
                    if best[name] == nil || score > best[name]!.score { best[name] = (score, entry.machine, entry.file.core) }
                }
            }
            let ordered = best.sorted { $0.value.score != $1.value.score ? $0.value.score > $1.value.score : $0.key < $1.key }
            var rank = 0, lastScore = Int.min
            for (i, item) in ordered.enumerated() {
                if item.value.score != lastScore { rank = i + 1; lastScore = item.value.score }  // ties share a rank
                results[item.key, default: []].append(PlayerResult(game: game, rank: rank, score: item.value.score, machine: item.value.machine, core: item.value.core))
            }
        }
        return results.map { name, games in
            PlayerStanding(name: name, points: games.reduce(0) { $0 + points(forRank: $1.rank) }, firstPlaces: games.filter { $0.rank == 1 }.count,
                           games: games.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.game < $1.game })
        }
        .sorted { a, b in
            if a.points != b.points { return a.points > b.points }
            if a.firstPlaces != b.firstPlaces { return a.firstPlaces > b.firstPlaces }
            return a.name < b.name
        }
    }
}
