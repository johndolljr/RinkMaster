import SwiftUI
import RinkMasterCore

struct HighScoresView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Text("HIGH SCORES").font(Rink.title(40)).foregroundStyle(Rink.red).shadow(color: Rink.red.opacity(0.8), radius: 10)
                if let at = model.scoresCollectedAt {
                    Text("UPDATED \(at.formatted(date: .omitted, time: .shortened))").font(Rink.bebas(20)).foregroundStyle(Rink.teal)
                }
                if model.scoresRefreshing { ProgressView().controlSize(.small).tint(Rink.amber); Text("CHECKING CABINETS").font(Rink.bebas(18)).foregroundStyle(Rink.lavender) }
                Spacer()
                Button("REFRESH NOW") { Task { await model.refreshScores() } }.buttonStyle(RinkButtonStyle()).disabled(model.scoresRefreshing)
            }
            syncBar
            if let note = model.scoresNote { Text(note.uppercased()).font(Rink.bebas(18)).foregroundStyle(Rink.amber) }
            switch model.scores {
            case .idle: PlaceholderView(title: "NOT COLLECTED YET", note: "Scores are collected in the background; press REFRESH NOW to check the cabinets.")
            case .loading:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(Rink.amber)
                    Text("READING SCORES...").font(Rink.bebas(24)).foregroundStyle(Rink.lavender)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let m): PlaceholderView(title: "COULDN'T COLLECT", note: m)
            case .loaded(let unified): content(unified)
            }
        }
        .padding(28)
        .task { model.startBackgroundCatalog() }
        .task { model.startBackgroundScores() }
    }

    @State private var confirmApply = false

    @ViewBuilder private var syncBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("SYNC").font(Rink.bungee(18)).foregroundStyle(Rink.amber)
                if model.syncDue { Chip(text: "WEEKLY SYNC DUE", tint: Rink.red) }
                else if let last = model.lastScoreSync { Chip(text: "LAST SYNC \(last.formatted(date: .abbreviated, time: .shortened))") }
                Button("PREVIEW") { model.previewSync() }.buttonStyle(RinkButtonStyle(tint: Rink.teal))
                    .disabled({ if case .loaded = model.scores { return false } else { return true } }() || model.syncRunning)
                if let plan = model.syncPlan, !plan.items.isEmpty {
                    Button("APPLY \(plan.items.count) WRITE\(plan.items.count == 1 ? "" : "S")") { confirmApply = true }
                        .buttonStyle(RinkButtonStyle(tint: Rink.red)).disabled(model.syncRunning)
                }
                if model.syncRunning { ProgressView().controlSize(.small).tint(Rink.amber) }
            }
            if let plan = model.syncPlan {
                if plan.items.isEmpty { Text("NOTHING TO SYNC: EVERY CABINET ALREADY HAS ITS BEST FILE").font(Rink.bebas(18)).foregroundStyle(Rink.teal) }
                else {
                    ScrollView { VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(plan.items.enumerated()), id: \.offset) { _, i in Text(i.summary).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white) }
                    }.frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 90).padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5)))
                }
            }
            if let results = model.syncResults {
                let failed = results.filter { $0.error != nil }
                Text(failed.isEmpty ? "SYNCED \(results.count) FILE\(results.count == 1 ? "" : "S"); PREVIOUS FILES KEPT AS .BAK" :
                        "SYNCED \(results.count - failed.count) OF \(results.count); FAILED: " + failed.map { "\($0.item.to) \($0.item.game) (\($0.error ?? ""))" }.joined(separator: "; "))
                    .font(Rink.bebas(18)).foregroundStyle(failed.isEmpty ? Rink.teal : Rink.red)
            }
        }
        .confirmationDialog("Overwrite \(model.syncPlan?.items.count ?? 0) score file(s) on the cabinets?", isPresented: $confirmApply) {
            Button("Apply (previous files are kept as .bak)", role: .destructive) { Task { await model.applySync() } }
        }
    }

    @State private var mode = CommandLine.arguments.contains("--players") ? 1 : 0  // `--players` opens on the leaderboard

    private func content(_ unified: UnifiedScores) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                tab("BY GAME", 0); tab("PLAYERS", 1)
            }
            if mode == 0 { gamesContent(unified) } else { PlayersView(unified: unified) }
        }
    }

    private func tab(_ title: String, _ value: Int) -> some View {
        Button { mode = value } label: {
            Text(title).font(Rink.bebas(24)).foregroundStyle(mode == value ? Color.white : Rink.amber.opacity(0.8))
                .padding(.horizontal, 18).padding(.vertical, 3)
                .background(Capsule().fill(mode == value ? Rink.red.opacity(0.5) : .clear))
                .overlay(Capsule().strokeBorder(Rink.amber.opacity(mode == value ? 0.9 : 0.4), lineWidth: 1.5))
        }.buttonStyle(.plain)
    }

    private func gamesContent(_ unified: UnifiedScores) -> some View {
        let withScores = unified.games.filter { unified.best(for: $0) != nil }
        let titles: [String: String] = { if case .loaded(let c) = model.catalog { return Dictionary(withScores.compactMap { n in c.game(n).flatMap { $0.isMame ? (n, $0.title) : nil } }, uniquingKeysWith: { a, _ in a }) }; return [:] }()
        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(withScores.count) GAMES WITH SCORES  -  \(unified.games.count - withScores.count) FILES NOT DECODABLE")
                    .font(Rink.bebas(18)).foregroundStyle(Rink.lavender)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(withScores, id: \.self) { game in
                            let best = unified.best(for: game)
                            Button { model.selectedScoreGame = game } label: {
                                HStack {
                                    Text((titles[game] ?? game).uppercased()).font(Rink.bebas(22)).lineLimit(1)
                                        .foregroundStyle(model.selectedScoreGame == game ? .white : Color(red: 1, green: 0.85, blue: 0.7))
                                    Spacer(minLength: 6)
                                    Text(best?.table?.rows.first.flatMap { _ in best?.topScore }.map { $0.formatted() } ?? "").font(Rink.bebas(20)).foregroundStyle(Rink.amber)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(model.selectedScoreGame == game ? Rink.red.opacity(0.35) : .clear))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(width: 380)
            if let game = model.selectedScoreGame, !unified.entries(for: game).isEmpty {
                ScoreDetail(game: game, title: titles[game] ?? game, unified: unified)
            } else {
                PlaceholderView(title: "PICK A GAME", note: "Scores from each cabinet, with the best file marked.")
            }
        }
    }
}

