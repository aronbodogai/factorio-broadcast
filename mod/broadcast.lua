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

  Wire format (protocol 4)
  ------------------------
  Two JSON files in script-output, rewritten in place:

    broadcast.json          the whole snapshot, once per interval
    broadcast-history.json  the graph series, on a slower cadence

  Protocol 4 splits the history file per surface into { produced, consumed }.
  The in-game production screen draws a graph over each of its two panels, and
  ranking series by production alone left heavily-consumed items unplottable.

  This used to push datagrams with helpers.send_udp. It does not any more:
  send_udp costs 8-31 ms PER CALL - a fixed cost, not proportional to payload -
  and its silent 1472-byte ceiling forced roughly 17 calls per snapshot, so a
  single snapshot blocked the game for ~140 ms. Measured against it,
  helpers.write_file moves 20 KB in 0.6-1.0 ms and has no size limit, which is
  20-100x cheaper for a payload that is 10x bigger.

  The sidecar reads whichever file changed. A read can catch a half-written
  file; the sidecar simply skips anything that fails to parse and picks up the
  next write.

  Rates and energies are integers in HUNDREDTHS of their unit; the sidecar
  divides by 100. Writing floats would be correct but helpers.table_to_json
  serialises them at full double precision, which triples the payload for nothing.

  Units, per the API docs: flow counts are normalised per-tick for electric
  networks and per-minute for everything else.
]]

local M = {}

local PROTOCOL_VERSION = 4

local SNAPSHOT_FILE = "broadcast.json"
local HISTORY_FILE = "broadcast-history.json"

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

-- Windows long enough that re-reading them every snapshot is waste: a 1000-hour
-- average does not move perceptibly in a second. These are refreshed on their
-- own slower cadence and the sidecar keeps the last value it saw for each.
local SLOW_WINDOWS = {
  ["1h"] = true, ["10h"] = true, ["50h"] = true,
  ["250h"] = true, ["1000h"] = true,
}

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
    interval = c.interval or 60,
    rescan_seconds = c.rescan_seconds or 300,
    windows = split_windows(c.windows or "5s,1m,10m,1h,10h,50h,250h,1000h"),
    -- Graph series are large, so they go out on their own slower cadence and
    -- cover one window per burst, rotating through the configured windows.
    history_items = c.history_items or 10,
    history_every = c.history_every or 5,
    slow_every = c.slow_every or 30,
  }
end

--- Scale a float to an integer number of hundredths.
local function q(x)
  if x == nil then return 0 end
  return math.floor(x * 100 + 0.5)
end

--- Windowed rates for every prototype with a non-zero total, plus the all-time
--- totals - the "all" column of the in-game production screen.
---
--- input_counts and output_counts are fetched once and reused across every
--- window: they are the set of prototypes this force has ever touched, so this
--- stays O(items produced) rather than O(every prototype in the game), and the
--- dictionaries are not rebuilt per window.
---
--- The all-time totals cost nothing extra - they are the *values* in those same
--- dictionaries, which the per-window loops only use for their keys. They are
--- sent unscaled, being exact counts rather than rates.
local function read_flow_windows(stats, windows)
  local inputs = stats.input_counts
  local outputs = stats.output_counts

  local out = {}
  for _, window in pairs(windows) do
    local precision = WINDOWS[window]
    local flow = { input = {}, output = {} }
    for name in pairs(inputs) do
      local rate = stats.get_flow_count({ name = name, category = "input", precision_index = precision })
      if rate and rate > 0 then flow.input[name] = q(rate) end
    end
    for name in pairs(outputs) do
      local rate = stats.get_flow_count({ name = name, category = "output", precision_index = precision })
      if rate and rate > 0 then flow.output[name] = q(rate) end
    end
    out[window] = flow
  end

  local totals = { input = {}, output = {} }
  for name, count in pairs(inputs) do
    if count > 0 then totals.input[name] = count end
  end
  for name, count in pairs(outputs) do
    if count > 0 then totals.output[name] = count end
  end

  return out, totals
end

