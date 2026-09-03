// Bridges the game to the web: reads the JSON the mod writes into script-output,
// normalises it, and serves it over HTTP + SSE along with the dashboard.
//
// Node 24 runs TypeScript directly, so there is no build step and no dependencies:
//   node src/index.ts
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WEB_ROOT = path.resolve(HERE, '../../web');

// Where helpers.write_file puts things: <write-data-path>/script-output.
const OUTPUT_DIR = process.env.FB_OUTPUT_DIR ?? path.join(process.env.HOME ?? '', 'fb/factorio/script-output');
const SNAPSHOT_FILE = path.join(OUTPUT_DIR, 'broadcast.json');
const HISTORY_FILE = path.join(OUTPUT_DIR, 'broadcast-history.json');

// The server's own name and description live in server-settings.json, which the
// game reads at startup and never exposes to Lua - LuaGameScript has no
// server_settings. So the dashboard gets them the only way anything outside the
// game can: by reading the same file. Optional; unset simply means no name.
const SETTINGS_FILE = process.env.FB_SERVER_SETTINGS ?? '';

// Item icons come out of a Factorio install, which the sidecar serves from disk
// rather than the dashboard bundling them. They are Wube's artwork: keeping them
// on the machine that owns the game, instead of copying them into a repo and
// onto a CDN, is both the smaller change and the more defensible one.
//
// Point this at the "data" directory of a FULL install. The headless build ships
// no graphics at all, so on a WSL setup this is the Windows copy:
//   FB_ICONS_DIR=/mnt/f/SteamLibrary/steamapps/common/Factorio/data
const ICONS_DIR = process.env.FB_ICONS_DIR ?? '';

// A few prototypes do not share a name with their icon file.
const ICON_ALIASES: Record<string, string> = {
  'stone-wall': 'wall',
  'raw-fish': 'fish',
  'heat-exchanger': 'heat-boiler',
};

// name -> absolute path, built once at startup. Serving only what is in this map
// is also what keeps a request for ../../secrets from resolving to anything.
const icons = new Map<string, string>();

function indexIcons(root: string) {
  const walk = (dir: string) => {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return; // a mod directory that is not installed
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.png')) {
        const key = entry.name.slice(0, -4);
        // First writer wins, so base beats a mod's same-named override.
        if (!icons.has(key)) icons.set(key, full);
      }
    }
  };

  for (const mod of ['base', 'space-age', 'elevated-rails', 'quality']) {
    walk(path.join(root, mod, 'graphics', 'icons'));
  }
  for (const [name, file] of Object.entries(ICON_ALIASES)) {
    const target = icons.get(file);
    if (target && !icons.has(name)) icons.set(name, target);
  }
  console.log(`[icons] ${icons.size} indexed from ${root}`);
}
const POLL_MS = Number(process.env.FB_POLL_MS ?? 200);
const HTTP_PORT = Number(process.env.FB_HTTP_PORT ?? 8099);

// The mod scales every rate and energy by 100 to keep the JSON compact.
const SCALE = 100;
const un = (v: number | undefined): number => (v === undefined ? 0 : v / SCALE);
const unMap = (m: Record<string, number> | undefined): Record<string, number> => {
  const out: Record<string, number> = {};
  for (const [k, v] of Object.entries(m ?? {})) out[k] = un(v);
  return out;
};

// Electric network statistics are stored in Joules per tick, averaged over the
// requested window - the same unit as LuaEntityPrototype::get_max_energy_usage,
// which reports 1500 for an electric mining drill (a 90 kW machine). So watts is
// the flow count times the 60 ticks in a second.
const TICKS_PER_SECOND = 60;
const watts = (joulesPerTick: number | undefined): number => un(joulesPerTick) * TICKS_PER_SECOND;

// Lua has one table type, so helpers.table_to_json serialises an empty list as
// {} rather than []. Anything the mod means as a list must be coerced back.
const asArray = <T,>(v: unknown): T[] => {
  if (Array.isArray(v)) return v as T[];
  if (v && typeof v === 'object') return Object.values(v) as T[];
  return [];
};