struct ScoreDetail: View {
    let game: String
    let title: String
    let unified: UnifiedScores

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title.uppercased()).font(Rink.title(32)).foregroundStyle(Rink.red).shadow(color: Rink.red.opacity(0.7), radius: 8)
                ForEach(Array(unified.entries(for: game).enumerated()), id: \.offset) { _, entry in
                    let isBest = unified.best(for: game, core: entry.file.core) == entry
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text(entry.machine.uppercased()).font(Rink.bungee(20)).foregroundStyle(Rink.amber).lineLimit(1).fixedSize()
                            Chip(text: entry.file.core.uppercased()).lineLimit(1).fixedSize()
                            Chip(text: entry.file.kind == "hi" ? ".HI" : ".NV", tint: Rink.lavender).fixedSize()
                            if isBest { Chip(text: "BEST", tint: Rink.amber).fixedSize() }
                        }
                        if let table = entry.table { ScoreTableView(table: table) }
                        else { Text((entry.note ?? "no scores").uppercased()).font(Rink.bebas(20)).foregroundStyle(Rink.lavender) }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.4)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isBest ? Rink.amber.opacity(0.8) : Rink.red.opacity(0.4), lineWidth: isBest ? 2 : 1))
                }
            }
            .padding(.trailing, 8)
        }
    }
}

struct ScoreTableView: View {
    let table: ScoreTable
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 2) {
            GridRow { ForEach(table.columns, id: \.self) { Text($0).font(Rink.bebas(18)).foregroundStyle(Rink.teal) } }
            ForEach(Array(table.rows.prefix(10).enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { i, cell in
                        Text(cell).font(Rink.bebas(24)).foregroundStyle(table.columns.indices.contains(i) && table.columns[i] == "SCORE" ? Rink.amber : .white)
                    }
                }
            }
        }
    }
}

