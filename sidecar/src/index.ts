// Bridges the game to the web: listens for the mod's UDP datagrams, assembles
// them into snapshots, and serves the latest one over HTTP + SSE.
//
// Node 24 runs TypeScript directly, so there is no build step and no dependencies:
//   node src/index.ts
import dgram from 'node:dgram';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../web');

const UDP_PORT = Number(process.env.FB_UDP_PORT ?? 41234);
const UDP_HOST = process.env.FB_UDP_HOST ?? '127.0.0.1';
const HTTP_PORT = Number(process.env.FB_HTTP_PORT ?? 8099);

// The mod scales every rate and energy by 100 to keep JSON compact.
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
// the flow count times the 60 ticks in a second, NOT divided by the window.
const TICKS_PER_SECOND = 60;
const watts = (joulesPerTick: number | undefined): number => un(joulesPerTick) * TICKS_PER_SECOND;

// Lua has one table type, so helpers.table_to_json serialises an empty list as
// {} rather than []. Anything the mod means as a list must be coerced back.
const asArray = <T,>(v: unknown): T[] => {
  if (Array.isArray(v)) return v as T[];
  if (v && typeof v === 'object') return Object.values(v) as T[];
  return [];
};

type Datagram = { k: 'meta' | 'surface'; v: number; t: number; [key: string]: unknown };

type Snapshot = {
  tick: number;
  receivedAt: number;
  ups: number | null;
  meta: Record<string, unknown>;
  surfaces: Record<string, unknown>;
  history: Record<string, Record<string, Record<string, number[]>>>;
};

let latest: Snapshot | null = null;
let partial: { tick: number; surfaces: Record<string, unknown> } | null = null;
const clients = new Set<http.ServerResponse>();
const stats = { packets: 0, snapshots: 0, bytes: 0, lastError: null as string | null };

// Graph series arrive on their own slower cadence, one window per burst, so they
// are kept here and merged into every snapshot rather than expiring with one.
const history: Record<string, Record<string, Record<string, number[]>>> = {};

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

/** Protocol 2 reports each flow once per statistics window: {"1m": {input, output}}. */
function normaliseFlowWindows(value: unknown) {
  const out: Record<string, { produced: Record<string, number>; consumed: Record<string, number> }> = {};
  for (const [window, flow] of Object.entries((value ?? {}) as Record<string, any>)) {
    out[window] = { produced: unMap(flow?.input), consumed: unMap(flow?.output) };
  }
  return out;
}

function normaliseSurface(d: Datagram) {
  return {
    name: d.name,
    platform: d.platform,
    pollution: un(d.pollution as number),
    items: normaliseFlowWindows(d.items),
    fluids: normaliseFlowWindows(d.fluids),
    power: asArray<any>(d.power).map((n) => ({
      id: n.id,
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

function finalise(meta: Datagram) {
  const surfaces = partial && partial.tick === meta.t ? partial.surfaces : {};
  partial = null;

  const now = Date.now();
  // A reloaded save can move the tick backwards; start the measurement over
  // rather than reporting a negative rate.
  if (ticks.length && meta.t < ticks[ticks.length - 1].tick) ticks.length = 0;
  ticks.push({ tick: meta.t, at: now });
  while (ticks.length > UPS_WINDOW) ticks.shift();

  latest = {
    tick: meta.t,
    receivedAt: now,
    ups: currentUps(),
    history,
    meta: {
      modVersion: meta.mod_version,
      speed: un(meta.speed as number),
      paused: meta.paused,
      research: meta.research
        ? { ...(meta.research as object), progress: un((meta.research as any).progress) }
        : null,
      rockets: meta.rockets,
      evolution: un(meta.evolution as number),
      playersOnline: meta.players_online,
      players: asArray(meta.players),
      surfaceNames: asArray(meta.surfaces),
      windows: asArray<string>(meta.windows),
      baseWindow: meta.base_window ?? '1m',
    },
    surfaces,
  };
  stats.snapshots++;

  const frame = `data: ${JSON.stringify(latest)}\n\n`;
  for (const res of clients) res.write(frame);
}

const sock = dgram.createSocket('udp4');

// helpers.send_udp drops anything over 1472 bytes, so the mod splits payloads
// into "<id>|<index>|<total>|<chunk>" datagrams that are reassembled here.
const pending = new Map<number, { total: number; parts: string[]; have: number }>();
const CHUNK_HEADER = /^(\d+)\|(\d+)\|(\d+)\|/;

function reassemble(raw: string): string | null {
  const m = CHUNK_HEADER.exec(raw);
  if (!m) return raw; // unchunked, for forward compatibility
  const id = Number(m[1]);
  const index = Number(m[2]);
  const total = Number(m[3]);
  const body = raw.slice(m[0].length);

  if (total === 1) return body;

  let entry = pending.get(id);
  if (!entry) {
    entry = { total, parts: new Array(total), have: 0 };
    pending.set(id, entry);
    // A lost chunk would otherwise pin its siblings in memory forever.
    if (pending.size > 64) {
      for (const key of pending.keys()) {
        if (key < id - 32) pending.delete(key);
      }
    }
  }
  if (entry.parts[index - 1] === undefined) {
    entry.parts[index - 1] = body;
    entry.have++;
  }
  if (entry.have < entry.total) return null;

  pending.delete(id);
  return entry.parts.join('');
}

sock.on('message', (buf) => {
  stats.packets++;
  stats.bytes += buf.length;

  const whole = reassemble(buf.toString('utf8'));
  if (whole === null) return; // waiting on more chunks

  let d: Datagram;
  try {
    d = JSON.parse(whole);
  } catch (err) {
    stats.lastError = `bad JSON (${whole.length}B): ${(err as Error).message}`;
    return;
  }

  if (d.k === 'surface') {
    // Surface datagrams always precede the meta datagram for the same tick.
    if (!partial || partial.tick !== d.t) partial = { tick: d.t, surfaces: {} };
    partial.surfaces[String(d.name)] = normaliseSurface(d);
  } else if (d.k === 'history') {
    const surface = String(d.name);
    const window = String(d.window);
    const series: Record<string, number[]> = {};
    for (const [item, values] of Object.entries((d.series ?? {}) as Record<string, number[]>)) {
      // Index 0 is the most recent sample; reverse so charts read left to right.
      series[item] = asArray<number>(values).map(un).reverse();
    }
    history[surface] = history[surface] ?? {};
    history[surface][window] = series;
  } else if (d.k === 'meta') {
    finalise(d);
  }
});

sock.on('error', (err) => {
  console.error(`[udp] ${err.message}`);
  process.exit(1);
});

sock.bind(UDP_PORT, UDP_HOST, () => {
  console.log(`[udp] listening on ${UDP_HOST}:${UDP_PORT}`);
});

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  const url = new URL(req.url ?? '/', 'http://localhost');

  if (url.pathname === '/api/stats') {
    if (!latest) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'no snapshot received yet' }));
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

  if (url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(
      JSON.stringify({
        ...stats,
        clients: clients.size,
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
  console.log(`[http] http://127.0.0.1:${HTTP_PORT}/api/stats  (stream: /api/stream, health: /health)`);
});
