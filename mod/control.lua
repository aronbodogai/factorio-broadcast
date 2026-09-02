-- Mod entry point. The implementation lives in broadcast.lua so the same file
-- can be shipped as a softmod inside a save; see scripts/make-scenario.py.
local broadcast = require("broadcast")

broadcast.setup(function()
  return {
    enabled = settings.global["fb-enabled"].value,
    port = settings.global["fb-udp-port"].value,
    interval = settings.global["fb-interval-ticks"].value,
    rescan_seconds = settings.global["fb-network-rescan-seconds"].value,
    windows = settings.global["fb-windows"].value,
    history_items = settings.global["fb-history-items"].value,
    history_every = settings.global["fb-history-every"].value,
  }
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == "fb-interval-ticks" then
    broadcast.reschedule()
  end
end)
