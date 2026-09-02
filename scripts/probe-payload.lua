-- Diagnostic: report the JSON size the mod would emit for each surface, and
-- whether a datagram of that size actually reaches the sidecar.
local force = game.forces["player"]
local PRECISION = defines.flow_precision_index.one_minute

local function q(x) return math.floor((x or 0) * 100 + 0.5) end

local function read_flow(stats)
  local out = { input = {}, output = {} }
  for name in pairs(stats.input_counts) do
    out.input[name] = q(stats.get_flow_count({ name = name, category = "input", precision_index = PRECISION }))
  end
  for name in pairs(stats.output_counts) do
    out.output[name] = q(stats.get_flow_count({ name = name, category = "output", precision_index = PRECISION }))
  end
  return out
end

local report = {}
for _, surface in pairs(game.surfaces) do
  local seen, networks = {}, {}
  for _, pole in pairs(surface.find_entities_filtered({ type = "electric-pole" })) do
    local id = pole.electric_network_id
    if id and not seen[id] then
      seen[id] = true
      local stats = pole.electric_network_statistics
      local producers, consumers = {}, {}
      for name in pairs(stats.output_counts) do
        producers[name] = q(stats.get_flow_count({ name = name, category = "output", precision_index = PRECISION }))
      end
      for name in pairs(stats.input_counts) do
        consumers[name] = q(stats.get_flow_count({ name = name, category = "input", precision_index = PRECISION }))
      end
      networks[#networks + 1] = { id = id, producers = producers, consumers = consumers }
    end
  end

  local payload = {
    k = "surface",
    v = 1,
    t = game.tick,
    name = surface.name,
    pollution = q(surface.get_total_pollution()),
    items = read_flow(force.get_item_production_statistics(surface)),
    fluids = read_flow(force.get_fluid_production_statistics(surface)),
    power = networks,
  }
  local json = helpers.table_to_json(payload)
  report[#report + 1] = surface.name .. "=" .. #json .. "B/" .. #networks .. "nets"

  -- Send a marker of the same length, so a size-related drop shows up as a
  -- missing marker on the sidecar side.
  helpers.send_udp(settings.global["fb-udp-port"].value, string.rep("X", #json), 0)
end

rcon.print(table.concat(report, " "))
