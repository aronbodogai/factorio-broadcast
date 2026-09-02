# factorio-broadcast

Live factory statistics out of Factorio 2.0 and onto a web page: everything the
in-game Production, Electricity and Logistics menus show, pushed once per second
to an external consumer.

Status: **the full chain works end to end** on a real Space Age save — mod →
UDP → sidecar → HTTP/SSE. The website is not built yet.

---

## Architecture

```
  WSL2 (Ubuntu 26.04)                                    Windows
  ┌──────────────────────────────────────┐
  │ factorio 2.0.77 headless (linux64)   │
  │   mod: factorio-broadcast            │
  │   samples stats every 60 ticks       │
  │            │                         │
  │            │ helpers.send_udp        │
  │            │ 127.0.0.1:41234         │
  │            │ chunked, ≤1472 B/datagram
  │            ▼                         │
  │ sidecar (Node 22, TypeScript)        │
  │   reassembles → normalises           │        browser / Cloudflare
  │   :8099 /api/stats  /api/stream ─────┼──────► (localhost forwarding)
  └──────────────────────────────────────┘
              ▲
              │ RCON 127.0.0.1:27015  (control plane: restart, probe, assert)
```

Why this shape:

- **A Factorio mod cannot open a listening socket.** The only outbound channels
  are `helpers.write_file` and `helpers.send_udp`. `send_udp` wins on latency and
  leaves no files behind, so the mod pushes and the sidecar serves.
- **`send_udp` is localhost-only**, so the sidecar must share a network namespace
  with the server. Both live in WSL2. Windows reaches the sidecar's TCP port
  through WSL2's localhost forwarding.
- **RCON is the control plane, not the data plane.** It is request/response and
  capped in command length; it is used to drive and inspect the server, not to
  ship statistics.

---

## Measured constraints

Things that cost time to find. All verified on 2.0.77.

| Constraint | Detail |
|---|---|
| `send_udp` size ceiling | **1472 bytes**, silently dropped above that. Not the loopback MTU (65536) — an internal cap. No error is raised, the datagram just never leaves. Hence the chunking protocol. |
| No Windows headless build | Wube ships headless for Linux only. The Windows binary *does* run `--start-server` headlessly, but the real dedicated build needs Linux — here, WSL2. |
| Headless tarball includes DLC | The public `factorio-headless_linux_2.0.77.tar.xz` already contains `space-age`, `quality` and `elevated-rails` data. Nothing to copy from Steam. |
| Electric stats are J/tick | `electric_network_statistics` flow counts are Joules **per tick**, the same unit as `get_max_energy_usage()` (1500 for a 90 kW drill). Watts = count × 60. Item stats, by contrast, are already per-minute. |
| Settings live in the save | Runtime-global mod settings are stored in the save file. Changing a default in `settings.lua` does nothing to an existing save, and the console cannot write them (`Settings can only be changed by the owning player or the mod that made the setting`). Use `dev.sh reset-save`. |
| WSL kills background jobs | Processes started from a `wsl.exe` invocation die when it exits. `setsid` is required, `nohup` is not enough. |
| `table_to_json` and floats | Lua serialises doubles at full precision (`2271.66666666666651508421637117862701416015625`). All numbers are scaled ×100 to integers on the wire and divided back in the sidecar. |
| `table_to_json` and lists | An empty Lua table serialises as `{}`, not `[]`. The sidecar coerces with `asArray`. |
| RCON command length | Long Lua pasted into `/silent-command` is silently rejected. Anything non-trivial goes through the mod's `remote` interface instead. |
| Factorio client squats ports | A running Factorio client holds UDP ports around 34197–34210. The dev server and sidecar use 34198 / 34200 / 41234. |

---

## Shipping it: mod vs scenario

The question is whether joining clients have to install anything. They do for a
mod, and they do not for a scenario.

| | Mod | Scenario script ("softmod") |
|---|---|---|
| Client install | **Required.** Every peer must have the identical mod; the checksum must match. Clients can auto-sync only from the mod portal, so it must be published. | **None.** The scenario script lives inside the save and is transmitted to joining clients automatically. |
| Config | `settings.lua`, with in-game settings UI | constants in the script, or a console/remote call |
| Prototypes | can add them | cannot — script stage only |
| Updating | bump version, clients re-sync | edit the save's `control.lua` and reload |

**Verified working**, not just researched — `scripts/scenario-test.sh` builds a
copy of the save whose `control.lua` calls `helpers.send_udp`, runs it against a
mod directory containing only `base`, `elevated-rails`, `quality` and
`space-age`, and taps the socket:

```
--- mods actually loaded ---
Loading mod core / base / elevated-rails / quality / space-age    (no factorio-broadcast)
--- tapping udp 41235 for 6s (no mod installed) ---
25B  ×6   →  total 6 datagrams in 6s
```

