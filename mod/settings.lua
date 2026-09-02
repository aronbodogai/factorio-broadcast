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
  {
    -- Which statistics windows to report, comma separated. Valid tokens:
    -- 5s, 1m, 10m, 1h, 10h, 50h, 250h, 1000h. Unknown tokens are ignored.
    type = "string-setting",
    name = "fb-windows",
    setting_type = "runtime-global",
    default_value = "5s,1m,10m,1h",
    allow_blank = false,
    order = "e",
  },
  {
    -- How many items per surface get their 300-sample graph series sent.
    -- Zero disables graph history entirely.
    type = "int-setting",
    name = "fb-history-items",
    setting_type = "runtime-global",
    default_value = 5,
    minimum_value = 0,
    maximum_value = 20,
    order = "f",
  },
  {
    -- Graph history is sent every Nth snapshot, one window per burst.
    type = "int-setting",
    name = "fb-history-every",
    setting_type = "runtime-global",
    default_value = 5,
    minimum_value = 1,
    maximum_value = 60,
    order = "g",
  },
})
