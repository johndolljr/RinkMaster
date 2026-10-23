# Architecture

## Repository Layout

```
RinkMaster/
  Package.swift                  SwiftPM: RinkMasterCore (library), RinkMaster (app executable), tests
  Sources/RinkMasterCore/        UI-free logic (testable, reusable by a future CLI/k3s job)
  Sources/RinkMaster/            SwiftUI app, theme, views
  Tests/RinkMasterCoreTests/     unit tests + fixtures
  Resources/                     fonts (Bungee, Bebas Neue; SIL OFL), theme art, generator notes
  service/                       rinkmasterd (Python) + tests + install script and systemd unit
  scripts/                       build.sh run.sh test.sh install.sh report.sh
  docs/                          ARCHITECTURE.md, PROPOSAL.md, MANUAL_TEST_PLAN.md
```

## Modules And Boundaries

**RinkMasterCore** (no UI imports):

| Module | Responsibility |
|---|---|
| `MachineStore` | Configured machines (name, host, user, frontend, mounts), master collection path, arcade branding (title, subtitle, year), and emulator path overrides. Persisted as JSON in Application Support. |
| `SSHClient` | Runs commands and file transfers on a machine by shelling out to `/usr/bin/ssh` and `rsync` (BatchMode, user keys). Protocol-based so tests use a fake. |
| `Inventory` | Reads a machine's installed games per system/emulator: ROM dirs under `~/RetroPie/roms/<system>`, per-game core pins (`emulators.cfg`), frontend lists (Attract romlist / ES gamelist). |
| `MasterLibrary` | Index of the NAS master: ROM sets by version, `extras`, `other-systems`, artwork (`artwork/best`), MAME XML + `history.dat` metadata. Cached in SQLite. |
| `GameDB` | Merged per-game record: name, description, year, manufacturer, parent/clone, history text, art paths, which sets contain it, which machines have it. |
| `Installer` | Add (copy ROM + required parents/BIOS/devices from the master, per-game core choice, art sync, frontend list update) and remove (confirmed deletion on the machine only). Reuses the `arcade-roms.py` content-matching ideas (zip member CRCs). |
| `HighScores` | Collect `.hi` files, decode via per-game definitions, build the unified table, choose the best file per game, distribute. Decoding is behind a `ScoreDecoder` protocol (hi2txt definitions first, native decoders after). |
| `Sync` | Orchestrates collect -> decode -> merge -> distribute with a dry-run mode and a log. |

**RinkMaster (app):** SwiftUI, macOS 14+. `Theme` (colors, fonts, confetti/stripe/glow components matching the cabinet
layout), views: Machines (inventory), Game Browser (master), Game Detail (info, art, scores, where installed),
High Scores, Settings (machines, master path), Sync log.

**Data flow:** machine/NAS files -> Core readers -> `GameDB`/SQLite cache -> SwiftUI views. All writes to machines go through
`Installer`/`Sync` with explicit user actions; the app never writes to the master except through an explicit adopt/import
action (later).

## Cabinet service (`service/`)

`rinkmasterd` (Python 3.9 stdlib, systemd, port 8472) runs on each cabinet. Endpoints (v1): `GET /health`,
`GET /v1/inventory` (cached, ETag), `GET /v1/games/<system>/<name>`, `GET /v1/scores` and
`GET /v1/scores/<core>/<game>` (raw `.hi`/`.nv` bytes), `POST /v1/refresh`, `DELETE /v1/games/<system>/<name>`
(`?dryRun=1`, `?withArt=1`, `?withSaves=1`). The app's `ServiceClient` (URLSession) decodes the JSON into the same
`MachineInventory` the SSH reader produces; if the service is down the app falls back to `InventoryReader`.
Emulator management (`emucfg.py`): `GET /v1/emulators` lists each system's emulator ids and default;
`POST|PUT /v1/emulators/default` body `{"system","emulator"}` rewrites `default = "<id>"` in the system's `emulators.cfg`;
`POST|PUT /v1/emulators/pin` body `{"system","game","emulator"}` (emulator `null`/`""` clears) and
`DELETE /v1/emulators/pin?system=&game=` edit the `<system>_<game> = "<id>"` line in `all/emulators.cfg`. The emulator
must be one of the system's `id = "command"` lines (400), the system must have an `emulators.cfg` (404), names are
charset-validated (400). All accept `?dryRun=1`, write `<file>.bak` first, replace the file atomically, keep other lines
and their order, are idempotent (`changed:false`, no write) and refresh the inventory cache. Responses carry
`system, [game, key,] emulator, previous, changed, dryRun, file, backup, machine`.
Copies of files to/from a cabinet still use rsync over SSH.

## MCP server (`Sources/RinkMasterMCP`)

A stdio MCP server over `RinkMasterCore`: `MCPServer` (protocol), `Workspace` (settings, per-cabinet connections, the cached catalog
and scores) and `RinkMasterTools` (24 tools). It shares the app's settings and cache files, so the two agree. See [MCP.md](MCP.md).

## Testing Architecture

- `swift test` with fixtures: sample ROM zips, `roms-manifest.tsv`, `.hi` files, MAME XML slice, `history.dat` slice.
- `SSHClient`/filesystem are protocols with in-memory fakes; no live network in unit tests.
- Coverage from `swift test --enable-code-coverage`; `scripts/test.sh` prints the summary and supports `--last`.
- UI checked by running the app (`scripts/run.sh`) and recording results in `docs/MANUAL_TEST_PLAN.md`.
