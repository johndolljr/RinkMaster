import Foundation

/// The MCP tools: everything the RinkMaster app can do, for an agent. Reads are free; anything that changes a cabinet
/// is explicit (adds say what they would copy with `dry_run`, removals are a dry run unless told otherwise, and the
/// score sync only writes with `confirm: true`).
public enum RinkMasterTools {
    public static let instructions = """
    RinkMaster manages RetroPie arcade cabinets from one master collection of MAME ROMs, artwork and history.
    Start with `overview` to see what is installed where. Find games with `search_games` (filters: text, decade, maker, letter, installed=none to \
    find games no cabinet has) and read everything about one with `get_game`. `add_game` copies a game (with its parent/BIOS/device ROM sets and \
    artwork) from the master to a cabinet; it is refused unless the cabinet has an emulator for the system, and `dry_run: true` shows the plan. \
    `remove_game` deletes a cabinet's copy only (never the master) and is a dry run unless you pass `dry_run: false`. High scores are cached and \
    checked by MD5: `get_scores`, `player_rankings`, `plan_score_sync` (preview) and `apply_score_sync` (needs `confirm: true`, keeps .bak copies).
    """

    public static func make(_ ws: Workspace) -> [MCPTool] {
        machineTools(ws) + gameTools(ws) + changeTools(ws) + scoreTools(ws) + settingsTools(ws)
    }

    // MARK: helpers

    private static func table(_ t: ScoreTable?) -> JSONValue {
        guard let t else { return .null }
        return .object(["columns": .array(t.columns.map { .string($0) }), "rows": .array(t.rows.map { .array($0.map { .string($0) }) })])
    }

    private static func str(_ v: String?) -> JSONValue { v.map { .string($0) } ?? .null }

    private static func machineJSON(_ m: Machine) -> JSONValue {
        .object(["name": .string(m.name), "user": .string(m.user), "host": .string(m.host), "frontend": .string(m.frontend.rawValue),
                 "romsPath": .string(m.romsPath), "servicePort": .int(m.servicePort)])
    }

    private static func gameJSON(_ g: GameInfo, installedOn: [String]) -> JSONValue {
        .object(["id": .string(g.id), "name": .string(g.name), "title": .string(g.title), "year": .string(g.year), "maker": .string(g.maker), "cloneOf": str(g.cloneOf),
                 "system": .string(g.system), "sourcePath": str(g.sourcePath),
                 "hasHistory": .bool(g.hasHistory), "artTypes": .array(g.artTypes.map { .string($0) }), "installedOn": .array(installedOn.map { .string($0) })])
    }

    private static let filterProperties: [String: MCPProperty] = [
        "text": .string("Free text matched against title, ROM name, year and manufacturer"),
        "decade": .integer("Decade the game came out, e.g. 1980"),
        "maker": .string("Manufacturer as shown in get_game/catalog_facets, e.g. Namco"),
        "letter": .string("First letter of the title (a single letter, or # for digits and symbols)"),
        "hide_clones": .boolean("Only parent games, not clones/variants"),
        "require_art": .boolean("Only games that have artwork"),
        "require_history": .boolean("Only games with a history write-up"),
        "installed": .string("any (default), on_any (on at least one cabinet), none (on no cabinet), or a cabinet name"),
        "system": .string("Only this RetroPie system, e.g. mame, atari2600, daphne (see catalog_facets)"),
        "sort": .choice("Sort order", ["title", "year", "maker"]),
    ]

    private static func query(_ a: MCPArguments, machines: [String]) throws -> GameQuery {
        var q = GameQuery()
        q.text = a.optionalString("text") ?? ""
        if a.has("decade") { q.decade = a.int("decade", default: 0) }
        q.maker = a.optionalString("maker")
        q.system = a.optionalString("system")
        if let l = a.optionalString("letter") { q.letter = l.first.map { $0.isLetter ? Character($0.uppercased()) : "#" } }
        q.hideClones = a.bool("hide_clones", default: false)
        q.requireArt = a.bool("require_art", default: false)
        q.requireHistory = a.bool("require_history", default: false)
        switch a.optionalString("installed")?.lowercased() {
        case nil, "any": q.installed = .any
        case "on_any": q.installed = .onAnyCabinet
        case "none": q.installed = .notOnAnyCabinet
        case let name?:
            guard let m = machines.first(where: { $0.lowercased() == name }) else {
                throw MCPError("unknown 'installed' value '\(name)': use any, on_any, none or a cabinet name (\(machines.joined(separator: ", ")))")
            }
            q.installed = .onMachine(m)
        }
        if let s = a.optionalString("sort") { q.sort = GameSort(rawValue: s.uppercased()) ?? .title }
        return q
    }

    private static func installedMap(_ index: InstalledIndex, _ game: String) -> [String] { index.entries(for: game).map(\.machine) }

    private static func requireGame(_ ws: Workspace, _ name: String) async throws -> GameInfo {
        guard let g = try await ws.catalog().catalog.game(name) else { throw MCPError("no game named '\(name)' in the master catalog") }
        return g
    }

