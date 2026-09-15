# factorio-broadcast

Live factory statistics out of Factorio 2.0 and onto a web page: everything the
in-game Production, Electricity and Logistics menus show, pushed once per second
to an external consumer.

Status: **the full chain works end to end** on a real Space Age save — mod →
UDP → sidecar → HTTP/SSE → dashboard, deployed at
[factorio-dash.aroncreates.com](https://factorio-dash.aroncreates.com/).

---

## Architecture

```
  WSL2 (Ubuntu 26.04)                                    Windows
  ┌──────────────────────────────────────┐
  │ factorio 2.0.77 headless (linux64)   │
  │   softmod in the save's scenario     │
  │   samples stats every 60 ticks       │
  │            │                         │
  │            │ helpers.write_file      │
  │            ▼                         │
  │   script-output/broadcast.json       │
  │   script-output/broadcast-history.json
  │            │                         │
  │            │ mtime poll, 200 ms      │
  │            ▼                         │
  │ sidecar (Node 22, TypeScript)        │
  │   normalises → serves the dashboard  │        browser / Cloudflare
  │   :8099 /  /api/stats  /api/stream ──┼──────► (localhost forwarding)
  └──────────────────────────────────────┘
              ▲
              │ RCON 127.0.0.1:27015  (control plane: restart, probe, assert)
```

Why this shape:

- **A Factorio mod cannot open a listening socket.** The only outbound channels
  are `helpers.write_file` and `helpers.send_udp`.
- **It writes files rather than pushing datagrams.** `send_udp` looks like the
  lower-latency choice and is not: it costs 8–31 ms *per call*, a fixed cost
  independent of payload size, and its silent 1472-byte ceiling forces about 17
  calls per snapshot. That blocked the game for ~140 ms every second — visible as
  a hard stutter. `write_file` moves 20 KB in 0.6–1.0 ms with no size limit.
  Switching cut a snapshot from 142 ms to 6 ms and took UPS from 43–53 back to 60.
- **RCON is the control plane, not the data plane.** It is request/response and
  capped in command length; it is used to drive and inspect the server, not to
  ship statistics.

---

## Measured constraints

Things that cost time to find. All verified on 2.0.77.

| Constraint | Detail |
|---|---|
| `send_udp` is very expensive | **8–31 ms per call**, fixed — a 10-byte datagram costs the same as a 1400-byte one. 17 calls per snapshot meant a 142 ms freeze every second. `write_file` does 20 KB in 0.6–1.0 ms. Do not use `send_udp` for anything periodic. |
| `send_udp` size ceiling | **1472 bytes**, silently dropped above that. Not the loopback MTU (65536) — an internal cap, no error raised. Combined with the per-call cost, this is what made UDP unusable: bigger payloads force more of the expensive calls. |
| `table_to_json` cost | ~8 ms per 1500-key table. Fine once a second, but it is the largest remaining cost in a snapshot. |
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

## Statistics windows, graphs and UPS

`get_flow_count` takes a `precision_index` and an optional `sample_index`, and
the docs are explicit that the samples are *"the data used to generate the
statistics graphs"* — each precision level holds **300 samples** spanning its
whole window. So the in-game graphs are readable verbatim, not approximated.

The mod reports every window named in `fb-windows` (default `5s,1m,10m,1h`;
`10h`, `50h`, `250h`, `1000h` also valid) and sends graph series for the busiest
`fb-history-items` items, one window per burst, every `fb-history-every`
snapshots. Rotating keeps the extra bandwidth flat however many windows are on.

Measured on the game thread with `LuaProfiler`, on a base with 138 produced items:

| Work | Calls | Duration |
|---|---|---|
| 138 items × 1 window | 138 | 0.18–0.21 ms |
| 138 items × all 8 windows | 1104 | 1.30–1.78 ms |
| 5 items × 300 graph samples | 1500 | 0.97–1.20 ms |

A tick is 16.67 ms at 60 UPS and sampling runs once per *second*, so all of it
together costs well under 1% of a second. Payload, not CPU, is the limit: a
snapshot with four windows plus a history burst is ~19 KB across ~16 datagrams.

The **all-time column** of the production screen costs nothing extra: it is the
*values* in `input_counts` / `output_counts`, the dictionaries already iterated
for their keys. Those are exact counts rather than rates, so they are sent
unscaled and the page formats and labels them differently — there is no graph
for them, because the game only keeps samples per window.

**Science** is reported as two numbers, because it is not one:

| Tile | Meaning |
|---|---|
| SPM | research units per minute — what "1k SPM" means. A unit needs the whole ingredient list, so the rate is the scarcest pack: `min(consumed / amount)` over `research_unit_ingredients`, which the mod sends so the consumer never has to guess which packs count. |
| Science packs/min | every science pack consumed, added up. Always larger. |

Both sum across surfaces first, since labs can sit on any planet. On the dev save
this immediately showed utility science at 8/min throttling research while every
other pack ran at 22–26.

**UPS is measured in the sidecar**, not the mod. Factorio exposes no UPS to Lua —
`LuaProfiler` measures real time but can only be written to the log, never read
back — so the sidecar derives it from how far the tick advances per second of
wall clock. Cross-checked against a direct two-point `game.tick` measurement:
46.25 measured vs 45.07 reported. (`scripts/ups-check.sh` runs that check.)

## Debugging a stutter

The game thread is single-threaded, so anything the mod does on a tick is time
the server is not simulating. `LuaProfiler` measures real time and can be written
to the log, which is the only timing signal Lua gets — it cannot be read back
into a variable. That makes this the fastest way to find a stall, and it needs no
restart:

```bash
bash scripts/dev.sh rcon '/silent-command local p=helpers.create_profiler() local r=remote.call("factorio-broadcast","send_now") p.stop() log{"","fb-lag FULL ",p} rcon.print("ok")'
grep fb-lag ~/fb/instance/server.log | tail
```

Time the whole snapshot first, then bisect into phases with the same pattern.
That is how the `send_udp` cost above was found: the total said 142 ms, the
phases said 0.5 ms for logistics, 42 ms for JSON and 174–374 ms for the sends.

`scripts/ups-check.sh` cross-checks the reported UPS against a direct two-point
`game.tick` measurement, which tells you whether a fix actually landed.

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

**Both targets ship from one file.** `mod/broadcast.lua` is the whole
implementation; `mod/control.lua` is a thin wrapper feeding it mod settings, and
`scripts/make-scenario.py` copies the same file into a save beside a generated
`control.lua`. Switch the dev server between them:

```bash
bash scripts/dev.sh softmod && bash scripts/dev.sh restart   # no client download
bash scripts/dev.sh mod     && bash scripts/dev.sh restart   # mod, settings UI
```

Because the softmod target shares its script with freeplay, `broadcast.lua` must
never register `on_init`, `on_load`, `on_configuration_changed`, or entity
events — only one handler per event may exist, so registering them would
silently clobber the scenario's own. Handlers go at load scope instead
(`control.lua` runs on every load) and `storage` is initialised lazily. Verified:
with the softmod running, `remote.interfaces` lists
`factorio-broadcast, freeplay, space_finish_script` — freeplay survived intact.

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
| `dev.sh softmod` / `mod` | Switch target. `softmod` rebuilds the scenario save from `mod/broadcast.lua`; it refuses while the server is running, because `/quit` saves the running script back over the rebuild. The order is **stop, softmod, start** — `softmod` followed by `restart` silently discards the build. |
| `dev.sh mode` | Which target the next start will use. |

The edit loop is **edit `mod/control.lua` → `dev.sh restart` → assert**, about
15 seconds wall clock, of which ~5 s is loading the 24 MB save.

`auto_pause` is on, so the server stops ticking when the last player leaves and
burns no CPU while idle. That has a consequence at the other end of the chain:
a paused game runs no ticks, the mod's timer never fires, and no snapshot is
written. The dashboard reads that as `paused · 20m 44s` — see *Reading the
status badge*. The UPS tile keeps showing the last value measured before the
pause, as does every other figure; the frozen tick in the header is what says
they are held, not current.

Assertions an agent can make without a human:

```bash
bash scripts/dev.sh errors                                    # no Lua errors
bash scripts/dev.sh rcon '/silent-command rcon.print(helpers.table_to_json(remote.call("factorio-broadcast","ping")))'
curl -s http://127.0.0.1:8099/health                          # packets, snapshots, age
node scripts/udp-tap.js 41234 5                               # raw datagrams, unparsed
```

### Layout

```
mod/          broadcast.lua is the implementation; control.lua wraps it as a mod
sidecar/      Node 22 + TypeScript, no dependencies, no build step
web/          index.html is the dashboard; servers.json names the sidecars it can reach
scripts/      dev.sh (WSL driver), make-scenario.py (softmod build), rcon.js, udp-tap.js
wrangler.jsonc  deploys web/ to Cloudflare as static assets, no Worker script
dev/          gitignored: Windows-side scratch instance
~/fb/         in WSL: factorio/ (headless), node/, instance/ (save, mods, logs)
```

---

## Which sidecar the page talks to

The dashboard is a static file. When the sidecar serves it the two are
same-origin and nothing needs configuring. But it is also deployed to
Cloudflare, where it has no API of its own, so the target is data rather than a
hardcoded origin.

The URL names the server:

```
https://factorio-dash.aroncreates.com/target/fb.example.com
https://factorio-dash.aroncreates.com/target/fb.example.com:8099
https://factorio-dash.aroncreates.com/target/fb.example.com/under-a-prefix
```

A bare host is assumed to be `https`. It has to be: the page is served over
https, and a browser blocks an http subresource from an https page as mixed
content, so an `http://192.168.x.x:8099` sidecar cannot be reached from the
deployed page at all — see *Reaching a local sidecar* below.

Resolution order, first match wins:

| Source | Notes |
|---|---|
| `/target/<host>` | A shareable link to one server. Needs the SPA fallback, which `wrangler.jsonc` sets. |
| `?api=<base-url>` | Same idea for a host that cannot route many paths to one page. |
| `?server=<id>` | An id from `servers.json`. |
| `localStorage` | The last pick, so a reload stays put. |
| First entry of `servers.json` | Same-origin when the sidecar serves the page. |

`web/servers.json` lists sidecars the page may talk to without a URL. With more
than one entry a picker appears in the header; with one it stays hidden.

```json
[
  { "id": "local", "label": "Local sidecar", "url": "" },
  { "id": "nauvis", "label": "Main base", "url": "https://fb.example.com" }
]
```

An empty `url` means same-origin. If the file is missing, the page falls back to
same-origin.

Switching servers closes the stream and clears every panel: ticks, surfaces and
series colours all belong to the game being left. Cross-origin needs nothing on
the sidecar — it already answers `Access-Control-Allow-Origin: *`, and SSE sends
no preflight.

One parsing quirk worth knowing: browsers collapse a doubled slash inside a
path, so `/target/https://host` arrives as `https:/host`. The parser puts the
slash back before reading the host.

### Reaching a local sidecar

The sidecar runs next to the game, on a private address, over plain http. The
deployed page cannot reach that: mixed content blocks the request, and a visitor
outside the LAN has no route to the address anyway. `http://127.0.0.1` is exempt
from mixed-content blocking, but only serves the one machine running the game,
and Chrome's Private Network Access rules want a preflight opt-in the sidecar
does not send.

So the sidecar goes behind a Cloudflare tunnel, which gives it a public hostname
and real TLS without opening a port. The tunnel is `factorio-broadcast`
(`46bf7456-dd14-455e-805b-dc4165a91271`), configured in
`%USERPROFILE%\.cloudflared\factorio-broadcast.yml` — its own file rather than
`config.yml`, which belongs to an unrelated tunnel:

```yaml
tunnel: 46bf7456-dd14-455e-805b-dc4165a91271
credentials-file: C:\Users\ideku\.cloudflared\46bf7456-dd14-455e-805b-dc4165a91271.json

ingress:
  - hostname: fb-api.aroncreates.com
    service: http://127.0.0.1:8099
  - service: http_status:404
```

`cloudflared tunnel route dns factorio-broadcast fb-api.aroncreates.com` created
the CNAME. To run it:

```bash
cloudflared tunnel --config "%USERPROFILE%\.cloudflared\factorio-broadcast.yml" run
```

The dashboard is then
`https://factorio-dash.aroncreates.com/target/fb-api.aroncreates.com`.

cloudflared runs on the Windows side while the sidecar runs in WSL. That works
because `.wslconfig` sets `networkingMode=Mirrored`, so the two share a loopback
and `http://127.0.0.1:8099` means the same socket on both sides. Under the
default NAT networking it would need the WSL address instead.

Note what does *not* pass through Cloudflare: the tunnel carries the statistics
straight from the sidecar to the browser. The deployed site is the page only.

### Server identity in the header

The heading is the server, not the tool: its name, its description, and what it
is running. The three come from two different places, because the game will not
give up all of it.

`script.active_mods` is readable from Lua, so the **mod list** rides along in
every snapshot. It is static for a run, but re-sending it is what lets a sidecar
that started late — or restarted — learn it at all, and the only cost that
scales with it is `table_to_json`, about a millisecond even at two hundred mods.

**Name and description** are not readable from Lua at all: `LuaGameScript` has no
`server_settings`, and probing for it errors outright. They live in
`server-settings.json`, which the game reads once at startup and never exposes.
So the sidecar reads that same file, polled on the same mtime check as
everything else, so renaming the server does not need a restart:

```bash
FB_SERVER_SETTINGS=~/fb/instance/server-settings.json node sidecar/src/index.ts
```

`dev.sh sidecar` passes it. Unset, or a server with no name, and the page keeps
its own title. Ten mods are shown; any beyond that collapse into a `+N more`
chip that names the rest on hover, rather than being dropped silently.

### Reading the status badge

The badge reports whether the **tick is moving**, not whether bytes are
arriving. The distinction matters because the sidecar replays its last snapshot
to every stream that connects, so a paused server hands out a fresh-looking
frame on each reconnect — carrying the tick it was written at. Counting arrivals
made that read `live` for a server that had been idle for hours.

| Badge | Means |
|---|---|
| `live` | The tick is advancing. |
| `lagging` | No progress for 2.5× the usual gap between snapshots. |
| `no data for 12s` | No progress for 5×. Could be the game, could be the pipe. |
| `paused · 20m 44s` | No progress for 10×, with the stream still open. |
| `reconnecting…` | The stream itself is down: sidecar or tunnel unreachable. |

Every threshold is a multiple of the *measured* cadence, never a fixed number of
seconds. One snapshot per second is a coincidence of the defaults: the mod emits
one every `fb-interval-ticks` game ticks (6–3600, default 60), so the real gap is
`interval / UPS` seconds and stretches as UPS falls. A megabase at 20 UPS sends a
frame every three seconds. Fixed thresholds would have called all of that
`lagging` while the UPS tile beside it said the server was healthy, so the page
tracks the median of the last eight gaps and scales to whatever it is getting.

Two things it deliberately does not claim. A paused game and a mod that stopped
reporting look identical from outside, so `paused` is only asserted once the
silence is too long to be a hiccup. And on first load the page has no history to
measure, so it dates that first frame from the sidecar's own `receivedAt` stamp —
otherwise opening the dashboard onto a server paused an hour ago would count from
zero and imply the data had just arrived. Only the first frame: the two clocks
are independent, and letting skew into every frame would make a running server
look permanently behind.

### Deploying the page

```bash
npx wrangler deploy
```

`wrangler.jsonc` uploads `web/` as Workers static assets and binds
`factorio-dash.aroncreates.com`. There is no Worker script. The one setting that
matters is `not_found_handling: "single-page-application"`, without which every
`/target/...` URL would 404 instead of loading the page that reads it.

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
- **M3** — ~~Cloudflare Worker + Durable Object~~ shipped differently: a static
  Pages site plus a Cloudflare Tunnel straight to the sidecar. No Worker, no
  stored secret — see *Which sidecar the page talks to*.
- **M4** — ~~the website~~ shipped: three tabs matching the game's own
  Production / Electricity / Logistics screens, deployed at
  [factorio-dash.aroncreates.com](https://factorio-dash.aroncreates.com/).

### Open questions

1. Which save is the real target — this dev copy, or a long-running server you
   keep up? Affects whether the sidecar needs to survive restarts.
2. Public or private page, and may player names appear on it?
3. Per-planet breakdown in the UI, or nauvis-first with the rest secondary?
4. Should the mod be published to mods.factorio.com, or stay private?