So `helpers.send_udp` works from a scenario script with no mod present. A save's
scenario script is one line by default (`require('__base__/script/freeplay/control.lua')`),
so the broadcast appends cleanly.

Recommendation: keep the logic in one file and ship it both ways — the mod for
local development (settings UI, fast reload), the scenario for any server with
real players on it. Not yet done; the mod is the only target today.

## Development pipeline

Everything runs from Windows via `wsl.exe`; the repo lives on the Windows side
and is symlinked into the server's mod directory, so an edit is live on restart.

```bash
wsl -d Ubuntu -- bash -lc 'cd /mnt/c/Users/ideku/factorio-broadcast && bash scripts/dev.sh setup'
```

| Command | Does |
|---|---|
| `dev.sh setup` | Creates the instance, symlinks `mod/`, writes `mod-list.json` and server settings, copies a save with a running factory. |
| `dev.sh start` / `stop` / `restart` | Server lifecycle. `restart` waits for RCON before returning. |
| `dev.sh wait` | Blocks until `Starting RCON interface` appears in the log. |
| `dev.sh errors` | What to grep after a change to see whether the mod loaded. |
| `dev.sh rcon '<cmd>'` | One-shot console command. |
| `dev.sh rcon-lua <file>` | Runs a Lua *file* — avoids shell quoting entirely. |
| `dev.sh sidecar` / `sidecar-stop` | Sidecar lifecycle. |
| `dev.sh reset-save` | Fresh save from the pristine source; needed after changing a setting default. |

The edit loop is **edit `mod/control.lua` → `dev.sh restart` → assert**, about
15 seconds wall clock, of which ~5 s is loading the 24 MB save.

Assertions an agent can make without a human:

```bash
bash scripts/dev.sh errors                                    # no Lua errors
bash scripts/dev.sh rcon '/silent-command rcon.print(helpers.table_to_json(remote.call("factorio-broadcast","ping")))'
curl -s http://127.0.0.1:8099/health                          # packets, snapshots, age
node scripts/udp-tap.js 41234 5                               # raw datagrams, unparsed
```

### Layout

```
mod/          the Factorio mod (info.json, control.lua, settings.lua)
sidecar/      Node 22 + TypeScript, no dependencies, no build step
scripts/      dev.sh (WSL driver), rcon.js, udp-tap.js, probe-payload.lua
dev/          gitignored: Windows-side scratch instance
~/fb/         in WSL: factorio/ (headless), node/, instance/ (save, mods, logs)
```

---

## Data contract

The mod emits one JSON object per surface plus one `meta` object per snapshot,
all sharing a tick so the sidecar can group them. Numbers on the wire are
integers scaled ×100.

`GET /api/stats` returns the assembled snapshot:

```jsonc
{
  "tick": 11991840,
  "receivedAt": 1788350648001,
  "meta": {
    "modVersion": "0.1.0", "speed": 1, "paused": false,
    "research": { "name": "atomic-bomb", "level": 1, "progress": 21.66, "queue": 1 },
    "rockets": 232, "evolution": 88.69,
    "playersOnline": 0, "players": [],
    "surfaceNames": ["nauvis", "platform-1", "platform-2", "gleba", "fulgora"]
  },
  "surfaces": {
    "nauvis": {
      "pollution": 99875,
      "items":  { "produced": { "iron-ore": 3531.83 }, "consumed": { } },  // per minute
      "fluids": { "produced": { }, "consumed": { } },
      "power": [{
        "id": 1,
        "producedW": 193200000, "consumedW": 193200000, "satisfaction": 100,
        "producersW": { "solar-panel": 193200000 },
        "consumersW": { "roboport": 45200000, "electric-furnace": 21700000 }
      }],
      "logistics": [{ "cells": 12, "bots_all": 400, "bots_idle": 380 }]
    }
  }
}
```

Also `GET /api/stream` (SSE, one frame per snapshot) and `GET /health`.

Measured: **~5.5 KB per snapshot, 8 datagrams**, for a 5-surface Space Age base
with 138 distinct items produced on nauvis. Rates come from the game's own
windowed statistics (`defines.flow_precision_index.one_minute`), so the website
never has to diff snapshots or handle counter resets.

---

## Next

- **M1** — logistics detail, per-machine status histogram, fluids on all surfaces.
- **M2** — decide history: live-only today; the game keeps its own 10 m / 1 h / 10 h
  buckets, which can be exposed instead of storing a time series.
- **M3** — Cloudflare: sidecar pushes to a Worker + Durable Object, static site on
  Pages reads from it. Needs a shared secret and a decision on what is public
  (server name and player names are the sensitive fields).
- **M4** — the website.

### Open questions

1. Which save is the real target — this dev copy, or a long-running server you
   keep up? Affects whether the sidecar needs to survive restarts.
2. Public or private page, and may player names appear on it?
3. Per-planet breakdown in the UI, or nauvis-first with the rest secondary?
4. Should the mod be published to mods.factorio.com, or stay private?
