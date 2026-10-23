import SwiftUI
import RinkMasterCore

/// A cabinet's installed games: a list on the left and, for the one picked, the same details as the Games screen
/// (art, history, where else it is installed) plus that machine's own high scores.
struct MachineGamesView: View {
    @Environment(AppModel.self) private var model
    let machine: Machine
    let inventory: MachineInventory
    @State private var selected: String?
    @State private var removing: InstalledGame?
    @State private var query = InstalledQuery()
    @State private var emulatorStatus: String?

    private var catalog: GameCatalog? { if case .loaded(let c) = model.catalog { return c }; return nil }
    private var groups: [(system: String, entries: [InstalledEntry])] { inventory.entries(matching: query, catalog: catalog) }

    var body: some View {
        let shown = groups
        let facets = inventory.facets(catalog: catalog)
        return HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 8) {
                TextField("SEARCH THIS CABINET", text: $query.game.text).textFieldStyle(RinkFieldStyle())
                filterBar(facets, shown: shown.reduce(0) { $0 + $1.entries.count })
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(shown, id: \.system) { group in section(group.system, group.entries) }
                    }
                }
            }
            .frame(width: 430)
            detail
        }
        .sheet(item: $removing) { game in RemoveGameSheet(machine: machine, game: game) }
        .task { model.startBackgroundCatalog() }
        .task { for m in model.settings.machines where model.emulators[m.id] == nil { await model.loadEmulators(m) } }
        .onAppear {  // `--select-game name` preselects a game (handy for checking the detail panel)
            if selected == nil, let name = model.selectedGameName, let g = inventory.systems.flatMap(\.games).first(where: { $0.name == name }) { selected = g.id }
        }
    }

    /// The same filters as the Games screen (they all run through `GameQuery`) plus this cabinet's system and emulator.
    private func filterBar(_ f: MachineInventory.Facets, shown: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                menu("SYSTEM", value: query.system) {
                    Button("ANY SYSTEM") { query.system = nil }
                    ForEach(f.systems, id: \.name) { s in Button("\(s.name)  (\(s.count))") { query.system = s.name } }
                }
                menu("EMULATOR", value: query.emulator) {
                    Button("ANY EMULATOR") { query.emulator = nil }
                    ForEach(f.emulators, id: \.name) { e in Button("\(e.name)  (\(e.count))") { query.emulator = e.name } }
                }
                menu("DECADE", value: query.game.decade.map { "\($0)S" }) {
                    Button("ANY DECADE") { query.game.decade = nil }
                    ForEach(f.decades, id: \.decade) { d in Button("\(d.decade)S  (\(d.count))") { query.game.decade = d.decade } }
                }
            }
            HStack(spacing: 6) {
                menu("MAKER", value: query.game.maker) {
                    Button("ANY MAKER") { query.game.maker = nil }
                    ForEach(Array(f.makers.prefix(40)), id: \.name) { m in Button("\(m.name)  (\(m.count))") { query.game.maker = m.name } }
                }
                menu("LETTER", value: query.game.letter.map { String($0) }) {
                    Button("ANY LETTER") { query.game.letter = nil }
                    ForEach(f.letters, id: \.self) { l in Button(String(l)) { query.game.letter = l } }
                }
                menu("SORT", value: query.game.sort == .title ? nil : query.game.sort.rawValue) {
                    ForEach(GameSort.allCases, id: \.self) { sort in Button(sort.rawValue) { query.game.sort = sort } }
                }
            }
            HStack(spacing: 10) {
                toggle("PINNED", isOn: $query.pinnedOnly)
                toggle("NO CLONES", isOn: $query.game.hideClones)
                toggle("ART", isOn: $query.game.requireArt)
                toggle("HISTORY", isOn: $query.game.requireHistory)
                Spacer(minLength: 0)
                Text("\(shown) / \(inventory.totalGames)").font(Rink.bebas(18)).foregroundStyle(Rink.teal).fixedSize()
                if query.isFiltering { Button("RESET") { query = InstalledQuery() }.buttonStyle(RinkButtonStyle(tint: Rink.lavender)).lineLimit(1).fixedSize() }
            }
        }
    }

    private func menu<Content: View>(_ title: String, value: String?, @ViewBuilder content: () -> Content) -> some View {
        Menu { content() } label: { Text(value.map { "\(title): \($0.uppercased())" } ?? title).lineLimit(1) }
            .menuStyle(.button).buttonStyle(RinkButtonStyle(tint: value == nil ? Rink.amber : Rink.teal)).fixedSize()
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title).font(Rink.bebas(17)).foregroundStyle(isOn.wrappedValue ? Color.white : Rink.amber.opacity(0.8))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(isOn.wrappedValue ? Rink.red.opacity(0.5) : .clear))
                .overlay(Capsule().strokeBorder(Rink.amber.opacity(isOn.wrappedValue ? 0.9 : 0.4), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func section(_ name: String, _ list: [InstalledEntry]) -> some View {
        let system = inventory.systems.first { $0.name == name }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(name.uppercased()).font(Rink.bungee(18)).foregroundStyle(Rink.amber).lineLimit(1).fixedSize()
                Text("\(list.count)").font(Rink.bebas(20)).foregroundStyle(.white)
                ForEach(Dictionary(grouping: list, by: { $0.game.emulator ?? "(none)" }).sorted { $0.key < $1.key }.prefix(3), id: \.key) { emu, games in
                    Chip(text: "\(emu)  \(games.count)").fixedSize()
                }
                if let d = system?.defaultEmulator { Chip(text: "DEFAULT  \(d)", tint: Rink.lavender).fixedSize() }
            }
            StripeBand().frame(maxWidth: 300).scaleEffect(y: 0.5)
            ForEach(list) { entry in row(entry) }
        }
    }

    private func row(_ entry: InstalledEntry) -> some View {
        let game = entry.game
        return HStack(spacing: 6) {
            Button { selected = game.id } label: {
                HStack(spacing: 8) {
                    Text(entry.title.uppercased()).font(Rink.bebas(21)).lineLimit(1)
                        .foregroundStyle(selected == game.id ? Color.white : Color(red: 1, green: 0.85, blue: 0.7))
                    Spacer(minLength: 4)
                    if game.isPinned { Chip(text: game.emulator ?? "", tint: Rink.amber).fixedSize() }
                    if let year = entry.info?.year, !year.isEmpty { Text(year).font(Rink.bebas(17)).foregroundStyle(Rink.amber) }
                }
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected == game.id ? Rink.red.opacity(0.35) : .clear))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { removing = game } label: { Image(systemName: "xmark.circle").font(.system(size: 15)) }
                .buttonStyle(.plain).foregroundStyle(Rink.red.opacity(0.75)).help("Remove \(game.name) from \(machine.name)")
        }
    }

    /// Which emulator runs the selected game: its pin, or the system default. Changing it pins the game (or clears the pin).
    private func emulatorBar(_ game: InstalledGame) -> some View {
        let installed = model.emulators[machine.id]?.installedEmulators(for: game.system) ?? []
        let systemDefault = inventory.systems.first { $0.name == game.system }?.defaultEmulator
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("RUNS WITH").font(Rink.bebas(20)).foregroundStyle(Rink.amber)
                Menu {
                    Button("SYSTEM DEFAULT (\(systemDefault ?? "-"))") { pin(nil, game) }
                    Divider()
                    ForEach(installed, id: \.self) { e in Button(e) { pin(e, game) } }
                } label: { Text((game.emulator ?? "NONE").uppercased() + (game.isPinned ? "  (PINNED)" : "")) }
                    .menuStyle(.button).buttonStyle(RinkButtonStyle(tint: game.isPinned ? Rink.amber : Rink.teal)).fixedSize()
                    .disabled(installed.isEmpty)
            }
            if let emulatorStatus { Text(emulatorStatus.uppercased()).font(Rink.bebas(18)).foregroundStyle(emulatorStatus.hasPrefix("Failed") ? Rink.red : Rink.teal) }
        }
    }

    private func pin(_ emulator: String?, _ game: InstalledGame) {
        Task { emulatorStatus = await model.pinEmulator(emulator, game: game.name, system: game.system, on: machine) }
    }

    @ViewBuilder private var detail: some View {
        if let id = selected, let game = inventory.systems.flatMap(\.games).first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                emulatorBar(game)
                if let info = inventory.info(for: game, in: catalog) {
                    GameDetailView(game: info, machine: machine).id(id)
                } else {
                    InstalledOnlyDetail(machine: machine, game: game).id(id)
                }
            }
        } else {
            PlaceholderView(title: "PICK A GAME", note: "Details, history and this cabinet's high scores.")
        }
    }
}

/// Games the master catalog does not know (not in the master, or an unknown ROM name); show what the cabinet knows.
struct InstalledOnlyDetail: View {
    @Environment(AppModel.self) private var model
    let machine: Machine
    let game: InstalledGame

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(game.name.uppercased()).font(Rink.title(34)).foregroundStyle(Rink.red).shadow(color: Rink.red.opacity(0.7), radius: 8)
                HStack(spacing: 10) {
                    Chip(text: game.system.uppercased(), tint: Rink.amber)
                    Chip(text: (game.emulator ?? "no emulator").uppercased())
                    Chip(text: game.file, tint: Rink.lavender)
                    if game.size > 0 { Chip(text: ByteCountFormatter.string(fromByteCount: Int64(game.size), countStyle: .file), tint: Rink.lavender) }
                }
                Text("NOT IN THE MASTER CATALOG, SO THERE IS NO ARTWORK OR HISTORY FOR IT.").font(Rink.bebas(18)).foregroundStyle(Rink.lavender)
                GameScoresSection(game: game.name, machine: machine.name)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
        }
    }
}
