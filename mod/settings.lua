data:extend({
  {
    type = "bool-setting",
    name = "fb-enabled",
    setting_type = "runtime-global",
    default_value = true,
    order = "a",
  },
  {
    type = "int-setting",
    name = "fb-udp-port",
    setting_type = "runtime-global",
    default_value = 41234,
    minimum_value = 1,
    maximum_value = 65535,
    order = "b",
  },
  {
    -- How often a snapshot is emitted. 60 ticks = once per in-game second.
    type = "int-setting",
    name = "fb-interval-ticks",
    setting_type = "runtime-global",
    default_value = 60,
    minimum_value = 6,
    maximum_value = 3600,
    order = "c",
  },
  {
    -- Electric poles are rescanned this often to discover new electric networks.
    type = "int-setting",
    name = "fb-network-rescan-seconds",
    setting_type = "runtime-global",
    default_value = 300,
    minimum_value = 10,
    maximum_value = 3600,
    order = "d",
  },
})