type SeriesPanels = { produced: Record<string, number[]>; consumed: Record<string, number[]> };

type Snapshot = {
  tick: number;
  receivedAt: number;
  ups: number | null;
  meta: Record<string, unknown>;
  surfaces: Record<string, unknown>;
  history: Record<string, Record<string, { items: SeriesPanels; fluids: SeriesPanels; power: Record<string, SeriesPanels> }>>;
};

let latest: Snapshot | null = null;
const clients = new Set<http.ServerResponse>();
const stats = {
  reads: 0,
  snapshots: 0,
  bytes: 0,
  parseFailures: 0,
  lastError: null as string | null,
};

// Graph series arrive on their own slower cadence, one window per burst, so they
// are kept here and merged into every snapshot rather than expiring with one.
const history: Record<string, Record<string, { items: SeriesPanels; fluids: SeriesPanels; power: Record<string, SeriesPanels> }>> = {};

// Last value seen per surface per statistics window, so slow windows survive the
// snapshots that omit them.
const flowCache: Record<string, { items: Record<string, unknown>; fluids: Record<string, unknown> }> = {};

// Read from server-settings.json rather than from the game, and polled like
// everything else so renaming the server does not need a sidecar restart.
let serverInfo: { name: string; description: string } | null = null;

function applySettings(raw: any) {
  const name = typeof raw?.name === 'string' ? raw.name.trim() : '';
  const description = typeof raw?.description === 'string' ? raw.description.trim() : '';
  // An unnamed server is the same as no file: the page keeps its own title.
  serverInfo = name || description ? { name, description } : null;
}

// The game exposes no UPS reading - LuaProfiler measures real time but can only
// be written to the log, never read back into Lua. Measuring it out here is both
// exact and free: ticks advanced per second of wall clock.
const UPS_WINDOW = 8;
const ticks: Array<{ tick: number; at: number }> = [];

function currentUps(): number | null {
  if (ticks.length < 2) return null;
  const first = ticks[0];
  const last = ticks[ticks.length - 1];
  const seconds = (last.at - first.at) / 1000;
  if (seconds <= 0) return null;
  return (last.tick - first.tick) / seconds;
}

/** Protocol 3 reports each flow once per statistics window: {"1m": {input, output}}. */
function normaliseFlowWindows(value: unknown) {
  const out: Record<string, { produced: Record<string, number>; consumed: Record<string, number> }> = {};
  for (const [window, flow] of Object.entries((value ?? {}) as Record<string, any>)) {
    out[window] = { produced: unMap(flow?.input), consumed: unMap(flow?.output) };
  }
  return out;
}

/** All-time totals are exact counts, not rates, so they are not scaled by 100. */
function totalsAsWindow(value: any) {
  return {
    produced: { ...(value?.input ?? {}) } as Record<string, number>,
    consumed: { ...(value?.output ?? {}) } as Record<string, number>,
  };
}

function normaliseSurface(d: any) {
  const items = normaliseFlowWindows(d.items);
  const fluids = normaliseFlowWindows(d.fluids);
  // The "all" column of the in-game production screen.
  if (d.item_totals) items.all = totalsAsWindow(d.item_totals);
  if (d.fluid_totals) fluids.all = totalsAsWindow(d.fluid_totals);

  return {
    name: d.name,
    platform: d.platform,
    pollution: un(d.pollution),
    items,
    fluids,
    power: asArray<any>(d.power).map((n) => ({
      id: n.id,
      // Discovered on a surface with no electric poles, so the game will not
      // give up its statistics. Present, but unmeasurable.
      noStats: !!n.no_stats,
      producedW: watts(n.produced_j),
      consumedW: watts(n.consumed_j),
      satisfaction: un(n.satisfaction),
      producersW: Object.fromEntries(
        Object.entries(n.producers ?? {}).map(([k, v]) => [k, watts(v as number)]),
      ),
      consumersW: Object.fromEntries(
        Object.entries(n.consumers ?? {}).map(([k, v]) => [k, watts(v as number)]),
      ),
    })),
    logistics: asArray(d.logistics),
  };
}

