#!/usr/bin/env bash
# Verifies the "softmod" route: can the broadcast run from a save's scenario
# script, with NO mod installed? If so, joining clients need no mod download,
# because a scenario script travels inside the save.
#
# Runs on its own ports so the normal dev server can keep running.
set -euo pipefail

FB="${FB_HOME:-$HOME/fb}"
FACTORIO="$FB/factorio/bin/x64/factorio"
INSTANCE="$FB/instance"
SAVE="$INSTANCE/scenario-test.zip"
MODS="$INSTANCE/mods-vanilla"
LOG="$INSTANCE/scenario.log"
PIDFILE="$INSTANCE/scenario.pid"

GAME_PORT=34220
LUA_UDP_PORT=34221
RCON_PORT=27016
TAP_PORT=41235

start() {
  mkdir -p "$MODS"
  cat > "$MODS/mod-list.json" <<'JSON'
{
  "mods": [
    { "name": "base", "enabled": true },
    { "name": "elevated-rails", "enabled": true },
    { "name": "quality", "enabled": true },
    { "name": "space-age", "enabled": true }
  ]
}
JSON

  setsid bash -c 'echo $$ > "$1"; exec "$2" \
      --start-server "$3" \
      --server-settings "$4" \
      --mod-directory "$5" \
      --rcon-bind "127.0.0.1:$6" \
      --rcon-password devpass \
      --enable-lua-udp "$7" \
      --port "$8"' _ \
    "$PIDFILE" "$FACTORIO" "$SAVE" "$INSTANCE/server-settings.json" "$MODS" \
    "$RCON_PORT" "$LUA_UDP_PORT" "$GAME_PORT" \
    </dev/null >"$LOG" 2>&1 &

  for _ in $(seq 1 120); do
    grep -q 'Starting RCON interface' "$LOG" 2>/dev/null && { echo "scenario server ready (pid $(cat "$PIDFILE"))"; return 0; }
    sleep 1
  done
  echo "scenario server did not come up" >&2
  tail -20 "$LOG" >&2
  return 1
}

stop() {
  [[ -f "$PIDFILE" ]] || { echo "not running"; return; }
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
  echo "scenario server stopped"
}

case "${1:-run}" in
  start) start ;;
  stop)  stop ;;
  run)
    start
    echo "--- mods actually loaded ---"
    grep -E 'Checksum of|Loading mod ' "$LOG" | grep -v 'mod settings' | head -8
    echo "--- tapping udp $TAP_PORT for 6s (no mod installed) ---"
    "${FB_NODE:-$HOME/fb/node/bin/node}" "$(dirname "${BASH_SOURCE[0]}")/udp-tap.js" "$TAP_PORT" 6
    ;;
  *) echo "usage: $0 {run|start|stop}" >&2; exit 64 ;;
esac
