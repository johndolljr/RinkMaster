import SwiftUI
import RinkMasterCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("SETTINGS").font(Rink.title(40)).foregroundStyle(Rink.red).shadow(color: Rink.red.opacity(0.8), radius: 10)

                    card(title: "MASTER COLLECTION") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                TextField("Master path", text: $model.settings.masterPath).textFieldStyle(RinkFieldStyle())
                                Button("CHOOSE...") { chooseMasterFolder() }
                                    .buttonStyle(RinkButtonStyle(tint: Rink.teal))
                                let path = model.settings.masterPath.trimmingCharacters(in: .whitespaces)
                                let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
                                Chip(text: path.isEmpty ? "NOT CONFIGURED" : (exists ? "MOUNTED" : "NOT FOUND"),
                                     tint: path.isEmpty ? Rink.lavender : (exists ? Rink.teal : Rink.red))
                            }
                            Text("Root directory of the master collection containing roms, artwork, and data.")
                                .font(Rink.bebas(16)).foregroundStyle(Rink.lavender)
                        }
                    }

                    card(title: "ARCADE BRANDING") {
                        VStack(alignment: .leading, spacing: 10) {
                            row("ARCADE NAME") { TextField("arcade title", text: $model.settings.arcadeTitle).textFieldStyle(RinkFieldStyle()) }
                            row("SUBTITLE") { TextField("location or subtitle", text: $model.settings.arcadeSubtitle).textFieldStyle(RinkFieldStyle()) }
                            row("YEAR / TAG") { TextField("year or tagline", text: $model.settings.arcadeYear).textFieldStyle(RinkFieldStyle()) }
                        }
                    }

                    card(title: "EMULATOR OVERRIDES (OPTIONAL)") {
                        VStack(alignment: .leading, spacing: 10) {
                            row("RETROARCH") {
                                HStack(spacing: 8) {
                                    TextField("Default: /Applications/RetroArch.app", text: $model.settings.retroArchPath).textFieldStyle(RinkFieldStyle())
                                    Button("CHOOSE...") { chooseRetroArchApp() }.buttonStyle(RinkButtonStyle(tint: Rink.teal))
                                }
                            }
                            row("JAVA PATH") {
                                HStack(spacing: 8) {
                                    TextField("Default: auto-detect", text: $model.settings.javaPath).textFieldStyle(RinkFieldStyle())
                                    Button("CHOOSE...") { chooseJavaBinary() }.buttonStyle(RinkButtonStyle(tint: Rink.teal))
                                }
                            }
                        }
                    }

                    ForEach($model.settings.machines) { $machine in
                        card(title: machine.name.uppercased()) {
                            VStack(alignment: .leading, spacing: 10) {
                                row("NAME") { TextField("name", text: $machine.name).textFieldStyle(RinkFieldStyle()) }
                                row("USER") { TextField("user", text: $machine.user).textFieldStyle(RinkFieldStyle()) }
                                row("HOST") { TextField("host", text: $machine.host).textFieldStyle(RinkFieldStyle()) }
                                row("ROMS") { TextField("roms path", text: $machine.romsPath).textFieldStyle(RinkFieldStyle()) }
                                row("SERVICE PORT") { TextField("port", value: $machine.servicePort, format: .number.grouping(.never)).textFieldStyle(RinkFieldStyle()).frame(maxWidth: 140) }
                                row("FRONTEND") {
                                    HStack(spacing: 10) {
                                        ForEach([(FrontendType.attractMode, "ATTRACT-MODE"), (.emulationStation, "EMULATIONSTATION")], id: \.0) { type, label in
                                            Button { machine.frontend = type } label: {
                                                Text(label).font(Rink.bebas(20))
                                                    .foregroundStyle(machine.frontend == type ? .white : Rink.amber.opacity(0.75))
                                                    .padding(.horizontal, 16).padding(.vertical, 5)
                                                    .background(Capsule().fill(machine.frontend == type ? Rink.red.opacity(0.35) : Color.clear))
                                                    .overlay(Capsule().strokeBorder(machine.frontend == type ? Rink.amber : Rink.amber.opacity(0.35), lineWidth: 2))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                HStack(spacing: 14) {
                                    Button("TEST CONNECTION") { let m = machine; Task { await model.testConnection(m) } }
                                        .buttonStyle(RinkButtonStyle())
                                    if let status = model.connectionStatus[machine.id] {
                                        Chip(text: status.uppercased(), tint: status.hasPrefix("Reachable (") ? Rink.teal : (status == "Testing..." || status.hasPrefix("Reachable over SSH") ? Rink.amber : Rink.red))
                                    }
                                    Spacer()
                                    Button("REMOVE") { let m = machine; model.removeMachine(m) }
                                        .buttonStyle(RinkButtonStyle(tint: Rink.red))
                                }
                                if let problem = machine.validationError {
                                    Text(Self.describe(problem)).font(Rink.bebas(18)).foregroundStyle(Rink.red)
                                }
                            }
                        }
                    }

                    HStack {
                        Button("ADD MACHINE") { model.addMachine() }.buttonStyle(RinkButtonStyle(tint: Rink.teal))
                        if let e = model.settings.validationError, case .duplicateName(let n) = e {
                            Text("Two machines are named '\(n)'.").font(Rink.bebas(18)).foregroundStyle(Rink.red)
                        }
                        if let saveError = model.saveError { Text(saveError).font(Rink.bebas(18)).foregroundStyle(Rink.red) }
                    }
                }
                .padding(28)
            }
            .frame(maxWidth: 860)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Rink.bungee(18)).foregroundStyle(Rink.amber)
            content()
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Rink.red.opacity(0.7), lineWidth: 2))
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Rink.bebas(20)).foregroundStyle(Rink.lavender).frame(width: 130, alignment: .leading)
            content()
        }
    }

    private func chooseMasterFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Select the folder containing your master ROM collection"
        let current = model.settings.masterPath.trimmingCharacters(in: .whitespaces)
        if !current.isEmpty && FileManager.default.fileExists(atPath: current) {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.masterPath = url.path
        }
    }

    private func chooseRetroArchApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select RetroArch.app"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.retroArchPath = url.path
        }
    }

    private func chooseJavaBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select java binary"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.javaPath = url.path
        }
    }

    private static func describe(_ e: MachineValidationError) -> String {
        switch e {
        case .emptyName: return "Give the machine a name."
        case .invalidUser: return "User may only contain letters, digits, dot, dash and underscore."
        case .invalidHost: return "Host may only contain letters, digits, dot, dash and underscore."
        case .duplicateName(let n): return "Another machine is already named '\(n)'."
        }
    }
}
