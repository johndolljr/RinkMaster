import SwiftUI
import RinkMasterCore

struct GameBrowserView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("GAMES").font(Rink.title(40)).foregroundStyle(Rink.red).shadow(color: Rink.red.opacity(0.8), radius: 10)
                if case .loaded(let catalog) = model.catalog {
                    Text("\(results.count.formatted()) OF \(catalog.games.count.formatted()) GAMES").font(Rink.bebas(22)).foregroundStyle(Rink.teal)
                    if model.catalogRefreshing { ProgressView().controlSize(.small).tint(Rink.amber); Text("CHECKING THE MASTER").font(Rink.bebas(18)).foregroundStyle(Rink.lavender) }
                    else if let note = model.catalogNote { Text(note.uppercased()).font(Rink.bebas(18)).foregroundStyle(Rink.amber) }
                }
                Spacer()
            }
            switch model.catalog {
            case .idle, .loading:
                if model.settings.masterPath.trimmingCharacters(in: .whitespaces).isEmpty {
                    PlaceholderView(title: "MASTER PATH NOT SET", note: "Set the folder path to your master ROM collection in Settings.")
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large).tint(Rink.amber)
                        Text("READING THE MASTER...").font(Rink.bebas(24)).foregroundStyle(Rink.lavender)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .failed(let message):
                VStack(spacing: 10) {
                    Text("CAN'T READ THE MASTER").font(Rink.bungee(26)).foregroundStyle(Rink.red)
                    Text(message).font(Rink.bebas(22)).foregroundStyle(Rink.lavender)
                    Button("RETRY") { Task { await model.reloadCatalog() } }.buttonStyle(RinkButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let catalog):
                browser(catalog)
            }
        }
        .padding(28)
        .task { model.startBackgroundCatalog() }
        .task {
            for m in model.settings.machines {
                if model.emulators[m.id] == nil { await model.loadEmulators(m) }
                if case .idle = model.inventories[m.id] ?? .idle { await model.refreshInventory(m) }
            }
        }
    }

    @State private var query = GameQuery()
    @State private var results: [GameInfo] = []
    @State private var page = 0
    /// As many rows as fit, so the list never scrolls; recomputed from the window's height.
    @State private var pageSize = 18
    private static let rowStride: Double = 38
    /// Arrow keys come from a local key monitor, not SwiftUI focus: focus on a container with scroll views made the window
    /// re-run its layout pass until AppKit aborted the app.
    @State private var keyMonitor: Any?
    @State private var fitTask: Task<Void, Never>?

    private func browser(_ catalog: GameCatalog) -> some View {
        let pager = Pager(total: results.count, pageSize: pageSize)
        return HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 8) {
                TextField("SEARCH TITLE, YEAR, MAKER", text: $query.text).textFieldStyle(RinkFieldStyle())
                letterStrip(catalog)
                filterBar(catalog)
                GeometryReader { geo in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(results[pager.range(page: page)]) { game in row(game) }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .onAppear { fit(height: geo.size.height) }
                    .onChange(of: geo.size.height) { _, h in fit(height: h) }
                }
                pagerBar(pager)
            }
            .frame(width: 430)
            if let name = model.selectedGameName, let game = catalog.game(name) {
                GameDetailView(game: game).id(game.id)
            } else {
                PlaceholderView(title: "PICK A GAME", note: "Browse by letter, decade, maker or what a cabinet is missing.")
            }
        }
        .onAppear { recompute(catalog); installKeys(); model.adoptRunningGame() }
        .onDisappear { removeKeys() }
        .onChange(of: query) { _, _ in page = 0; recompute(catalog) }
        .onChange(of: model.installedIndexVersion) { _, _ in recompute(catalog) }
    }

    /// Resizes the page to the window, keeping the selected game on screen. Applied after a short pause and never inside the layout
    /// pass, so resizing the window cannot start a layout loop.
    private func fit(height: CGFloat) {
        let rows = min(80, ListNavigation.rows(forHeight: Double(height), rowHeight: Self.rowStride))
        fitTask?.cancel()
        fitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, rows != pageSize else { return }
            pageSize = rows
            let pager = Pager(total: results.count, pageSize: rows)
            if let name = model.selectedGameName, let i = results.firstIndex(where: { $0.id == name }) { page = pager.page(containing: i) }
            else { page = min(page, pager.pageCount - 1) }
        }
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // typing in the search box keeps its arrows; shortcuts with modifiers are not ours
            guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control),
                  !(event.window?.firstResponder is NSTextView) else { return event }
            switch event.keyCode {
            case 126: moveSelection(by: -1)
            case 125: moveSelection(by: 1)
            case 123: changePage(by: -1)
            case 124: changePage(by: 1)
            default: return event
            }
            return nil
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        fitTask?.cancel()
    }

    /// Up / down: the previous or next game, turning the page when the selection crosses its edge.
    private func moveSelection(by delta: Int) {
        let current = model.selectedGameName.flatMap { name in results.firstIndex(where: { $0.id == name }) }
        guard let i = ListNavigation.step(selected: current, delta: delta, count: results.count) else { return }
        model.selectedGameName = results[i].id
        page = Pager(total: results.count, pageSize: pageSize).page(containing: i)
    }

    /// Left / right: the previous or next page; the selection moves to its first game so it stays on screen.
    private func changePage(by delta: Int) {
        let pager = Pager(total: results.count, pageSize: pageSize)
        let new = ListNavigation.page(current: page, delta: delta, pageCount: pager.pageCount)
        guard new != page else { return }
        page = new
        if let first = results[pager.range(page: new)].first { model.selectedGameName = first.id }
    }

    private func recompute(_ catalog: GameCatalog) { results = catalog.query(query, installed: model.installedIndex) }

    /// ALL, #, A-Z in two evenly spaced rows that fill the column.
    private func letterStrip(_ catalog: GameCatalog) -> some View {
        let items: [(title: String, letter: Character?)] = [("ALL", nil)] + catalog.letters.map { (String($0), Optional($0)) }
        let half = (items.count + 1) / 2
        return VStack(spacing: 2) {
            ForEach([Array(items.prefix(half)), Array(items.dropFirst(half))], id: \.first?.title) { row in
                HStack(spacing: 2) {
                    ForEach(row, id: \.title) { item in
                        letterButton(item.title, selected: query.letter == item.letter) { query.letter = (item.letter != nil && query.letter == item.letter) ? nil : item.letter }
                    }
                }
            }
        }
    }

    private func letterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Rink.bebas(20)).foregroundStyle(selected ? Color.white : Rink.amber.opacity(0.85))
                .frame(maxWidth: .infinity).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Rink.red.opacity(0.55) : Color.white.opacity(0.05)))
        }.buttonStyle(.plain)
    }

    private func filterBar(_ catalog: GameCatalog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if catalog.systems.count > 1 {
                    menu("SYSTEM", value: query.system.map(Self.systemLabel)) {
                        Button("ANY SYSTEM") { query.system = nil }
                        ForEach(catalog.systems, id: \.name) { s in Button("\(Self.systemLabel(s.name))  (\(s.count.formatted()))") { query.system = s.name } }
                    }
                }
                menu("DECADE", value: query.decade.map { "\($0)S" }) {
                    Button("ANY DECADE") { query.decade = nil }
                    ForEach(catalog.decades, id: \.decade) { d in Button("\(d.decade)S  (\(d.count))") { query.decade = d.decade } }
                }
                menu("MAKER", value: query.maker) {
                    Button("ANY MAKER") { query.maker = nil }
                    ForEach(Array(catalog.makers.prefix(40)), id: \.name) { m in Button("\(m.name)  (\(m.count))") { query.maker = m.name } }
                }
                menu("SHOW", value: installedTitle) {
                    Button("ALL GAMES") { query.installed = .any }
                    Button("NOT ON ANY CABINET") { query.installed = .notOnAnyCabinet }
                    Button("ON ANY CABINET") { query.installed = .onAnyCabinet }
                    ForEach(model.settings.machines) { m in Button("ON \(m.name.uppercased())") { query.installed = .onMachine(m.name) } }
                }
                menu("SORT", value: query.sort == .title ? nil : query.sort.rawValue) {
                    ForEach(GameSort.allCases, id: \.self) { sort in Button(sort.rawValue) { query.sort = sort } }
                }
            }
            HStack(spacing: 10) {
                toggle("NO CLONES", isOn: $query.hideClones)
                toggle("ART", isOn: $query.requireArt)
                toggle("HISTORY", isOn: $query.requireHistory)
                Spacer(minLength: 0)
                Button("RANDOM") { pickRandom() }.buttonStyle(RinkButtonStyle(tint: Rink.teal)).disabled(results.isEmpty).lineLimit(1).fixedSize()
                Button("RESET") { query = GameQuery() }.buttonStyle(RinkButtonStyle(tint: Rink.lavender)).lineLimit(1).fixedSize()
            }
        }
    }

    static func systemLabel(_ system: String) -> String { system == GameInfo.mameSystem ? "MAME" : system.uppercased() }

    private var installedTitle: String? {
        switch query.installed {
        case .any: return nil
        case .notOnAnyCabinet: return "NOT ON CABINETS"
        case .onAnyCabinet: return "ON A CABINET"
        case .onMachine(let m): return "ON \(m.uppercased())"
        }
    }

    private func menu<Content: View>(_ title: String, value: String?, @ViewBuilder content: () -> Content) -> some View {
        Menu { content() } label: { Text(value.map { "\(title): \($0.uppercased())" } ?? title) }
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

    private func pickRandom() {
        var rng = SystemRandomNumberGenerator()
        guard let pick = results.randomElement(using: &rng), let index = results.firstIndex(where: { $0.id == pick.id }) else { return }
        model.selectedGameName = pick.id
        page = Pager(total: results.count, pageSize: pageSize).page(containing: index)
    }

    private func pagerBar(_ pager: Pager) -> some View {
        HStack(spacing: 10) {
            Button("FIRST") { page = 0 }.disabled(page == 0)
            Button("PREV") { page = max(0, page - 1) }.disabled(page == 0)
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Text(pager.label(page: page)).font(Rink.bebas(20)).foregroundStyle(.white)
                Text("PAGE \(min(page, pager.pageCount - 1) + 1) OF \(pager.pageCount)").font(Rink.bebas(15)).foregroundStyle(Rink.lavender)
            }
            Spacer(minLength: 0)
            Button("NEXT") { page = min(pager.pageCount - 1, page + 1) }.disabled(page >= pager.pageCount - 1)
            Button("LAST") { page = pager.pageCount - 1 }.disabled(page >= pager.pageCount - 1)
        }
        .buttonStyle(RinkButtonStyle(tint: Rink.amber))
    }

    private func row(_ game: GameInfo) -> some View {
        let on = model.installedIndex.entries(for: game.id)
        return Button { model.selectedGameName = game.id } label: {
            HStack(spacing: 8) {
                Text(game.title.uppercased()).font(Rink.bebas(22)).lineLimit(1)
                    .foregroundStyle(model.selectedGameName == game.id ? Color.white : Color(red: 1, green: 0.85, blue: 0.7))
                Spacer(minLength: 4)
                if !on.isEmpty { Text(on.map { String($0.machine.prefix(1)).uppercased() }.joined()).font(Rink.bebas(16)).foregroundStyle(Rink.teal) }
                Text(game.year).font(Rink.bebas(18)).foregroundStyle(Rink.amber)
            }
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(model.selectedGameName == game.id ? Rink.red.opacity(0.35) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    let game: GameInfo
    /// When set (opened from a machine), the high scores shown are that machine's only.
    var machine: Machine?
    /// Art locations and the history write-up are read from the NAS (listing a folder of tens of thousands of images, seeking in
    /// a 36 MB file), so they load off the main thread when the game changes instead of while the view is drawn.
    @State private var artURLs: [String: URL] = [:]
    @State private var sections: [HistoryDatabase.Section]?
    @State private var details: GamelistEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(game.title.uppercased()).font(Rink.title(34)).foregroundStyle(Rink.red).shadow(color: Rink.red.opacity(0.7), radius: 8)
                HStack(spacing: 10) {
                    if game.isMame {
                        Chip(text: game.year, tint: Rink.amber)
                        Chip(text: game.manufacturer)
                        Chip(text: "ROM  \(game.name)", tint: Rink.lavender)
                    } else {
                        Chip(text: GameBrowserView.systemLabel(game.system), tint: Rink.amber)
                        Chip(text: ((game.sourcePath ?? game.name) as NSString).lastPathComponent, tint: Rink.lavender)
                    }
                    if let parent = game.cloneOf { Chip(text: "CLONE OF \(parent)", tint: Rink.lavender) }
                }
                playBar
                art
                installed
                if game.isMame { GameScoresSection(game: game.name, machine: machine?.name) }
                historyText
                detailsText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
        }
        .task(id: game.id) {
            artURLs = [:]; sections = nil; details = nil
            let master = model.master, name = game.name, types = game.artTypes, info = game
            let loaded = await Task.detached(priority: .userInitiated) { () -> [String: URL] in
                var urls: [String: URL] = [:]
                if info.isMame {
                    for type in ["snap", "flyer", "marquee"] where types.contains(type) { urls[type] = master.artURL(type: type, game: name) }
                } else {
                    for type in GameDetailView.otherArtShown where types.contains(type) { urls[type] = master.otherArtURL(game: info, type: type) }
                }
                return urls
            }.value
            artURLs = loaded
            if game.isMame { sections = await model.loadHistorySections(for: name) } else { details = await model.loadGamelistEntry(for: game) }
        }
    }

    /// Art shown for a non-MAME game, in order; video snaps appear as a still frame.
    nonisolated static let otherArtShown = ["boxart", "snap", "wheel", "marquee", "cartart", "flyer"]

    private var art: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach((game.isMame ? ["snap", "flyer", "marquee"] : Self.otherArtShown).filter { game.artTypes.contains($0) }, id: \.self) { type in
                ArtImage(url: artURLs[type], maxPixel: 700)
                    .frame(maxWidth: type == "marquee" || type == "wheel" ? 300 : 320, maxHeight: 260)
                    .glowFrame(radius: 14)
            }
            if game.artTypes.isEmpty { Text(game.isMame ? "NO ARTWORK" : "NO ARTWORK FOR THIS SYSTEM").font(Rink.bebas(20)).foregroundStyle(Rink.lavender) }
        }
    }

    /// Play on this Mac with the emulator version that matches the ROM set.
    @ViewBuilder private var playBar: some View {
        let supported = model.localPlayer.isSupported(game)
        let running = model.playing?.id == game.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if running {
                    Button("QUIT GAME") { model.stopPlaying() }.buttonStyle(RinkButtonStyle(tint: Rink.red)).disabled(model.playPreparing)
                    Text(model.playPreparing ? (model.playing?.emulator ?? "") : "RUNNING IN \((model.playing?.emulator ?? "").uppercased())").font(Rink.bebas(16)).foregroundStyle(Rink.teal)
                } else {
                    Button("PLAY ON THIS MAC") { model.play(game) }.buttonStyle(RinkButtonStyle(tint: Rink.teal))
                        .disabled(!supported)
                    let pads = model.controllerNames
                    Text(!supported ? "NO EMULATOR FOR \(GameBrowserView.systemLabel(game.system)) HERE YET"
                         : (pads.isEmpty ? "NO CONTROLLER FOUND" : pads.joined(separator: ", ").uppercased()))
                        .font(Rink.bebas(16)).foregroundStyle(Rink.lavender)
                }
            }
            if let note = model.playNote { Text(note).font(.system(size: 12)).foregroundStyle(Rink.amber).lineLimit(4) }
        }
    }

    private var installed: some View {
        let here = model.installedIndex.entries(for: game.id)
        return VStack(alignment: .leading, spacing: 8) {
            Text("ON THE CABINETS").font(Rink.bungee(18)).foregroundStyle(Rink.amber)
            StripeBand().frame(maxWidth: 300).scaleEffect(y: 0.6)
            ForEach(model.settings.machines) { machine in
                machineRow(machine, entry: here.first { $0.machine == machine.name })
            }
        }
    }

    private func machineRow(_ machine: Machine, entry: InstalledIndex.Entry?) -> some View {
        let key = "\(machine.name)/\(game.id)"
        let system = game.isMame ? "mame-libretro" : game.system
        let blocked = model.cannotAdd(to: machine, system: system)
        let status = model.addStatus[key]
        return VStack(alignment: .leading, spacing: 4) { HStack(spacing: 12) {
            Text(machine.name.uppercased()).font(Rink.bebas(24)).foregroundStyle(.white).frame(width: 130, alignment: .leading)
            if let entry {
                Chip(text: "INSTALLED  \(entry.emulator ?? "")")
            } else if let blocked {
                Chip(text: blocked.uppercased(), tint: model.emulatorErrors[machine.id] == nil ? Rink.lavender : Rink.red).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if model.emulators[machine.id] == nil {
                    Button("RETRY") { Task { await model.loadEmulators(machine) } }.buttonStyle(RinkButtonStyle(tint: Rink.teal))
                }
            } else {
                Menu {
                    let installed = model.emulators[machine.id]?.installedEmulators(for: system) ?? []
                    let preferred = model.emulators[machine.id]?.preferredEmulator(for: system)
                    Button("DEFAULT (\(preferred ?? "-"))") { Task { await model.add(game: game, to: machine, system: system, emulator: nil) } }
                    Divider()
                    ForEach(installed, id: \.self) { e in
                        Button(e) { Task { await model.add(game: game, to: machine, system: system, emulator: e) } }
                    }
                } label: { Text("ADD TO \(machine.name.uppercased())") }
                .menuStyle(.button).buttonStyle(RinkButtonStyle()).fixedSize()
                .disabled(status == "Copying...")
            }
        }
            if let status {
                Text(status.uppercased()).font(Rink.bebas(18)).foregroundStyle(status.hasPrefix("Failed") ? Rink.red : Rink.teal)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var detailsText: some View {
        if let d = details {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if !d.genre.isEmpty { Chip(text: d.genre, tint: Rink.lavender) }
                    if !d.publisher.isEmpty { Chip(text: d.publisher, tint: Rink.lavender) }
                }
                if !d.desc.isEmpty { Text(d.desc).font(.system(size: 16)).foregroundStyle(Color(red: 1, green: 0.92, blue: 0.85)).textSelection(.enabled) }
            }
        }
    }

    @ViewBuilder private var historyText: some View {
        if let sections {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, s in
                    if !s.title.isEmpty { Text(s.title).font(Rink.bungee(16)).foregroundStyle(Rink.teal).padding(.top, 6) }
                    Text(s.body).font(.system(size: 16)).foregroundStyle(Color(red: 1, green: 0.92, blue: 0.85)).textSelection(.enabled)
                }
            }
        }
    }
}