    private static func wrap<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as MCPError { throw e } catch { throw MCPError(ErrorText.describe(error)) }
    }

    // MARK: cabinets

    private static func machineTools(_ ws: Workspace) -> [MCPTool] {
        let machine = ["machine": MCPProperty.string("Cabinet name as configured in settings")]
        return [
            MCPTool(name: "overview", description: "Start here: every cabinet with its game counts per system and emulator, whether it is reachable, plus the master collection and score cache status.",
                    properties: [:], required: [], readOnly: true) { _ in try await wrap {
                let settings = try await ws.settings()
                var machines: [JSONValue] = []
                for m in settings.machines {
                    do {
                        let loaded = try await ws.inventory(m)
                        let systems: [JSONValue] = loaded.inventory.systems.map { s in
                            .object(["name": .string(s.name), "games": .int(s.games.count), "defaultEmulator": str(s.defaultEmulator),
                                     "emulators": .object(s.gamesByEmulator.mapValues { .int($0.count) })])
                        }
                        var source = "ssh"
                        if case .service = loaded.source { source = "service" }
                        machines.append(.object(["name": .string(m.name), "host": .string(m.host), "frontend": .string(m.frontend.rawValue), "reachable": true,
                                                 "source": .string(source), "totalGames": .int(loaded.inventory.totalGames), "systems": .array(systems)]))
                    } catch {
                        machines.append(.object(["name": .string(m.name), "host": .string(m.host), "reachable": false, "error": .string(ErrorText.describe(error))]))
                    }
                }
                let master = try await ws.master()
                var masterInfo: [String: JSONValue] = ["path": .string(master.root.path), "mounted": .bool(master.isAvailable)]
                if let c = try? await ws.catalog() { masterInfo["games"] = .int(c.catalog.games.count) }
                let cache = await ws.scores()
                let unified = await ws.unifiedScores()
                return .object(["machines": .array(machines), "master": .object(masterInfo),
                                "branding": .object(["title": .string(settings.arcadeTitle), "subtitle": .string(settings.arcadeSubtitle), "year": .string(settings.arcadeYear)]),
                                "scores": .object(["cachedFiles": .int(cache?.entries.count ?? 0), "gamesWithScores": .int(unified.games.filter { unified.best(for: $0) != nil }.count),
                                                   "updated": cache.map { .string(ISO8601DateFormatter().string(from: $0.collectedAt)) } ?? .null])])
            } },
            MCPTool(name: "list_machines", description: "The configured cabinets (name, host, user, frontend, ROM path, service port), master path, and arcade branding.",
                    properties: [:], required: [], readOnly: true) { _ in try await wrap {
                let s = try await ws.settings()
                return .object(["master": .string(s.masterPath), "machines": .array(s.machines.map(machineJSON)),
                                "branding": .object(["title": .string(s.arcadeTitle), "subtitle": .string(s.arcadeSubtitle), "year": .string(s.arcadeYear)])])
            } },
            MCPTool(name: "test_connection", description: "Check a cabinet: its rinkmasterd service (preferred) and plain SSH.",
                    properties: machine, required: ["machine"], readOnly: true) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                var service: [String: JSONValue] = [:], ssh: [String: JSONValue] = [:]
                do { let h = try await ws.hooks.service(m).health(); service = ["ok": .bool(h.ok), "version": .string(h.version), "machine": .string(h.machine)] }
                catch { service = ["ok": false, "error": .string(ErrorText.describe(error))] }
                do { _ = try await ws.hooks.shell(m).run("echo ok"); ssh = ["ok": true] } catch { ssh = ["ok": false, "error": .string(ErrorText.describe(error))] }
                return .object(["machine": .string(m.name), "service": .object(service), "ssh": .object(ssh)])
            } },
            MCPTool(name: "get_inventory", description: "The games installed on one cabinet, with titles and which emulator runs each.",
                    properties: machine.merging(["system": .string("Only this system, e.g. mame-libretro"), "search": .string("Only games whose name or title contains this"),
                                                 "limit": .integer("Maximum games to return (default 200)"), "refresh": .boolean("Ask the cabinet to rescan first")]) { a, _ in a },
                    required: ["machine"], readOnly: true) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                let inv = try await ws.inventory(m, refresh: a.bool("refresh", default: false)).inventory
                let titles: [String: String] = (try? await ws.catalog().catalog).map { c in Dictionary(c.games.map { ($0.name, $0.title) }, uniquingKeysWith: { x, _ in x }) } ?? [:]
                let needle = a.optionalString("search")?.lowercased()
                let sys = a.optionalString("system")
                let rows = inv.systems.filter { sys == nil || $0.name == sys }.flatMap(\.games).filter { g in
                    needle == nil || g.name.lowercased().contains(needle!) || (titles[g.name] ?? "").lowercased().contains(needle!)
                }.sorted { ($0.system, $0.name) < ($1.system, $1.name) }
                let limit = max(1, min(a.int("limit", default: 200), 2000))
                return .object(["machine": .string(m.name), "total": .int(rows.count), "returned": .int(min(limit, rows.count)),
                                "games": .array(rows.prefix(limit).map { g in
                                    .object(["system": .string(g.system), "name": .string(g.name), "title": str(titles[g.name]), "emulator": str(g.emulator), "pinned": .bool(g.isPinned)])
                                })])
            } },
            MCPTool(name: "list_emulators", description: "Which emulators are installed on a cabinet, per system. Games can only be added for a system that has one.",
                    properties: machine.merging(["system": .string("Only this system, e.g. mame-libretro")]) { a, _ in a }, required: ["machine"], readOnly: true) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                let e = try await ws.hooks.service(m).emulators()
                if let system = a.optionalString("system") {
                    return .object(["machine": .string(m.name), "system": .string(system), "installed": .array(e.installedEmulators(for: system).map { .string($0) }),
                                    "default": str(e.systems.first { $0.name == system }?.defaultEmulator), "preferred": str(e.preferredEmulator(for: system)),
                                    "canAdd": .bool(e.canInstall(system: system)), "reason": str(e.cannotInstallReason(system: system, machine: m.name))])
                }
                return .object(["machine": .string(m.name), "systems": .array(e.systems.map { s in
                    .object(["name": .string(s.name), "default": str(s.defaultEmulator), "installed": .array(s.emulators.filter(\.installed).map { .string($0.id) }), "canAdd": .bool(s.hasInstalledEmulator)])
                })])
            } },
            MCPTool(name: "refresh_inventory", description: "Make a cabinet's service rescan its ROM folders so the inventory is current.",
                    properties: machine, required: ["machine"]) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                try await ws.hooks.service(m).refreshInventory()
                let inv = try await ws.inventory(m).inventory
                return .object(["machine": .string(m.name), "totalGames": .int(inv.totalGames)])
            } },
            MCPTool(name: "refresh_frontend", description: "Rebuild a cabinet's frontend game list (Attract-Mode romlist) so added or removed games show up.",
                    properties: machine.merging(["system": .string("System to rebuild (default mame-libretro)")]) { a, _ in a }, required: ["machine"]) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                let r = try await ws.hooks.service(m).refreshFrontend(system: a.optionalString("system") ?? "mame-libretro")
                return .object(["frontend": .string(r.frontend), "refreshed": .array(r.refreshed.map { .string($0) }), "errors": .array(r.errors.map { .string($0) })])
            } },
            MCPTool(name: "set_default_emulator", description: "Change which emulator a cabinet uses by default for a system (writes default = ... in that system's emulators.cfg; the service keeps a .bak). Use list_emulators to see what is installed. DRY RUN unless you pass dry_run: false.",
                    properties: machine.merging(["system": .string("RetroPie system, e.g. mame-libretro or atari2600"), "emulator": .string("Emulator id from list_emulators, e.g. lr-mame2003"),
                                                 "dry_run": .boolean("Default true. Pass false to really change it")]) { a, _ in a },
                    required: ["machine", "system", "emulator"], destructive: true) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                let r = try await ws.hooks.service(m).setDefaultEmulator(system: try a.string("system"), emulator: try a.string("emulator"), dryRun: a.bool("dry_run", default: true))
                return .object(["machine": .string(m.name), "system": .string(r.system), "emulator": str(r.emulator), "previous": str(r.previous),
                                "changed": .bool(r.changed), "dryRun": .bool(r.dryRun), "file": .string(r.file), "backup": str(r.backup)])
            } },
            MCPTool(name: "pin_game_emulator", description: "Make one game on a cabinet always use a particular emulator (or clear the pin so the system default applies). DRY RUN unless you pass dry_run: false.",
                    properties: machine.merging(["system": .string("RetroPie system, e.g. mame-libretro"), "game": .string("Game name as installed, e.g. galaga"),
                                                 "emulator": .string("Emulator id to pin; leave out to clear the pin"), "dry_run": .boolean("Default true. Pass false to really change it")]) { a, _ in a },
                    required: ["machine", "system", "game"], destructive: true) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                let r = try await ws.hooks.service(m).pinEmulator(system: try a.string("system"), game: try a.string("game"), emulator: a.optionalString("emulator"), dryRun: a.bool("dry_run", default: true))
                return .object(["machine": .string(m.name), "system": .string(r.system), "game": str(r.game), "emulator": str(r.emulator), "previous": str(r.previous),
                                "changed": .bool(r.changed), "dryRun": .bool(r.dryRun), "file": .string(r.file), "backup": str(r.backup)])
            } },
            MCPTool(name: "sync_game_list", description: "Fill in EmulationStation's game list on a cabinet from the master (title, year, maker, description, plus any art files that exist there) so games show details instead of 'unknown'. Never overwrites values the list already has. Restart the frontend afterwards to see it. Only for EmulationStation cabinets.",
                    properties: machine, required: ["machine"]) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                guard m.frontend == .emulationStation else { throw MCPError("\(m.name) runs Attract-Mode, which has no EmulationStation game list; use refresh_frontend") }
                let inventory = try await ws.inventory(m).inventory
                let (catalog, history, historyFile) = try await ws.catalog()
                let master = try await ws.master()
                var lists: [String: [String: GamelistEntry]] = [:]
                let groups = GamelistSync.entries(inventory: inventory, catalog: catalog,
                    description: { GamelistSync.shortDescription(history.text(for: $0.name, in: historyFile)) },
                    scraped: { system, name in
                        if lists[system] == nil { lists[system] = Gamelist.load(from: master.root.appendingPathComponent("roms/other-systems/\(system)/gamelist.xml")) }
                        return lists[system]?[name]
                    })
                var added = 0, updated = 0
                var perSystem: [String: JSONValue] = [:]
                for group in groups {
                    var start = 0, sysAdded = 0, sysUpdated = 0
                    while start < group.games.count {
                        let batch = Array(group.games[start..<min(group.games.count, start + GamelistSync.batchSize)])
                        let r = try await ws.hooks.service(m).upsertGamelist(system: group.system, games: batch, autoMedia: true, onlyMissing: true)
                        sysAdded += r.added; sysUpdated += r.updated
                        start += GamelistSync.batchSize
                    }
                    added += sysAdded; updated += sysUpdated
                    perSystem[group.system] = .object(["games": .int(group.games.count), "added": .int(sysAdded), "updated": .int(sysUpdated)])
                }
                return .object(["machine": .string(m.name), "added": .int(added), "updated": .int(updated), "systems": .object(perSystem)])
            } },
            MCPTool(name: "repair_roms", description: "Find the support ROM sets (device ROMs, BIOS, parents) that games installed on a cabinet need but are missing there, which makes a game fail with 'required files are missing', and copy them from the master. DRY RUN unless you pass dry_run: false. Sets the master does not have are reported, not copied.",
                    properties: machine.merging(["dry_run": .boolean("Default true. Pass false to really copy the files")]) { a, _ in a },
                    required: ["machine"]) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                let inventory = try await ws.inventory(m, refresh: true).inventory
                let (catalog, _, _) = try await ws.catalog()
                let master = try await ws.master()
                let plan = RomRepair.plan(inventory: inventory, catalog: catalog, master: master)
                let dry = a.bool("dry_run", default: true)
                var copied: [String] = []
                if !dry {
                    let shell = ws.hooks.shell(m)
                    for item in plan {
                        guard let source = item.source else { continue }
                        let dir = "\(m.romsPath)/\(item.system)"
                        _ = try await shell.push(localPath: source.path, toRemotePath: dir + "/")
                        copied.append(item.set)
                    }
                    if !copied.isEmpty { try? await ws.hooks.service(m).refreshInventory() }
                }
                func row(_ i: RomRepair.Missing) -> JSONValue {
                    .object(["set": .string(i.set), "system": .string(i.system), "neededBy": .array(i.neededBy.map { .string($0) }),
                             "from": i.source.map { .string($0.path) } ?? .null])
                }
                return .object(["machine": .string(m.name), "dryRun": .bool(dry), "missing": .array(plan.map(row)),
                                "notInMaster": .array(plan.filter { $0.source == nil }.map { .string($0.set) }),
                                "copied": .array(copied.map { .string($0) })])
            } },
            MCPTool(name: "restart_frontend", description: "Make new games show up on a cabinet's frontend: restarts EmulationStation, or rebuilds all Attract-Mode romlists. Refused while a game is running unless force is true. Not done automatically after add_game.",
                    properties: machine.merging(["force": .boolean("Restart even if a game is running (ends the game)")]) { a, _ in a }, required: ["machine"]) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                do {
                    let r = try await ws.hooks.service(m).restartFrontend(force: a.bool("force", default: false))
                    return .object(["frontend": .string(r.frontend), "restarted": .bool(r.restarted), "refreshed": .array(r.refreshed.map { .string($0) }),
                                    "errors": .array(r.errors.map { .string($0) }), "message": .string(r.message)])
                } catch ServiceError.http(409) {
                    throw MCPError("a game is running on \(m.name); pass force: true to restart anyway")
                }
            } },
            MCPTool(name: "install_theme", description: "Install and activate the theme on an arcade cabinet (dll-arcade for EmulationStation, rink for Attract-Mode). Uses the cabinet service rinkmasterd if available, falling back to SSH/rsync.",
                    properties: machine.merging([
                        "theme": .string("Theme name (default: dll-arcade for EmulationStation, rink for Attract-Mode)"),
                        "activate": .boolean("Activate the theme after installing (default: true)"),
                        "restart": .boolean("Restart the frontend after installing (default: false)")
                    ]) { a, _ in a },
                    required: ["machine"], destructive: true) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                let installer = ThemeInstaller(machine: m, shell: ws.hooks.shell(m), service: ws.hooks.service(m))
                let report = try await installer.install(
                    theme: a.optionalString("theme"),
                    activate: a.bool("activate", default: true),
                    restartFrontend: a.bool("restart", default: false)
                )
                return .object([
                    "machine": .string(report.machine),
                    "frontend": .string(report.frontend),
                    "theme": .string(report.theme),
                    "method": .string(report.method.rawValue),
                    "activated": .bool(report.activated),
                    "files": .array(report.files.map { .string($0) }),
                    "message": .string(report.message)
                ])
            } },
            MCPTool(name: "theme_status", description: "Check installed and active themes on an arcade cabinet via its service.",
                    properties: machine, required: ["machine"], readOnly: true) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                let s = try await ws.hooks.service(m).themeStatus()
                return .object([
                    "machine": .string(m.name),
                    "frontend": .string(s.frontend),
                    "activeTheme": str(s.activeTheme),
                    "installedThemes": .array(s.installedThemes.map { .string($0) }),
                    "themesDir": .string(s.themesDir)
                ])
            } },
        ]
    }

    // MARK: games

    private static func gameTools(_ ws: Workspace) -> [MCPTool] {
        [
            MCPTool(name: "search_games", description: "Browse the master collection (30,000+ games) with filters and paging. Use installed=none to find games no cabinet has, or installed=<cabinet> for what one cabinet has.",
                    properties: filterProperties.merging(["page": .integer("Page number, from 1"), "page_size": .integer("Games per page (default 25, max 200)")]) { a, _ in a },
                    required: [], readOnly: true) { a in try await wrap {
                let machines = try await ws.settings().machines.map(\.name)
                let q = try query(a, machines: machines)
                let (catalog, _, _) = try await ws.catalog()
                let (index, failures) = try await ws.installedIndex()
                let results = catalog.query(q, installed: index)
                let pager = Pager(total: results.count, pageSize: max(1, min(a.int("page_size", default: 25), 200)))
                let page = max(1, a.int("page", default: 1)) - 1
                var out: [String: JSONValue] = ["total": .int(results.count), "page": .int(min(page, pager.pageCount - 1) + 1), "pageCount": .int(pager.pageCount),
                                                "pageSize": .int(pager.pageSize),
                                                "games": .array(results[pager.range(page: page)].map { gameJSON($0, installedOn: installedMap(index, $0.id)) })]
                if !failures.isEmpty { out["warnings"] = .object(failures.mapValues { .string("could not read inventory: \($0)") }) }
                return .object(out)
            } },
            MCPTool(name: "get_game", description: "Everything about one game: title, year, maker, parent/clone, ROM sets it needs, artwork file paths, history write-up, where it is installed, and its high-score tables.",
                    properties: ["game": .string("ROM name, e.g. galaga")], required: ["game"], readOnly: true) { a in try await wrap {
                let name = try a.string("game")
                let g = try await requireGame(ws, name)
                let master = try await ws.master()
                let (_, history, historyFile) = try await ws.catalog()
                let (index, _) = try await ws.installedIndex()
                var art: [String: JSONValue] = [:]
                for t in g.artTypes { if let u = g.isMame ? master.artURL(type: t, game: g.name) : master.otherArtURL(game: g, type: t) { art[t] = .string(u.path) } }
                let text = g.isMame ? history.text(for: g.name, in: historyFile) : master.gamelistEntry(for: g).map(\.desc)
                let scores: [JSONValue] = await ws.unifiedScores().entries(for: g.isMame ? g.name : "").map { e in
                    .object(["machine": .string(e.machine), "core": .string(e.file.core), "kind": .string(e.file.kind), "table": table(e.table), "note": str(e.note)])
                }
                var out = gameJSON(g, installedOn: []).objectValue
                out["manufacturer"] = .string(g.manufacturer)
                out["romSets"] = .array(g.romSets.map { .string($0) })
                out["art"] = .object(art)
                out["history"] = text.map { .string(String($0.prefix(6000))) } ?? .null
                out["installedOn"] = .array(index.entries(for: g.id).map { .object(["machine": .string($0.machine), "system": .string($0.system), "emulator": str($0.emulator)]) })
                out["scores"] = .array(scores)
                return .object(out)
            } },
            MCPTool(name: "random_game", description: "Pick a random game from the master, optionally within the same filters as search_games (e.g. installed=none for something new).",
                    properties: filterProperties, required: [], readOnly: true) { a in try await wrap {
                let q = try query(a, machines: try await ws.settings().machines.map(\.name))
                let (catalog, _, _) = try await ws.catalog()
                let (index, _) = try await ws.installedIndex()
                var rng = SystemRandomNumberGenerator()
                guard let g = catalog.randomGame(matching: q, installed: index, using: &rng) else { throw MCPError("no games match those filters") }
                return gameJSON(g, installedOn: installedMap(index, g.id))
            } },
            MCPTool(name: "catalog_facets", description: "What the master contains: decades, manufacturers (with counts) and the letters in use, for choosing search filters.",
                    properties: ["maker_limit": .integer("How many manufacturers to list (default 40)")], required: [], readOnly: true) { a in try await wrap {
                let (c, _, _) = try await ws.catalog()
                return .object(["total": .int(c.games.count),
                                "systems": .array(c.systems.map { .object(["name": .string($0.name), "count": .int($0.count)]) }),
                                "decades": .array(c.decades.map { .object(["decade": .int($0.decade), "count": .int($0.count)]) }),
                                "makers": .array(c.makers.prefix(max(1, a.int("maker_limit", default: 40))).map { .object(["name": .string($0.name), "count": .int($0.count)]) }),
                                "letters": .array(c.letters.map { .string(String($0)) })])
            } },
            MCPTool(name: "refresh_catalog", description: "Check the master for new or removed games, new artwork and a changed MAME database, and update the cached catalog.",
                    properties: [:], required: []) { _ in try await wrap {
                let u = try await ws.refreshCatalog()
                return .object(["games": .int(u.cache.games.count), "added": .array(u.added.map { .string($0) }), "removed": .array(u.removed.map { .string($0) }),
                                "rebuilt": .bool(u.rebuilt), "changed": .bool(u.changed)])
            } },
            MCPTool(name: "master_status", description: "Whether the master share is mounted, how many games the cached catalog has and when the score cache was last updated.",
                    properties: [:], required: [], readOnly: true) { _ in try await wrap {
                let m = try await ws.master()
                let games = try? await ws.catalog().catalog.games.count
                let cache = await ws.scores()
                return .object(["path": .string(m.root.path), "mounted": .bool(m.isAvailable), "catalogGames": games.map { .int($0) } ?? .null,
                                "scoresUpdated": cache.map { .string(ISO8601DateFormatter().string(from: $0.collectedAt)) } ?? .null])
            } },
        ]
    }

    // MARK: adding and removing

    private static func installer(_ ws: Workspace, _ m: Machine) async throws -> Installer {
        Installer(machine: m, shell: ws.hooks.shell(m), service: ws.hooks.service(m), master: try await ws.master(), database: nil)
    }

    private static func changeTools(_ ws: Workspace) -> [MCPTool] {
        [
            MCPTool(name: "add_game", description: "Copy a game from the master to a cabinet: its ROM sets (parent, BIOS, device ROMs), artwork, an emulator pin if you pick a non-default one, then refresh the frontend list. Refused unless the cabinet has an emulator installed for the system. Use dry_run to see the plan first.",
                    properties: ["machine": .string("Cabinet name"), "game": .string("ROM name, e.g. galaga; for other systems system/name, e.g. atari2600/Pitfall"), "system": .string("Target system (default mame-libretro for arcade games, the game's own system otherwise)"),
                                 "emulator": .string("Emulator to run it with (default: the system's default); must be installed"), "dry_run": .boolean("Only show what would be copied")],
                    required: ["machine", "game"]) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                let game = try await requireGame(ws, try a.string("game"))
                let system = a.optionalString("system") ?? (game.isMame ? "mame-libretro" : game.system)
                let inst = try await installer(ws, m)
                if !game.isMame, system != game.system { throw MCPError("\(game.id) is a \(game.system) game; it can only be added to the \(game.system) system") }
                if a.bool("dry_run", default: false) {
                    let p = try await inst.plan(game: game.name, system: system, emulator: a.optionalString("emulator"), romSets: game.romSets, sourcePath: game.sourcePath)
                    return .object(["dryRun": true, "plan": .object(["machine": .string(m.name), "game": .string(p.game), "system": .string(p.system), "emulator": .string(p.emulator),
                                                                    "pinsEmulator": .bool(p.pinsEmulator), "romSets": .array(p.romSets.map { .string($0) }),
                                                                    "romFiles": .array(p.romFiles.map { .string($0) }),
                                                                    "artFiles": .array(p.artFiles.map { .object(["type": .string($0.type), "path": .string($0.path)]) })])])
                }
                let r = try await inst.add(game: game.name, system: system, emulator: a.optionalString("emulator"), romSets: game.romSets, sourcePath: game.sourcePath)
                if m.frontend == .emulationStation, game.isMame {  // list it in EmulationStation with its details (non-MAME games do this inside the installer)
                    let (_, history, historyFile) = try await ws.catalog()
                    let installed = InstalledGame(system: system, name: game.name, file: game.name + ".zip", emulator: nil, isPinned: false)
                    if let entry = GamelistSync.entry(for: installed, info: game, description: GamelistSync.shortDescription(history.text(for: game.name, in: historyFile)), scraped: nil) {
                        _ = try? await ws.hooks.service(m).upsertGamelist(system: system, games: [entry], autoMedia: true, onlyMissing: true)
                    }
                }
                return .object(["dryRun": false, "added": true, "machine": .string(m.name), "game": .string(r.game), "system": .string(r.system), "emulator": .string(r.emulator),
                                "romSets": .array(r.romSets.map { .string($0) }), "frontendRefreshed": .array(r.frontendRefreshed.map { .string($0) })])
            } },
            MCPTool(name: "remove_game", description: "Delete a game from a cabinet (its ROM, and optionally artwork, saves and score files). Never touches the master. This is a DRY RUN unless you pass dry_run: false; show the user the file list before a real removal.",
                    properties: ["machine": .string("Cabinet name"), "game": .string("ROM/game name"), "system": .string("System (needed only if the game is in more than one)"),
                                 "remove_art": .boolean("Also delete artwork and video"), "remove_saves": .boolean("Also delete save states"), "remove_scores": .boolean("Also delete high-score files"),
                                 "dry_run": .boolean("Default true. Pass false to really delete")],
                    required: ["machine", "game"], destructive: true) { a in try await wrap {
                let m = try await ws.machine(try a.string("machine"))
                let name = try a.string("game")
                let inv = try await ws.inventory(m).inventory
                var matches = inv.systems.flatMap(\.games).filter { $0.name == name }
                if let s = a.optionalString("system") { matches = matches.filter { $0.system == s } }
                guard !matches.isEmpty else { throw MCPError("'\(name)' is not installed on \(m.name)") }
                guard matches.count == 1 else { throw MCPError("'\(name)' is installed under several systems on \(m.name) (\(matches.map(\.system).joined(separator: ", "))); pass 'system'") }
                let options = RemovalOptions(art: a.bool("remove_art", default: false), saves: a.bool("remove_saves", default: false), scores: a.bool("remove_scores", default: false))
                let dry = a.bool("dry_run", default: true)
                let plan = try await ws.hooks.service(m).removeGame(system: matches[0].system, name: name, options: options, dryRun: dry)
                if dry {
                    return .object(["dryRun": true, "machine": .string(m.name), "game": .string(name), "system": .string(matches[0].system),
                                    "wouldRemove": .array(plan.remove.map { .string($0) }), "pinRemoved": .bool(plan.pin),
                                    "note": "Nothing was deleted. Call again with dry_run: false to delete these files from the cabinet."])
                }
                return .object(["dryRun": false, "machine": .string(m.name), "game": .string(name), "system": .string(matches[0].system),
                                "removed": .array((plan.removed ?? []).map { .string($0) }),
                                "frontend": .array((plan.frontend?.refreshed ?? []).map { .string($0) })])
            } },
        ]
    }

    // MARK: scores

    private static func scoreTools(_ ws: Workspace) -> [MCPTool] {
        [
            MCPTool(name: "get_scores", description: "Decoded high-score tables for a game from the score cache, per cabinet and emulator core. Run refresh_scores first if you need them current.",
                    properties: ["game": .string("ROM name"), "machine": .string("Only this cabinet")], required: ["game"], readOnly: true) { a in try await wrap {
                let game = try a.string("game"), machine = a.optionalString("machine")?.lowercased()
                let entries = await ws.unifiedScores().entries(for: game).filter { machine == nil || $0.machine.lowercased() == machine }
                return .object(["game": .string(game), "scores": .array(entries.map { e in
                    .object(["machine": .string(e.machine), "core": .string(e.file.core), "kind": .string(e.file.kind), "table": table(e.table), "note": str(e.note)])
                })])
            } },
            MCPTool(name: "refresh_scores", description: "Re-read the score files on every cabinet. Only files whose MD5 changed are downloaded and decoded.",
                    properties: [:], required: []) { _ in try await wrap {
                let r = try await ws.refreshScores()
                let decoded = r.cache.entries.filter { $0.table != nil }.count
                return .object(["files": .int(r.cache.entries.count), "decoded": .int(decoded), "unreachable": .object(r.failures.mapValues { .string($0) }),
                                "decoderAvailable": .bool(r.decoderAvailable), "updated": .string(ISO8601DateFormatter().string(from: r.cache.collectedAt))])
            } },
            MCPTool(name: "player_rankings", description: "Who is best across all games: each initials' best score per game ranks them (1st = 10 points down to 10th = 1). Factory-default initials are skipped.",
                    properties: ["machine": .string("Rank only scores on this cabinet"), "player": .string("Show one player's results in every game"), "limit": .integer("Players to list (default 25)")],
                    required: [], readOnly: true) { a in try await wrap {
                let standings = PlayerRankings.build(from: await ws.unifiedScores(), machine: a.optionalString("machine"))
                if let p = a.optionalString("player")?.uppercased() {
                    guard let s = standings.first(where: { $0.name == p }) else { throw MCPError("no scores for player '\(p)'") }
                    return .object(["name": .string(s.name), "points": .int(s.points), "firstPlaces": .int(s.firstPlaces),
                                    "results": .array(s.games.map { .object(["game": .string($0.game), "rank": .int($0.rank), "score": .int($0.score), "machine": .string($0.machine)]) })])
                }
                return .object(["players": .array(standings.prefix(max(1, a.int("limit", default: 25))).enumerated().map { i, s in
                    .object(["rank": .int(i + 1), "name": .string(s.name), "points": .int(s.points), "firstPlaces": .int(s.firstPlaces), "games": .int(s.games.count)])
                })])
            } },
            MCPTool(name: "plan_score_sync", description: "Preview the weekly score sync: which cabinets would get a better score file for which game. Writes nothing.",
                    properties: [:], required: [], readOnly: true) { _ in try await wrap {
                let plan = ScoreSyncPlanner.plan(await ws.unifiedScores())
                return .object(["writes": .array(plan.items.map { i in
                    .object(["game": .string(i.game), "core": .string(i.core), "from": .string(i.from), "to": .string(i.to), "winnerScore": .int(i.winnerScore), "currentScore": .int(i.currentScore)])
                }), "note": "Based on the cached scores; run refresh_scores first for current data."])
            } },
            MCPTool(name: "apply_score_sync", description: "Perform the score sync: replace lower score files with the best ones (the old file is kept as .bak beside it). Only runs with confirm: true; preview with plan_score_sync first.",
                    properties: ["confirm": .boolean("Must be true to write to the cabinets")], required: ["confirm"], destructive: true) { a in try await wrap {
                guard a.bool("confirm", default: false) else { throw MCPError("this overwrites score files on the cabinets; call plan_score_sync, then pass confirm: true to apply") }
                let plan = ScoreSyncPlanner.plan(await ws.unifiedScores())
                var writers: [String: ScoreWriter] = [:]
                for m in try await ws.settings().machines { writers[m.name] = ws.hooks.service(m) }
                let results = await ScoreSyncRunner(writers: writers).apply(plan)
                _ = try? await ws.refreshScores()
                return .object(["synced": .int(results.filter { $0.error == nil }.count),
                                "failed": .array(results.filter { $0.error != nil }.map { .object(["game": .string($0.item.game), "to": .string($0.item.to), "error": .string($0.error ?? "")]) })])
            } },
        ]
    }

    // MARK: settings

    private static func settingsTools(_ ws: Workspace) -> [MCPTool] {
        let fields: [String: MCPProperty] = ["user": .string("SSH user (a user with write access to the ROM folders)"), "host": .string("Host name or address"),
                                             "frontend": .choice("Frontend", ["attract-mode", "emulationstation"]), "roms_path": .string("ROM folder on the cabinet"),
                                             "service_port": .integer("rinkmasterd port (default 8472)")]
        return [
            MCPTool(name: "add_machine", description: "Add a cabinet to RinkMaster's settings (the app reads settings when it starts).",
                    properties: fields.merging(["name": .string("Short unique name, e.g. arcade3")]) { a, _ in a }, required: ["name", "user", "host", "frontend"]) { a in try await wrap {
                var s = try await ws.settings()
                guard let frontend = FrontendType(rawValue: try a.string("frontend")) else { throw MCPError("frontend must be attract-mode or emulationstation") }
                let m = Machine(name: try a.string("name"), user: try a.string("user"), host: try a.string("host"), frontend: frontend,
                                romsPath: a.optionalString("roms_path") ?? "/home/pi/RetroPie/roms", servicePort: a.int("service_port", default: 8472))
                s.machines.append(m)
                try await ws.saveSettings(s)
                return .object(["added": .bool(true), "machine": machineJSON(m)])
            } },
            MCPTool(name: "update_machine", description: "Change a cabinet's settings; only the fields you pass change.",
                    properties: fields.merging(["name": .string("Cabinet to change")]) { a, _ in a }, required: ["name"]) { a in try await wrap {
                var s = try await ws.settings()
                let name = try a.string("name")
                guard let i = s.machines.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else { throw MCPError("unknown machine '\(name)'") }
                if let u = a.optionalString("user") { s.machines[i].user = u }
                if let h = a.optionalString("host") { s.machines[i].host = h }
                if let f = a.optionalString("frontend") {
                    guard let fe = FrontendType(rawValue: f) else { throw MCPError("frontend must be attract-mode or emulationstation") }
                    s.machines[i].frontend = fe
                }
                if let r = a.optionalString("roms_path") { s.machines[i].romsPath = r }
                if a.has("service_port") { s.machines[i].servicePort = a.int("service_port", default: 8472) }
                try await ws.saveSettings(s)
                return .object(["updated": .bool(true), "machine": machineJSON(s.machines[i])])
            } },
            MCPTool(name: "remove_machine", description: "Remove a cabinet from RinkMaster's settings. Does not touch the cabinet itself.",
                    properties: ["name": .string("Cabinet to remove")], required: ["name"], destructive: true) { a in try await wrap {
                var s = try await ws.settings()
                let name = try a.string("name")
                guard s.machines.contains(where: { $0.name.lowercased() == name.lowercased() }) else { throw MCPError("unknown machine '\(name)'") }
                s.machines.removeAll { $0.name.lowercased() == name.lowercased() }
                try await ws.saveSettings(s)
                return .object(["removed": .bool(true), "remaining": .array(s.machines.map { .string($0.name) })])
            } },
            MCPTool(name: "set_master_path", description: "Point RinkMaster at the master collection folder (where roms/, artwork/ and data/ live).",
                    properties: ["path": .string("Folder path to the master collection")], required: ["path"]) { a in try await wrap {
                var s = try await ws.settings()
                s.masterPath = try a.string("path")
                try await ws.saveSettings(s)
                return .object(["master": .string(s.masterPath), "mounted": .bool(MasterLibrary(root: URL(fileURLWithPath: s.masterPath)).isAvailable)])
            } },
            MCPTool(name: "set_branding", description: "Customize arcade banner branding (title name, subtitle/location, year/tagline).",
                    properties: ["title": .string("Arcade title name"),
                                 "subtitle": .string("Arcade subtitle or location"),
                                 "year": .string("Year or tagline")], required: []) { a in try await wrap {
                var s = try await ws.settings()
                if let t = a.optionalString("title") { s.arcadeTitle = t }
                if let sub = a.optionalString("subtitle") { s.arcadeSubtitle = sub }
                if let y = a.optionalString("year") { s.arcadeYear = y }
                try await ws.saveSettings(s)
                return .object(["title": .string(s.arcadeTitle), "subtitle": .string(s.arcadeSubtitle), "year": .string(s.arcadeYear)])
            } },
        ]
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue] { if case .object(let o) = self { return o }; return [:] }
}