function applySnapshot(raw: any) {
  const now = Date.now();
  // A reloaded save can move the tick backwards; start the measurement over
  // rather than reporting a negative rate.
  if (ticks.length && raw.t < ticks[ticks.length - 1].tick) ticks.length = 0;
  ticks.push({ tick: raw.t, at: now });
  while (ticks.length > UPS_WINDOW) ticks.shift();

  // Long windows are sampled on a slower cadence, so a snapshot carries only
  // the windows refreshed this tick. Merge rather than replace, keeping the
  // last value seen for every window.
  const surfaces: Record<string, unknown> = {};
  for (const [name, surface] of Object.entries((raw.surfaces ?? {}) as Record<string, any>)) {
    const fresh = normaliseSurface(surface);
    const cache = flowCache[name] ?? (flowCache[name] = { items: {}, fluids: {} });
    Object.assign(cache.items, fresh.items);
    Object.assign(cache.fluids, fresh.fluids);
    surfaces[name] = { ...fresh, items: cache.items, fluids: cache.fluids };
  }

  latest = {
    tick: raw.t,
    receivedAt: now,
    ups: currentUps(),
    history,
    meta: {
      modVersion: raw.mod_version,
      speed: un(raw.speed),
      paused: raw.paused,
      research: raw.research ? { ...raw.research, progress: un(raw.research.progress) } : null,
      rockets: raw.rockets,
      evolution: un(raw.evolution),
      playersOnline: raw.players_online,
      players: asArray(raw.players),
      surfaceNames: asArray<string>(raw.surface_names),
      // The mod can read the mod list but not the server's own name: Lua has no
      // access to server-settings.json, so that half comes from disk out here.
      mods: (raw.mods ?? {}) as Record<string, string>,
      server: serverInfo,
      // "all" is not a statistics window the game samples; it is the cumulative
      // total, which the mod sends alongside them.
      windows: [...asArray<string>(raw.windows), 'all'],
      baseWindow: raw.base_window ?? '1m',
    },
    surfaces,
  };
  stats.snapshots++;

  const frame = `data: ${JSON.stringify(latest)}\n\n`;
  for (const res of clients) res.write(frame);
}

/**
 * Index 0 is the most recent sample; reverse so charts read left to right.
 *
 * Protocol 4 sends each series as one comma-separated string, because
 * table_to_json over 6000 numbers costs the game 19 ms where the same values as
 * 20 strings cost 0.1 ms. Arrays are still accepted: same wire bytes, older mod.
 */
function normaliseSeries(series: Record<string, number[] | string> | undefined) {
  const out: Record<string, number[]> = {};
  for (const [item, values] of Object.entries(series ?? {})) {
    const numbers = typeof values === 'string'
      ? (values ? values.split(',').map(Number) : [])
      : asArray<number>(values);
    out[item] = numbers.map(un).reverse();
  }
  return out;
}

const emptyPanels = () => ({ produced: {}, consumed: {} });

function applyHistory(raw: any) {
  const window = String(raw.window);
  for (const [surface, series] of Object.entries((raw.surfaces ?? {}) as Record<string, any>)) {
    // Protocol 3 sent one flat map of production series per surface. The
    // production screen wants a graph per panel and a tab for fluids, so
    // protocol 4 sends items and fluids, each split into produced and consumed.
    // Both shapes are accepted, so a sidecar upgraded ahead of the mod - or a
    // save still running the old scenario script - keeps plotting.
    const panels = (v: any) => (v ? { produced: normaliseSeries(v.produced), consumed: normaliseSeries(v.consumed) } : emptyPanels());

    // Electricity is keyed by network id, each holding the same produced /
    // consumed pair - the two graphs of the in-game electric network window.
    const power: Record<string, { produced: Record<string, number[]>; consumed: Record<string, number[]> }> = {};
    for (const [id, nets] of Object.entries((series?.power ?? {}) as Record<string, any>)) {
      power[id] = panels(nets);
    }

    let normalised;
    if (series && (series.items || series.fluids)) {
      normalised = { items: panels(series.items), fluids: panels(series.fluids), power };
    } else if (series && (series.produced || series.consumed)) {
      normalised = { items: panels(series), fluids: emptyPanels(), power };
    } else {
      normalised = { items: { produced: normaliseSeries(series), consumed: {} }, fluids: emptyPanels(), power };
    }

    history[surface] = history[surface] ?? {};
    history[surface][window] = normalised;
  }
}

