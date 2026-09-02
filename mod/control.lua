--[[
  factorio-broadcast

  Samples factory statistics once per interval and pushes them to a sidecar
  process listening on a localhost UDP port.

  Requires the game to be started with  --enable-lua-udp <port>  ; without that
  flag helpers.send_udp is unavailable and this mod stays silent.

  Wire format
  -----------
  Each JSON object is split into datagrams of the form

    <id>|<index>|<total>|<chunk of the JSON text>

  because helpers.send_udp silently discards anything over 1472 bytes. The
  sidecar joins the chunks back together. Two kinds of object, both carrying the
  same "t" (tick) so the sidecar can group a set of them into one snapshot:

    {"k":"meta",    "v":1, "t":<tick>, ...}   exactly one per snapshot, sent last
    {"k":"surface", "v":1, "t":<tick>, ...}   one per surface

  All rates and energies are integers in HUNDREDTHS of their unit. The sidecar
  divides by 100. Sending floats would be correct but helpers.table_to_json
  serialises them at full double precision (2271.66666666666651508421637117862701416015625),
  which triples the payload for no gain.
]]

local PROTOCOL_VERSION = 1

-- Payload bytes per datagram. The measured ceiling is 1472 including the
-- "<id>|<index>|<total>|" header, so leave room for it.
local CHUNK_BYTES = 1400

local PRECISION = defines.flow_precision_index.one_minute

--- Scale a float to an integer number of hundredths.
local function q(x)
  if x == nil then return 0 end
  return math.floor(x * 100 + 0.5)
end

local function setting(name)
  local s = settings.global[name]
  return s and s.value or nil
end

--- Read windowed input/output rates for every prototype with a non-zero total.
--- Iterating input_counts keeps this O(items this force has ever made) rather
--- than O(every prototype in the game).
local function read_flow(stats)
  local out = { input = {}, output = {} }
  for name in pairs(stats.input_counts) do
    local rate = stats.get_flow_count({ name = name, category = "input", precision_index = PRECISION })
    if rate and rate > 0 then out.input[name] = q(rate) end
  end
  for name in pairs(stats.output_counts) do
    local rate = stats.get_flow_count({ name = name, category = "output", precision_index = PRECISION })
    if rate and rate > 0 then out.output[name] = q(rate) end
  end
  return out
end

--- One electric pole per distinct electric network, cached: find_entities_filtered
--- over a whole surface is far too expensive to run every second.
local function rescan_networks()
  storage.poles = {}
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
    storage.poles[surface.name] = list
  end
  storage.last_rescan = game.tick
end

