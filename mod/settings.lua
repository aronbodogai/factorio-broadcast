data:extend({
  {
    type = "bool-setting",
    name = "fb-enabled",
    setting_type = "runtime-global",
    default_value = true,
    order = "a",
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
    default_value = "5s,1m,10m,1h,10h,50h,250h,1000h",
    allow_blank = false,
    order = "e",
  },
  {
    -- A ceiling on how many items per surface get a graph series. The default
    -- is high enough that every item moving in the window gets one; lower it on
    -- a save large enough for that to cost real time. Zero disables history.
    type = "int-setting",
    name = "fb-history-items",
    setting_type = "runtime-global",
    default_value = 1000,
    minimum_value = 0,
    maximum_value = 1000,
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
  {
    -- The long windows (1h and up) are refreshed every Nth snapshot rather than
    -- every one: a 1000-hour average does not move perceptibly in a second.
    type = "int-setting",
    name = "fb-slow-every",
    setting_type = "runtime-global",
    default_value = 30,
    minimum_value = 1,
    maximum_value = 600,
    order = "h",
  },
})
