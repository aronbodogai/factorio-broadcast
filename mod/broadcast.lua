--[[
  factorio-broadcast - shared sampling logic.

  This file is the whole implementation and is used unchanged by both targets:

    * as a mod   - mod/control.lua requires it and feeds it mod settings
    * as a softmod - scripts/make-scenario.py copies it into a save next to a
      generated control.lua, so joining clients need no mod install at all

  Because of the softmod target it must never assume it is a mod:

    * no settings.global      - configuration arrives through get_config()
    * no script.on_init / on_load / on_configuration_changed - a scenario shares
      those with the freeplay script and only one handler per event may exist,
      so registering them here would silently clobber freeplay. Handlers are
      registered at load scope instead (control.lua runs on every load) and
      storage is initialised lazily.
    * no entity event subscriptions, for the same clobbering reason - electric
      networks are rediscovered on a timer instead.

  Requires the game to be started with  --enable-lua-udp <port>  ; without that
  flag helpers.send_udp does nothing.

  Wire format (protocol 2)
  ------------------------
  Each JSON object is split into datagrams of the form

    <id>|<index>|<total>|<chunk of the JSON text>

  because helpers.send_udp silently discards anything over 1472 bytes. Three
  kinds of object; "meta" and "surface" share a tick so the sidecar can group a
  set of them into one snapshot:

    {"k":"meta",    "v":2, "t":<tick>, ...}   exactly one per snapshot, sent last
    {"k":"surface", "v":2, "t":<tick>, ...}   one per surface
    {"k":"history", "v":2, "t":<tick>, ...}   one per surface, occasionally

  Rates and energies are integers in HUNDREDTHS of their unit; the sidecar
  divides by 100. Sending floats would be correct but helpers.table_to_json
  serialises them at full double precision, which triples the payload for nothing.

  Units, per the API docs: flow counts are normalised per-tick for electric
  networks and per-minute for everything else.
]]

local M = {}

local PROTOCOL_VERSION = 2

-- Payload bytes per datagram. The measured ceiling is 1472 including the
-- "<id>|<index>|<total>|" header, so leave room for it.
local CHUNK_BYTES = 1400

-- Each precision level holds 300 samples covering its whole window, which is
-- exactly the data behind the in-game statistics graphs.
local SAMPLES_PER_WINDOW = 300

local WINDOWS = {
  ["5s"] = defines.flow_precision_index.five_seconds,
  ["1m"] = defines.flow_precision_index.one_minute,
  ["10m"] = defines.flow_precision_index.ten_minutes,
  ["1h"] = defines.flow_precision_index.one_hour,
  ["10h"] = defines.flow_precision_index.ten_hours,
  ["50h"] = defines.flow_precision_index.fifty_hours,
  ["250h"] = defines.flow_precision_index.two_hundred_fifty_hours,
  ["1000h"] = defines.flow_precision_index.one_thousand_hours,
}

-- The window the power breakdown and the "top items" ranking are taken from.
local BASE_WINDOW = "1m"

--- Set by setup(); returns the live configuration table.
local get_config = nil