local function read_power(surface_name)
  local networks = {}
  local poles = storage.poles and storage.poles[surface_name]
  if not poles then return networks end

  for _, pole in pairs(poles) do
    if pole.valid then
      local stats = pole.electric_network_statistics
      local produced, consumed = 0, 0
      local by_producer, by_consumer = {}, {}

      for name in pairs(stats.output_counts) do
        local j = stats.get_flow_count({ name = name, category = "output", precision_index = PRECISION })
        if j and j > 0 then
          by_producer[name] = q(j)
          produced = produced + j
        end
      end
      for name in pairs(stats.input_counts) do
        local j = stats.get_flow_count({ name = name, category = "input", precision_index = PRECISION })
        if j and j > 0 then
          by_consumer[name] = q(j)
          consumed = consumed + j
        end
      end

      networks[#networks + 1] = {
        id = pole.electric_network_id,
        -- Joules over the one-minute window; the sidecar turns these into watts.
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

--- Split a payload across datagrams and emit it.
---
--- helpers.send_udp silently discards anything larger than the Ethernet MTU
--- payload (1472 bytes), measured on 2.0.77 - the loopback MTU of 65536 does
--- not apply and no error is raised, the datagram simply never leaves. So every
--- payload is chunked, with a "<id>|<index>|<total>|" header the sidecar
--- reassembles on.
local function send(port, payload)
  local json = helpers.table_to_json(payload)
  local total = math.max(1, math.ceil(#json / CHUNK_BYTES))

  storage.seq = (storage.seq or 0) + 1
  local id = storage.seq

  for i = 1, total do
    local part = string.sub(json, (i - 1) * CHUNK_BYTES + 1, i * CHUNK_BYTES)
    helpers.send_udp(port, id .. "|" .. i .. "|" .. total .. "|" .. part, 0)
  end

  return #json
end

--- Returns the datagram size emitted per surface, which is the number that
--- decides whether a snapshot survives the UDP size ceiling.
local function snapshot()
  if not setting("fb-enabled") then return end

  local port = setting("fb-udp-port")
  local tick = game.tick
  local force = game.forces["player"]
  if not (port and force and force.valid) then return end

  local sizes = {}

  local rescan_ticks = (setting("fb-network-rescan-seconds") or 300) * 60
  if not storage.last_rescan or tick - storage.last_rescan >= rescan_ticks then
    rescan_networks()
  end

  local surface_names = {}

  for _, surface in pairs(game.surfaces) do
    local items = read_flow(force.get_item_production_statistics(surface))
    local fluids = read_flow(force.get_fluid_production_statistics(surface))

    surface_names[#surface_names + 1] = surface.name
    sizes[surface.name] = send(port, {
      k = "surface",
      v = PROTOCOL_VERSION,
      t = tick,
      name = surface.name,
      platform = surface.platform ~= nil,
      pollution = q(surface.get_total_pollution()),
      items = items,
      fluids = fluids,
      power = read_power(surface.name),
      logistics = read_logistics(force, surface.name),
    })
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

  -- Sent last so the sidecar can treat "meta" as the end-of-snapshot marker.
  sizes.meta = send(port, {
    k = "meta",
    v = PROTOCOL_VERSION,
    t = tick,
    mod_version = script.active_mods["factorio-broadcast"],
    speed = q(game.speed),
    paused = game.tick_paused,
    surfaces = surface_names,
    research = research,
    rockets = force.rockets_launched,
    evolution = q(force.get_evolution_factor(game.surfaces.nauvis) * 100),
    players_online = #game.connected_players,
    players = players,
  })

  return sizes
end

local function reschedule()
  script.on_nth_tick(nil)
  local interval = setting("fb-interval-ticks") or 60
  script.on_nth_tick(interval, function()
    -- A malformed snapshot must never take the save down with it.
    local ok, err = pcall(snapshot)
    if not ok then
      log("[factorio-broadcast] snapshot failed: " .. tostring(err))
    end
  end)
end

script.on_init(function()
  storage.poles = {}
  rescan_networks()
  reschedule()
end)

script.on_load(reschedule)

script.on_configuration_changed(function()
  storage.poles = storage.poles or {}
  rescan_networks()
  reschedule()
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == "fb-interval-ticks" then reschedule() end
end)

-- Electric networks merge and split as poles are built or destroyed, so the
-- cached one-pole-per-network list goes stale; refresh it on the next tick.
local function invalidate(_)
  storage.last_rescan = nil
end

-- RCON caps how long a single command may be, so anything an operator or an
-- agent needs to ask the mod goes through short remote.call rather than being
-- pasted in as Lua.
remote.add_interface("factorio-broadcast", {
  --- Emit a snapshot immediately; returns the datagram size per surface.
  send_now = function()
    return snapshot()
  end,

  --- Cheap liveness/config check.
  ping = function()
    return {
      version = script.active_mods["factorio-broadcast"],
      tick = game.tick,
      port = setting("fb-udp-port"),
      interval = setting("fb-interval-ticks"),
      enabled = setting("fb-enabled"),
      surfaces = #game.surfaces,
    }
  end,
})

script.on_event(defines.events.on_built_entity, invalidate, { { filter = "type", type = "electric-pole" } })
script.on_event(defines.events.on_robot_built_entity, invalidate, { { filter = "type", type = "electric-pole" } })
script.on_event(defines.events.on_entity_died, invalidate, { { filter = "type", type = "electric-pole" } })
script.on_event(defines.events.on_player_mined_entity, invalidate, { { filter = "type", type = "electric-pole" } })