// mtime, not fs.watch: the mod rewrites these files in place once a second, and
// watch events on rewritten files are unreliable across platforms.
const seen = new Map<string, number>();

function readIfChanged(file: string, apply: (raw: any) => void) {
  let stat: fs.Stats;
  try {
    stat = fs.statSync(file);
  } catch {
    return; // not written yet
  }
  if (seen.get(file) === stat.mtimeMs) return;
  seen.set(file, stat.mtimeMs);

  let text: string;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    stats.lastError = `read ${path.basename(file)}: ${(err as Error).message}`;
    return;
  }

  stats.reads++;
  stats.bytes += text.length;

  try {
    apply(JSON.parse(text));
  } catch {
    // A read can land mid-write. The next write is a second away, so just skip.
    stats.parseFailures++;
  }
}

setInterval(() => {
  // Settings first: a snapshot read in the same pass should carry the new name
  // rather than the previous one.
  if (SETTINGS_FILE) readIfChanged(SETTINGS_FILE, applySettings);
  readIfChanged(HISTORY_FILE, applyHistory);
  readIfChanged(SNAPSHOT_FILE, applySnapshot);
}, POLL_MS);

if (ICONS_DIR) indexIcons(ICONS_DIR);

console.log(`[files] polling ${OUTPUT_DIR} every ${POLL_MS}ms`);

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  const url = new URL(req.url ?? '/', 'http://localhost');

  if (url.pathname === '/api/stats') {
    if (!latest) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'no snapshot yet', watching: SNAPSHOT_FILE }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify(latest));
    return;
  }

  if (url.pathname === '/api/stream') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-store',
      Connection: 'keep-alive',
    });
    if (latest) res.write(`data: ${JSON.stringify(latest)}\n\n`);
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }

  // /icons/<prototype-name>.png — only names in the index resolve, so the path
  // never reaches the filesystem as anything the caller wrote.
  if (url.pathname.startsWith('/icons/')) {
    const name = decodeURIComponent(url.pathname.slice('/icons/'.length)).replace(/\.png$/, '');
    const file = icons.get(name);
    if (!file) {
      res.writeHead(404).end('no icon');
      return;
    }
    res.writeHead(200, {
      'Content-Type': 'image/png',
      // Immutable for a given install; the page asks for a lot of these.
      'Cache-Control': 'public, max-age=86400',
    });
    fs.createReadStream(file).pipe(res);
    return;
  }

  if (url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(
      JSON.stringify({
        ...stats,
        watching: OUTPUT_DIR,
        clients: clients.size,
        icons: icons.size,
        lastTick: latest?.tick ?? null,
        ups: currentUps(),
        ageMs: latest ? Date.now() - latest.receivedAt : null,
      }),
    );
    return;
  }

  // The dashboard is served from here rather than opened as a file, so the page
  // is same-origin with the API and EventSource needs no CORS dance.
  const MIME: Record<string, string> = {
    '.html': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml',
  };
  const rel = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
  const file = path.join(WEB_ROOT, rel);

  // Never serve outside the web root, whatever the request path claims.
  if (file.startsWith(WEB_ROOT) && fs.existsSync(file) && fs.statSync(file).isFile()) {
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(file)] ?? 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    fs.createReadStream(file).pipe(res);
    return;
  }

  res.writeHead(404).end('not found');
});

server.listen(HTTP_PORT, () => {
  console.log(`[http] http://127.0.0.1:${HTTP_PORT}/  (api: /api/stats, /api/stream, /health)`);
});