/// Who is best across all the games: each initials' best score per game ranks them against the others in that game.
struct PlayersView: View {
    @Environment(AppModel.self) private var model
    let unified: UnifiedScores
    @State private var machine: String?
    @State private var selected: String?

    private var titles: [String: String] {
        if case .loaded(let c) = model.catalog { return Dictionary(c.games.filter(\.isMame).map { ($0.name, $0.title) }, uniquingKeysWith: { a, _ in a }) }
        return [:]
    }

    var body: some View {
        let standings = PlayerRankings.build(from: unified, machine: machine)
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("RANKED ON").font(Rink.bebas(18)).foregroundStyle(Rink.lavender)
                    machineButton("ALL CABINETS", nil)
                    ForEach(model.settings.machines) { m in machineButton(m.name.uppercased(), m.name) }
                }
                Text("1ST = 10 POINTS DOWN TO 10TH = 1, BEST SCORE PER PLAYER PER GAME").font(Rink.bebas(15)).foregroundStyle(Rink.lavender.opacity(0.8))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(standings.enumerated()), id: \.element.name) { index, p in
                            Button { selected = p.name } label: {
                                HStack(spacing: 10) {
                                    Text("\(index + 1)").font(Rink.bebas(22)).foregroundStyle(Rink.amber).frame(width: 34, alignment: .trailing)
                                    Text(p.name).font(Rink.bungee(20)).foregroundStyle(selected == p.name ? Color.white : Color(red: 1, green: 0.85, blue: 0.7)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(p.firstPlaces) FIRST").font(Rink.bebas(17)).foregroundStyle(Rink.teal)
                                    Text("\(p.games.count) GAMES").font(Rink.bebas(17)).foregroundStyle(Rink.lavender)
                                    Text("\(p.points) PTS").font(Rink.bebas(22)).foregroundStyle(Rink.amber).frame(width: 70, alignment: .trailing)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(selected == p.name ? Rink.red.opacity(0.35) : .clear))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if standings.isEmpty { Text("NO NAMED SCORES YET").font(Rink.bebas(20)).foregroundStyle(Rink.lavender) }
            }
            .frame(width: 470)
            if let name = selected, let player = standings.first(where: { $0.name == name }) { detail(player) }
            else { PlaceholderView(title: "PICK A PLAYER", note: "Every game they placed in, with rank and score.") }
        }
        .onAppear { if selected == nil { selected = standings.first?.name } }
    }

    private func machineButton(_ title: String, _ value: String?) -> some View {
        Button { machine = value; selected = nil } label: {
            Text(title).font(Rink.bebas(17)).foregroundStyle(machine == value ? Color.white : Rink.amber.opacity(0.8))
                .padding(.horizontal, 10).padding(.vertical, 2)
                .background(Capsule().fill(machine == value ? Rink.red.opacity(0.5) : .clear))
                .overlay(Capsule().strokeBorder(Rink.amber.opacity(machine == value ? 0.9 : 0.4), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func detail(_ p: PlayerStanding) -> some View {
        let titles = self.titles  // once, not per row
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(p.name).font(Rink.title(44)).foregroundStyle(Rink.red).shadow(color: Rink.red.opacity(0.8), radius: 10)
                HStack(spacing: 10) {
                    Chip(text: "\(p.points) POINTS", tint: Rink.amber)
                    Chip(text: "\(p.firstPlaces) FIRST PLACE\(p.firstPlaces == 1 ? "" : "S")")
                    Chip(text: "\(p.games.count) GAMES", tint: Rink.lavender)
                }
                StripeBand().frame(maxWidth: 360).scaleEffect(y: 0.6)
                ForEach(p.games, id: \.game) { r in
                    HStack(spacing: 12) {
                        Text("#\(r.rank)").font(Rink.bungee(18)).foregroundStyle(r.rank == 1 ? Rink.amber : Rink.teal).frame(width: 52, alignment: .leading)
                        Text((titles[r.game] ?? r.game).uppercased()).font(Rink.bebas(22)).foregroundStyle(.white).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(r.score.formatted()).font(Rink.bebas(24)).foregroundStyle(Rink.amber)
                        Text(r.machine.uppercased()).font(Rink.bebas(16)).foregroundStyle(Rink.lavender).frame(width: 80, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
        }
    }
}
