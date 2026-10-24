import SwiftUI
import RinkMasterCore

struct MachinesView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRestart = false
    @State private var gameRunning = false
    @State private var managingEmulators = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            machinePicker
            if let machine = model.selectedMachine {
                header(machine)
                ForEach([model.frontendStatus[machine.id], model.gamelistStatus[machine.id], model.themeStatus[machine.id]].compactMap { $0 }, id: \.self) { status in
                    Text(status.uppercased()).font(Rink.bebas(20)).foregroundStyle(status.hasPrefix("Failed") || status.hasPrefix("A game") ? Rink.red : Rink.teal)
                }
                content(machine)
            } else {
                PlaceholderView(title: "NO MACHINES", note: "Add a machine in Settings.")
            }
        }
        .padding(28)
        .task(id: model.selectedMachineID) {
            guard let machine = model.selectedMachine else { return }
            if case .idle = model.inventories[machine.id] ?? .idle { await model.refreshInventory(machine) }
        }
    }

    private var machinePicker: some View {
        HStack(spacing: 14) {
            ForEach(model.settings.machines) { m in
                Button { model.selectedMachineID = m.id } label: {
                    if m.id == model.selectedMachineID {
                        SelectionPill { Text(m.name.uppercased()).font(Rink.bebas(30)).foregroundStyle(.white) }
                    } else {
                        Text(m.name.uppercased()).font(Rink.bebas(26)).foregroundStyle(Rink.amber.opacity(0.75)).padding(.horizontal, 12)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func header(_ machine: Machine) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.name.uppercased()).font(Rink.title(40)).foregroundStyle(Rink.red)
                        .shadow(color: Rink.red.opacity(0.8), radius: 10)
                        .lineLimit(1)
                    Text("\(machine.user)@\(machine.host)  -  \(machine.frontend == .attractMode ? "ATTRACT-MODE" : "EMULATIONSTATION")")
                        .font(Rink.bebas(20)).foregroundStyle(Rink.teal)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 20)

                if case .loaded(let inv) = model.inventories[machine.id] ?? .idle {
                    HStack(spacing: 12) {
                        Text("\(inv.totalGames) GAMES").font(Rink.bungee(22)).foregroundStyle(Rink.amber).lineLimit(1)
                        switch model.inventorySources[machine.id] {
                        case .service(let cached): Chip(text: cached ? "SERVICE  CACHED" : "SERVICE")
                        case .ssh: Chip(text: "SSH  SERVICE OFFLINE", tint: Rink.amber)
                        case nil: EmptyView()
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                Button("REFRESH") { Task { await model.refreshInventory(machine) } }
                    .buttonStyle(RinkButtonStyle())
            }

            HStack(spacing: 12) {
                Button(machine.frontend == .emulationStation ? "RESTART EMULATIONSTATION" : "REBUILD GAME LISTS") {
                    if machine.frontend == .emulationStation { confirmRestart = true }
                    else { Task { await model.restartFrontend(machine) } }
                }
                .buttonStyle(RinkButtonStyle(tint: Rink.teal)).disabled(model.frontendBusy.contains(machine.id))

                if machine.frontend == .emulationStation {
                    Button("SYNC GAME LIST") { Task { await model.syncGamelist(machine) } }
                        .buttonStyle(RinkButtonStyle(tint: Rink.teal)).disabled(model.gamelistBusy.contains(machine.id))
                }

                Button("INSTALL THEME") { Task { await model.installTheme(machine) } }
                    .buttonStyle(RinkButtonStyle(tint: Rink.teal)).disabled(model.themeBusy.contains(machine.id))

                Button("EMULATORS") { managingEmulators = true }.buttonStyle(RinkButtonStyle(tint: Rink.teal))

                Spacer()
            }
        }
        .sheet(isPresented: $managingEmulators) { EmulatorsSheet(machine: machine) }
        .confirmationDialog("Restart EmulationStation on \(machine.name)?", isPresented: $confirmRestart) {
            Button("Restart") { Task { gameRunning = !(await model.restartFrontend(machine)) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The screen goes back to the start for a few seconds and the new games are listed.") }
        .confirmationDialog("A game is running on \(machine.name)", isPresented: $gameRunning) {
            Button("Restart anyway", role: .destructive) { Task { await model.restartFrontend(machine, force: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Restarting EmulationStation will end it.") }
    }

    @ViewBuilder private func content(_ machine: Machine) -> some View {
        switch model.inventories[machine.id] ?? .idle {
        case .idle, .loading:
            VStack { ProgressView().controlSize(.large).tint(Rink.amber); Text("READING \(machine.name.uppercased())...").font(Rink.bebas(24)).foregroundStyle(Rink.lavender) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Text("CAN'T REACH \(machine.name.uppercased())").font(Rink.bungee(26)).foregroundStyle(Rink.red)
                Text(message).font(Rink.bebas(22)).foregroundStyle(Rink.lavender)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let inventory):
            MachineGamesView(machine: machine, inventory: inventory)
        }
    }
}

extension InstalledGame: Identifiable { public var id: String { "\(system)/\(name)" } }

struct RemoveGameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let machine: Machine
    let game: InstalledGame
    @State private var art = true
    @State private var saves = false
    @State private var scores = false
    @State private var plan: LoadState<RemovalPlan> = .loading
    @State private var outcome: String?
    @State private var working = false

    private var options: RemovalOptions { RemovalOptions(art: art, saves: saves, scores: scores) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("REMOVE \(game.name.uppercased())").font(Rink.bungee(26)).foregroundStyle(Rink.red)
            Text("FROM \(machine.name.uppercased()) ONLY. THE MASTER IS NEVER TOUCHED.").font(Rink.bebas(20)).foregroundStyle(Rink.teal)
            StripeBand().scaleEffect(y: 0.6)
            Toggle("ARTWORK AND VIDEO", isOn: $art)
            Toggle("SAVE STATES", isOn: $saves)
            Toggle("HIGH SCORE FILES", isOn: $scores)
            Text("FILES THAT WILL BE DELETED").font(Rink.bebas(20)).foregroundStyle(Rink.amber)
            ScrollView {
                switch plan {
                case .idle, .loading: ProgressView().tint(Rink.amber)
                case .failed(let m): Text(m).foregroundStyle(Rink.red)
                case .loaded(let p):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(p.remove, id: \.self) { Text($0).font(.system(size: 14, design: .monospaced)).foregroundStyle(.white) }
                        if p.pin { Text("+ its per-game emulator choice").font(.system(size: 14, design: .monospaced)).foregroundStyle(Rink.amber) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 150).padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5)))
            if let outcome { Text(outcome.uppercased()).font(Rink.bebas(22)).foregroundStyle(outcome.hasPrefix("Failed") ? Rink.red : Rink.teal) }
            HStack {
                Spacer()
                Button(outcome == nil ? "CANCEL" : "CLOSE") { dismiss() }.buttonStyle(RinkButtonStyle(tint: Rink.lavender))
                if outcome == nil {
                    Button("REMOVE") {
                        working = true
                        Task { outcome = await model.remove(game: game.name, system: game.system, from: machine, options: options); working = false }
                    }
                    .buttonStyle(RinkButtonStyle(tint: Rink.red)).disabled(working || { if case .loaded = plan { return false } else { return true } }())
                }
            }
        }
        .toggleStyle(.checkbox).font(Rink.bebas(22)).foregroundStyle(Rink.amber)
        .padding(26).frame(width: 640)
        .background(RinkBackground())
        .task(id: options) {
            plan = .loading
            do { plan = .loaded(try await model.removePlan(game: game.name, system: game.system, from: machine, options: options)) }
            catch { plan = .failed(AppModel.describeInstall(error)) }
        }
    }
}


/// Every system on a cabinet with its emulators: which are installed and which one runs games by default. Picking another
/// installed emulator changes that system's default (the cabinet service keeps a backup of the config first).
struct EmulatorsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let machine: Machine
    @State private var status: String?
    @State private var showEmpty = false

    private var systems: [MachineEmulators.System] {
        let all = model.emulators[machine.id]?.systems ?? []
        return showEmpty ? all : all.filter { s in s.hasInstalledEmulator && inventoryCount(s.name) > 0 || s.emulators.count > 1 && s.hasInstalledEmulator }
    }

    private func inventoryCount(_ system: String) -> Int {
        if case .loaded(let inv) = model.inventories[machine.id] ?? .idle { return inv.systems.first { $0.name == system }?.games.count ?? 0 }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EMULATORS ON \(machine.name.uppercased())").font(Rink.bungee(26)).foregroundStyle(Rink.red)
            Text("PICK A SYSTEM'S DEFAULT. GAMES PINNED TO ANOTHER EMULATOR KEEP THEIR PIN.").font(Rink.bebas(18)).foregroundStyle(Rink.teal)
            StripeBand().scaleEffect(y: 0.6)
            Toggle("INCLUDE SYSTEMS WITH NO GAMES", isOn: $showEmpty).toggleStyle(.checkbox).font(Rink.bebas(18)).foregroundStyle(Rink.amber)
            if let error = model.emulatorErrors[machine.id], model.emulators[machine.id] == nil {
                Text(error).font(Rink.bebas(20)).foregroundStyle(Rink.red)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(systems, id: \.name) { system in row(system) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 380)
            if let status { Text(status.uppercased()).font(Rink.bebas(20)).foregroundStyle(status.hasPrefix("Failed") ? Rink.red : Rink.teal) }
            HStack { Spacer(); Button("CLOSE") { dismiss() }.buttonStyle(RinkButtonStyle(tint: Rink.lavender)) }
        }
        .padding(26).frame(width: 720)
        .background(RinkBackground())
        .task { await model.loadEmulators(machine) }
    }

    private func row(_ system: MachineEmulators.System) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(system.name.uppercased()).font(Rink.bebas(24)).foregroundStyle(.white)
                Text("\(inventoryCount(system.name)) GAMES").font(Rink.bebas(16)).foregroundStyle(Rink.lavender)
            }.frame(width: 190, alignment: .leading)
            Menu {
                ForEach(system.emulators.filter(\.installed), id: \.id) { e in
                    Button(e.id + (e.id == system.defaultEmulator ? "  (DEFAULT)" : "")) {
                        Task { status = await model.setDefaultEmulator(e.id, system: system.name, on: machine) }
                    }
                }
            } label: { Text("DEFAULT: \((system.defaultEmulator ?? "NONE").uppercased())") }
                .menuStyle(.button).buttonStyle(RinkButtonStyle(tint: Rink.amber)).fixedSize().disabled(!system.hasInstalledEmulator)
            FlowChips(items: system.emulators.map { ($0.id, $0.installed) })
        }
    }
}

/// Emulator ids as small chips: teal when installed, red when the config lists one whose program is missing.
struct FlowChips: View {
    let items: [(id: String, installed: Bool)]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items, id: \.id) { Chip(text: $0.id + ($0.installed ? "" : "  MISSING"), tint: $0.installed ? Rink.teal : Rink.red).fixedSize() }
        }
    }
}