--- The 300 samples behind one line of an in-game statistics graph.
--- Index 1 is the most recent sample.
--- category is "input" for what was produced, "output" for what was consumed.
--- The in-game production screen graphs both, one per panel, so both are sent.
local function read_series(stats, name, window, category)
  local precision = WINDOWS[window]
  local series = {}
  for sample = 1, SAMPLES_PER_WINDOW do
    series[sample] = q(stats.get_flow_count({
      name = name,
      category = category,
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
      -- What the network is holding, which is the Items table of the in-game L
      -- screen. Measured at 0.7 ms for 135 distinct items across two networks,
      -- so it is affordable every snapshot.
      --
      -- get_contents returns one entry per name AND quality; they are summed by
      -- name here. Splitting them would double the rows for a distinction the
      -- dashboard has nowhere to show.
      local contents = {}
      for _, stack in pairs(network.get_contents()) do
        contents[stack.name] = (contents[stack.name] or 0) + stack.count
      end

      out[#out + 1] = {
        -- Stable across snapshots, so the viewer's chosen network stays chosen.
        -- LuaLogisticNetwork has no name in 2.0, whatever the L screen shows.
        id = network.network_id,
        cells = #network.cells,
        bots_all = network.all_logistic_robots,
        bots_idle = network.available_logistic_robots,
        construction_all = network.all_construction_robots,
        construction_idle = network.available_construction_robots,
        contents = contents,
      }
    end
  end
  return out
end

--- for_player 0 writes only on the server, which is what we want: on a
--- multiplayer game every peer runs this script, and without it every client
--- would write the file too.
local function write(filename, payload)
  local json = helpers.table_to_json(payload)
  helpers.write_file(filename, json, false, 0)
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

--- Writes one snapshot file, plus a history file on its slower cadence.
--- Returns the bytes written per file.
local function snapshot()
  local cfg = config()
  if not cfg.enabled then return end

  local tick = game.tick
  local force = game.forces["player"]
  if not (force and force.valid) then return end

  if not storage.fb_last_rescan or tick - storage.fb_last_rescan >= cfg.rescan_seconds * 60 then
    rescan_networks()
  end

  -- One window's worth of graph series per burst, rotating, so the extra work
  -- stays flat no matter how many windows are configured.
  storage.fb_snapshot_n = (storage.fb_snapshot_n or 0) + 1
  local history_window = nil
  if cfg.history_items > 0 and storage.fb_snapshot_n % cfg.history_every == 0 then
    local cursor = math.floor(storage.fb_snapshot_n / cfg.history_every) % #cfg.windows
    history_window = cfg.windows[cursor + 1]
  end

  -- Long windows ride a slower cadence; the sidecar keeps the last value it saw
  -- for each window, so a snapshot that omits them is not a gap.
  local include_slow = storage.fb_snapshot_n % cfg.slow_every == 0
  local windows_now = {}
  for _, window in pairs(cfg.windows) do
    if include_slow or not SLOW_WINDOWS[window] then
      windows_now[#windows_now + 1] = window
    end
  end

  local sizes = {}
  local surface_names = {}
  local surfaces = {}
  local history = history_window and {} or nil

  for _, surface in pairs(game.surfaces) do
    local item_stats = force.get_item_production_statistics(surface)
    local items, item_totals = read_flow_windows(item_stats, windows_now)
    local fluid_stats = force.get_fluid_production_statistics(surface)
    local fluids, fluid_totals = read_flow_windows(fluid_stats, windows_now)

    surface_names[#surface_names + 1] = surface.name
    surfaces[surface.name] = {
      name = surface.name,
      platform = surface.platform ~= nil,
      pollution = q(surface.get_total_pollution()),
      items = items,
      item_totals = item_totals,
      fluid_totals = fluid_totals,
      fluids = fluids,
      power = read_power(surface.name),
      logistics = read_logistics(force, surface.name),
    }

    if history_window then
      -- The production screen puts a graph over each of its two panels, and has
      -- a tab for items and one for fluids, so all four combinations are sent.
      -- Production and consumption are ranked separately on purpose: an item can
      -- dominate consumption without ever being produced here, and ranking by
      -- production alone left exactly those items unplottable.
      local function series_for(stats, flows)
        local base = flows[BASE_WINDOW] or flows[cfg.windows[1]]
        local produced, consumed = {}, {}
        for _, name in pairs(top_names(base.input, cfg.history_items)) do
          produced[name] = read_series(stats, name, history_window, "input")
        end
        for _, name in pairs(top_names(base.output, cfg.history_items)) do
          consumed[name] = read_series(stats, name, history_window, "output")
        end
        return { produced = produced, consumed = consumed }
      end

      history[surface.name] = {
        items = series_for(item_stats, items),
        fluids = series_for(fluid_stats, fluids),
      }
    end
  end

  local research = nil
  if force.current_research then
    -- The pack recipe for one research unit, so the consumer can turn science
    -- pack consumption into research units per minute rather than guessing
    -- which packs count and how many of each a unit needs.
    local ingredients = {}
    for _, ingredient in pairs(force.current_research.research_unit_ingredients) do
      ingredients[#ingredients + 1] = { name = ingredient.name, amount = ingredient.amount }
    end

    research = {
      name = force.current_research.name,
      level = force.current_research.level,
      progress = q(force.research_progress * 100),
      queue = #force.research_queue,
      ingredients = ingredients,
      unit_count = force.current_research.research_unit_count,
    }
  end

  local players = {}
  for _, player in pairs(game.connected_players) do
    players[#players + 1] = { name = player.name, surface = player.surface.name }
  end

  local nauvis = game.surfaces["nauvis"]

  if history_window then
    sizes.history = write(HISTORY_FILE, {
      v = PROTOCOL_VERSION,
      t = tick,
      window = history_window,
      samples = SAMPLES_PER_WINDOW,
      surfaces = history,
    })
  end

  sizes.snapshot = write(SNAPSHOT_FILE, {
    v = PROTOCOL_VERSION,
    t = tick,
    -- Absent when running as a softmod, which is how the sidecar tells them apart.
    mod_version = script.active_mods["factorio-broadcast"] or "scenario",
    -- Static for the life of the run, and re-sent every snapshot anyway: a
    -- sidecar that starts late, or restarts, would otherwise never learn it.
    -- Four entries on a Space Age install, and table_to_json is the only cost
    -- that scales with it - about a millisecond even at two hundred mods.
    mods = script.active_mods,
    speed = q(game.speed),
    paused = game.tick_paused,
    surface_names = surface_names,
    surfaces = surfaces,
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