local function split_windows(spec)
  local out = {}
  for token in string.gmatch(spec or "", "[^,%s]+") do
    if WINDOWS[token] then out[#out + 1] = token end
  end
  if #out == 0 then out[#out + 1] = BASE_WINDOW end
  return out
end

local function config()
  local c = get_config and get_config() or {}
  return {
    enabled = c.enabled ~= false,
    port = c.port or 41234,
    interval = c.interval or 60,
    rescan_seconds = c.rescan_seconds or 300,
    windows = split_windows(c.windows or "5s,1m,10m,1h"),
    -- Graph series are large, so they go out on their own slower cadence and
    -- cover one window per burst, rotating through the configured windows.
    history_items = c.history_items or 5,
    history_every = c.history_every or 5,
  }
end

--- Scale a float to an integer number of hundredths.
local function q(x)
  if x == nil then return 0 end
  return math.floor(x * 100 + 0.5)
end

--- Windowed input/output rates for every prototype with a non-zero total.
--- Iterating input_counts keeps this O(items this force has ever made) rather
--- than O(every prototype in the game).
local function read_flow(stats, window)
  local precision = WINDOWS[window]
  local out = { input = {}, output = {} }
  for name in pairs(stats.input_counts) do
    local rate = stats.get_flow_count({ name = name, category = "input", precision_index = precision })
    if rate and rate > 0 then out.input[name] = q(rate) end
  end
  for name in pairs(stats.output_counts) do
    local rate = stats.get_flow_count({ name = name, category = "output", precision_index = precision })
    if rate and rate > 0 then out.output[name] = q(rate) end
  end
  return out
end

local function read_flow_windows(stats, windows)
  local out = {}
  for _, window in pairs(windows) do
    out[window] = read_flow(stats, window)
  end
  return out
end

--- The 300 samples behind one line of an in-game statistics graph.
--- Index 1 is the most recent sample.
local function read_series(stats, name, window)
  local precision = WINDOWS[window]
  local series = {}
  for sample = 1, SAMPLES_PER_WINDOW do
    series[sample] = q(stats.get_flow_count({
      name = name,
      category = "input",
      precision_index = precision,
      sample_index = sample,
    }))
  end
  return series
end

--- One electric pole per distinct electric network, cached: find_entities_filtered
--- over a whole surface is far too expensive to run every second.
local function rescan_networks()
  storage.fb_poles = {}
  for _, surface in pairs(game.surfaces) do
    local seen = {}
    local list = {}
    for _, pole in pairs(surface.find_entities_filtered({ type = "electric-pole" })) do
      local id = pole.electric_network_id
      if id and not seen[id] then
        seen[id] = true
        list[#list + 1] = pole
      end
    end
    storage.fb_poles[surface.name] = list
  end
  storage.fb_last_rescan = game.tick
end

local function read_power(surface_name)
  local networks = {}
  local poles = storage.fb_poles and storage.fb_poles[surface_name]
  if not poles then return networks end

  local precision = WINDOWS[BASE_WINDOW]
  for _, pole in pairs(poles) do
    if pole.valid then
      local stats = pole.electric_network_statistics
      local produced, consumed = 0, 0
      local by_producer, by_consumer = {}, {}

      for name in pairs(stats.output_counts) do
        local j = stats.get_flow_count({ name = name, category = "output", precision_index = precision })
        if j and j > 0 then
          by_producer[name] = q(j)
          produced = produced + j
        end
      end
      for name in pairs(stats.input_counts) do
        local j = stats.get_flow_count({ name = name, category = "input", precision_index = precision })
        if j and j > 0 then
          by_consumer[name] = q(j)
          consumed = consumed + j
        end
      end

      networks[#networks + 1] = {
        id = pole.electric_network_id,
        -- Joules per tick; the sidecar multiplies by 60 to get watts.
        produced_j = q(produced),
        consumed_j = q(consumed),
        satisfaction = produced > 0 and q(math.min(consumed / produced, 1) * 100) or 0,
        producers = by_producer,
        consumers = by_consumer,
      }
    end
  end
  return networks
end

local function read_logistics(force, surface_name)
  local out = {}
  local by_surface = force.logistic_networks[surface_name]
  if not by_surface then return out end

  for _, network in pairs(by_surface) do
    if network.valid then
      out[#out + 1] = {
        cells = #network.cells,
        bots_all = network.all_logistic_robots,
        bots_idle = network.available_logistic_robots,
        construction_all = network.all_construction_robots,
        construction_idle = network.available_construction_robots,
      }
    end
  end
  return out
end

local function send(port, payload)
  local json = helpers.table_to_json(payload)
  local total = math.max(1, math.ceil(#json / CHUNK_BYTES))

  storage.fb_seq = (storage.fb_seq or 0) + 1
  local id = storage.fb_seq

  for i = 1, total do
    local part = string.sub(json, (i - 1) * CHUNK_BYTES + 1, i * CHUNK_BYTES)
    helpers.send_udp(port, id .. "|" .. i .. "|" .. total .. "|" .. part, 0)
  end

  return #json
end

--- The n highest-rate prototype names in a flow map.
local function top_names(flow_map, n)
  local names = {}
  for name in pairs(flow_map) do names[#names + 1] = name end
  -- Sort by rate, then by name so the choice is stable and deterministic
  -- across peers when two items are producing at the same rate.
  table.sort(names, function(a, b)
    if flow_map[a] ~= flow_map[b] then return flow_map[a] > flow_map[b] end
    return a < b
  end)
  local out = {}
  for i = 1, math.min(n, #names) do out[i] = names[i] end
  return out
end

--- Returns the datagram size emitted per surface, which is the number that
--- decides whether a snapshot survives the UDP size ceiling.
local function snapshot()
  local cfg = config()
  if not cfg.enabled then return end

  local tick = game.tick
  local force = game.forces["player"]
  if not (force and force.valid) then return end

  if not storage.fb_last_rescan or tick - storage.fb_last_rescan >= cfg.rescan_seconds * 60 then
    rescan_networks()
  end

  -- One window's worth of graph series per burst, rotating, so the extra
  -- bandwidth stays flat no matter how many windows are configured.
  storage.fb_snapshot_n = (storage.fb_snapshot_n or 0) + 1
  local history_window = nil
  if cfg.history_items > 0 and storage.fb_snapshot_n % cfg.history_every == 0 then
    local cursor = math.floor(storage.fb_snapshot_n / cfg.history_every) % #cfg.windows
    history_window = cfg.windows[cursor + 1]
  end

  local sizes = {}
  local surface_names = {}

  for _, surface in pairs(game.surfaces) do
    local item_stats = force.get_item_production_statistics(surface)
    local items = read_flow_windows(item_stats, cfg.windows)

    surface_names[#surface_names + 1] = surface.name
    sizes[surface.name] = send(cfg.port, {
      k = "surface",
      v = PROTOCOL_VERSION,
      t = tick,
      name = surface.name,
      platform = surface.platform ~= nil,
      pollution = q(surface.get_total_pollution()),
      items = items,
      fluids = read_flow_windows(force.get_fluid_production_statistics(surface), cfg.windows),
      power = read_power(surface.name),
      logistics = read_logistics(force, surface.name),
    })

    if history_window then
      local base = items[BASE_WINDOW] or items[cfg.windows[1]]
      local names = top_names(base.input, cfg.history_items)
      if #names > 0 then
        local series = {}
        for _, name in pairs(names) do
          series[name] = read_series(item_stats, name, history_window)
        end
        sizes["history:" .. surface.name] = send(cfg.port, {
          k = "history",
          v = PROTOCOL_VERSION,
          t = tick,
          name = surface.name,
          window = history_window,
          samples = SAMPLES_PER_WINDOW,
          series = series,
        })
      end
    end
  end

  local research = nil
  if force.current_research then
    research = {
      name = force.current_research.name,
      level = force.current_research.level,
      progress = q(force.research_progress * 100),
      queue = #force.research_queue,
    }
  end

  local players = {}
  for _, player in pairs(game.connected_players) do
    players[#players + 1] = { name = player.name, surface = player.surface.name }
  end

  local nauvis = game.surfaces["nauvis"]

  -- Sent last so the sidecar can treat "meta" as the end-of-snapshot marker.
  sizes.meta = send(cfg.port, {
    k = "meta",
    v = PROTOCOL_VERSION,
    t = tick,
    -- Absent when running as a softmod, which is how the sidecar tells them apart.
    mod_version = script.active_mods["factorio-broadcast"] or "scenario",
    speed = q(game.speed),
    paused = game.tick_paused,
    surfaces = surface_names,
    windows = cfg.windows,
    base_window = BASE_WINDOW,
    research = research,
    rockets = force.rockets_launched,
    evolution = nauvis and q(force.get_evolution_factor(nauvis) * 100) or 0,
    players_online = #game.connected_players,
    players = players,
  })

  return sizes
end

local function on_tick()
  -- A malformed snapshot must never take the save down with it.
  local ok, err = pcall(snapshot)
  if not ok then
    log("[factorio-broadcast] snapshot failed: " .. tostring(err))
  end
end

-- Which interval is currently registered. A module local, not storage: storage
-- does not exist at load scope, and this is derived from synchronised settings
-- rather than being game state of its own.
local registered_interval = nil

--- (Re)register the sampling tick. Only this mod's own interval is touched, so
--- an nth-tick handler belonging to the scenario is left alone.
function M.reschedule()
  local interval = config().interval
  if registered_interval == interval then return end
  if registered_interval then
    script.on_nth_tick(registered_interval, nil)
  end
  registered_interval = interval
  script.on_nth_tick(interval, on_tick)
end

--- get_config is called on every snapshot, so settings changes are picked up
--- without re-registering anything.
function M.setup(config_source)
  get_config = config_source

  -- Registered at load scope: control.lua runs on every load, so this needs
  -- neither on_init nor on_load, and cannot clobber the scenario's handlers.
  M.reschedule()

  -- RCON caps how long a single command may be, so anything an operator or an
  -- agent needs to ask goes through a short remote.call rather than pasted Lua.
  remote.add_interface("factorio-broadcast", {
    --- Emit a snapshot immediately; returns the datagram size per surface.
    send_now = function()
      return snapshot()
    end,

    --- Cheap liveness/config check.
    ping = function()
      local cfg = config()
      return {
        version = script.active_mods["factorio-broadcast"] or "scenario",
        protocol = PROTOCOL_VERSION,
        tick = game.tick,
        port = cfg.port,
        interval = cfg.interval,
        enabled = cfg.enabled,
        windows = cfg.windows,
        surfaces = #game.surfaces,
      }
    end,

    --- Rediscover electric networks now rather than waiting for the timer.
    rescan = function()
      rescan_networks()
      return true
    end,
  })
end

return M