/// Decoded high-score tables for one game, from every cabinet or just one.
struct GameScoresSection: View {
    @Environment(AppModel.self) private var model
    let game: String
    var machine: String?

    var body: some View {
        let entries = (model.unifiedScores?.entries(for: game) ?? []).filter { machine == nil || $0.machine == machine }
        let withTables = entries.filter { $0.table != nil }
        VStack(alignment: .leading, spacing: 8) {
            Text(machine.map { "HIGH SCORES ON \($0.uppercased())" } ?? "HIGH SCORES").font(Rink.bungee(18)).foregroundStyle(Rink.amber)
            StripeBand().frame(maxWidth: 300).scaleEffect(y: 0.6)
            if withTables.isEmpty {
                Text(entries.isEmpty ? "NO SCORE FILE" : (entries.first?.note ?? "NOT DECODABLE").uppercased()).font(Rink.bebas(20)).foregroundStyle(Rink.lavender)
            }
            ForEach(Array(withTables.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if machine == nil { Text(entry.machine.uppercased()).font(Rink.bungee(16)).foregroundStyle(Rink.amber).lineLimit(1).fixedSize() }
                        Chip(text: entry.file.core.uppercased()).lineLimit(1).fixedSize()
                    }
                    if let table = entry.table { ScoreTableView(table: table) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.4)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Rink.red.opacity(0.4), lineWidth: 1))
            }
        }
    }
}
