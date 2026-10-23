# RinkMaster MCP server

`rinkmaster-mcp` exposes everything the app does as MCP tools, so an agent can know the inventory, find games and add or
remove them. It is a stdio server (newline-delimited JSON-RPC, protocol 2025-06-18) built from the same package and core
code as the app. It reads the app's settings and caches (`~/Library/Application Support/RinkMaster/`), so it works
whether or not the app is open; the app and the server share one view of the catalog and the scores.

Installed with the app: `~/Applications/RinkMaster.app/Contents/MacOS/rinkmaster-mcp` (`scripts/install.sh`).

## Registering

```bash
claude mcp add --scope user rinkmaster -- ~/Applications/RinkMaster.app/Contents/MacOS/rinkmaster-mcp   # Claude Code
codex mcp add rinkmaster -- ~/Applications/RinkMaster.app/Contents/MacOS/rinkmaster-mcp                  # Codex
```

Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`) and Antigravity
(`~/.gemini/config/mcp_config.json`) take an entry under `mcpServers`: `"rinkmaster": {"command": "<path above>"}`.

## Tools (24)

| Area | Tools |
|---|---|
| Cabinets | `overview` (start here), `list_machines`, `test_connection`, `get_inventory`, `list_emulators`, `refresh_inventory`, `refresh_frontend`, `restart_frontend`, `sync_game_list`, `repair_roms` |
| Games | `search_games`, `get_game`, `random_game`, `catalog_facets`, `refresh_catalog`, `master_status` |
| Changing a cabinet | `add_game`, `remove_game`, `set_default_emulator`, `pin_game_emulator` |
| High scores | `get_scores`, `refresh_scores`, `player_rankings`, `plan_score_sync`, `apply_score_sync` |
| Settings | `add_machine`, `update_machine`, `remove_machine`, `set_master_path` |

## Safety

- The catalog covers every system in `roms/other-systems` (`system` filter on `search_games`/`random_game`, `systems` in `catalog_facets`). A non-MAME game is addressed as `system/name` (e.g. `atari2600/Pitfall`) and `add_game` copies its file or folder to that system.
- `get_game` for a non-MAME game returns its art file paths and the scraped description; `add_game` also copies its artwork (and updates EmulationStation's game list on ES cabinets).
- `set_default_emulator` and `pin_game_emulator` are dry runs unless `dry_run: false`; the cabinet service keeps a `.bak` of the config it edits.
- `add_game` copies from the master and is refused (with the reason) unless the cabinet has an emulator installed for the
  system. `dry_run: true` returns the plan: ROM sets, files, art, emulator and whether a per-game pin would be written.
- `remove_game` deletes the cabinet's copy only, never the master. It is a **dry run unless `dry_run: false`**; the dry run
  lists exactly the files that would go. Art, saves and score files are only removed when asked for.
- `apply_score_sync` overwrites score files and only runs with `confirm: true`; every replaced file is kept beside it as
  `.bak-<UTC time>`. `plan_score_sync` previews it and writes nothing.
- Settings tools edit `settings.json`; the running app reads settings at launch, so restart it to see them.

## How it stays fast

The catalog (30,000+ games) and the score cache are the app's on-disk caches (the catalog is rebuilt from the master the first
time if there is none; `refresh_catalog` checks for added or removed games). Scores are checked by MD5 per file, so
`refresh_scores` downloads and decodes only what changed. Decoding needs Java and the hi2txt files in the master
(`tools/hi2txt`, `data/hi2txt`).

## Trying it without an agent

```bash
scripts/mcp-smoke.py overview 'search_games={"text":"galaga"}' 'add_game={"machine":"arcade2","game":"bublbobl","dry_run":true}'
```
