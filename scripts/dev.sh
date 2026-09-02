#!/usr/bin/env bash
# Development driver for factorio-broadcast.
#
# Runs the real Linux headless build inside WSL2 and drives it over RCON, so a
# change to mod/control.lua can be applied and verified without a human.
#
#   ./scripts/dev.sh setup      # one-time: instance dir, mod symlink, save
#   ./scripts/dev.sh start
#   ./scripts/dev.sh rcon '/silent-command rcon.print(game.tick)'
#   ./scripts/dev.sh restart    # after editing the mod
#   ./scripts/dev.sh stop
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FB="${FB_HOME:-$HOME/fb}"
FACTORIO="$FB/factorio/bin/x64/factorio"
INSTANCE="$FB/instance"
MODS="$INSTANCE/mods"
SAVE="$INSTANCE/dev.zip"
SETTINGS="$INSTANCE/server-settings.json"
PIDFILE="$INSTANCE/server.pid"
LOG="$INSTANCE/server.log"
SIDECAR_PID="$INSTANCE/sidecar.pid"
SIDECAR_LOG="$INSTANCE/sidecar.log"

# The Windows Factorio client squats UDP ports around 34197-34210, and WSL2
# mirrored networking can share them, so stay well clear.
GAME_PORT=34198
LUA_UDP_PORT=34200
RCON_PORT=27015
RCON_PASSWORD="${FB_RCON_PASSWORD:-devpass}"

WIN_SAVES="/mnt/c/Users/ideku/AppData/Roaming/Factorio/saves"
NODE="${FB_NODE:-$HOME/fb/node/bin/node}"

server_pid() {
  [[ -f "$PIDFILE" ]] || return 1
  local p
  p="$(cat "$PIDFILE")"
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && echo "$p"
}

cmd_setup() {
  [[ -x "$FACTORIO" ]] || { echo "no headless build at $FACTORIO" >&2; exit 1; }
  mkdir -p "$MODS"

  # A symlink, so editing mod/control.lua on the Windows side is live here.
  if [[ ! -e "$MODS/factorio-broadcast" ]]; then
    ln -s "$REPO/mod" "$MODS/factorio-broadcast"
    echo "symlink: $MODS/factorio-broadcast -> $REPO/mod"
  fi

  if [[ ! -f "$MODS/mod-list.json" ]]; then
    cat > "$MODS/mod-list.json" <<'JSON'
{
  "mods": [
    { "name": "base", "enabled": true },
    { "name": "elevated-rails", "enabled": true },
    { "name": "quality", "enabled": true },
    { "name": "space-age", "enabled": true },
    { "name": "factorio-broadcast", "enabled": true }
  ]
}
JSON
    echo "wrote $MODS/mod-list.json"
  fi

  if [[ ! -f "$SETTINGS" ]]; then
    cat > "$SETTINGS" <<'JSON'
{
  "name": "factorio-broadcast-dev",
  "description": "local dev server",
  "tags": [],
  "max_players": 4,
  "visibility": { "public": false, "lan": true },
  "username": "",
  "password": "",
  "token": "",
  "game_password": "",
  "require_user_verification": false,
  "max_upload_in_kilobytes_per_second": 0,
  "max_upload_slots": 5,
  "minimum_latency_in_ticks": 0,
  "ignore_player_limit_for_returning_players": false,
  "allow_commands": "true",
  "autosave_interval": 0,
  "autosave_slots": 2,
  "afk_autokick_interval": 0,
  "auto_pause": false,
  "only_admins_can_pause_the_game": true,
  "autosave_only_on_server": true,
  "non_blocking_saving": true
}
JSON
    echo "wrote $SETTINGS"
  fi

  cmd_reset_save
  echo "setup complete"
}

# Runtime-global mod settings are stored inside the save, so a changed default
# in mod/settings.lua only takes effect on a save that has never seen the mod.
cmd_reset_save() {
  local source
  source="$(find "$WIN_SAVES" -maxdepth 1 -name '10x *.zip' | head -1)"
  if [[ -n "$source" ]]; then
    cp "$source" "$SAVE"
    echo "save reset from: $source"
  else
    "$FACTORIO" --create "$SAVE" --map-gen-seed 1234 >/dev/null
    echo "created empty save: $SAVE"
  fi
}

cmd_start() {
  if server_pid >/dev/null; then echo "already running (pid $(server_pid))"; return; fi
  [[ -f "$SAVE" ]] || { echo "no save; run: $0 setup" >&2; exit 1; }

  # setsid, not just nohup: WSL kills the whole process group when the wsl.exe
  # session that started it exits, so the server must leave that session.
  # The pid is written by the child itself, because setsid may fork and $! would
  # then name a process that has already exited.
  setsid bash -c 'echo $$ > "$1"; exec "$2" \
      --start-server "$3" \
      --server-settings "$4" \
      --mod-directory "$5" \
      --rcon-bind "127.0.0.1:$6" \
      --rcon-password "$7" \
      --enable-lua-udp "$8" \
      --port "$9"' _ \
    "$PIDFILE" "$FACTORIO" "$SAVE" "$SETTINGS" "$MODS" "$RCON_PORT" "$RCON_PASSWORD" "$LUA_UDP_PORT" "$GAME_PORT" \
    </dev/null >"$LOG" 2>&1 &

  for _ in $(seq 1 20); do [[ -s "$PIDFILE" ]] && break; sleep 0.2; done
  echo "started pid=$(cat "$PIDFILE") rcon=127.0.0.1:$RCON_PORT lua-udp=$LUA_UDP_PORT"
}

cmd_wait_ready() {
  # Poll the log rather than sleeping a fixed amount: load time scales with save size.
  for _ in $(seq 1 120); do
    grep -q 'Starting RCON interface' "$LOG" 2>/dev/null && { echo ready; return 0; }
    server_pid >/dev/null || { echo "server died; see $LOG" >&2; tail -20 "$LOG" >&2; return 1; }
    sleep 1
  done
  echo "timed out waiting for RCON" >&2
  return 1
}

cmd_stop() {
  local p
  p="$(server_pid || true)"
  [[ -n "$p" ]] || { echo "not running"; return; }
  # /quit saves and exits cleanly; SIGKILL loses ticks.
  cmd_rcon '/quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  kill -0 "$p" 2>/dev/null && kill -9 "$p"
  rm -f "$PIDFILE"
  echo stopped
}

cmd_rcon() {
  [[ $# -gt 0 ]] || { echo "usage: $0 rcon '<command>'" >&2; exit 64; }
  "$NODE" "$REPO/scripts/rcon.js" 127.0.0.1 "$RCON_PORT" "$RCON_PASSWORD" "$@"
}

# Run a Lua file against the live server. Keeps real scripts out of shell
# quoting, which is what makes ad-hoc probing painful otherwise.
cmd_rcon_lua() {
  local file="${1:-}"
  [[ -f "$file" ]] || { echo "usage: $0 rcon-lua <file.lua>" >&2; exit 64; }
  cmd_rcon "/silent-command $(tr '\n' ' ' < "$file")"
}

cmd_sidecar_start() {
  if [[ -f "$SIDECAR_PID" ]] && kill -0 "$(cat "$SIDECAR_PID")" 2>/dev/null; then
    echo "sidecar already running (pid $(cat "$SIDECAR_PID"))"; return
  fi
  setsid bash -c 'echo $$ > "$1"; exec "$2" "$3"' _ \
    "$SIDECAR_PID" "$NODE" "$REPO/sidecar/src/index.ts" \
    </dev/null >"$SIDECAR_LOG" 2>&1 &

  for _ in $(seq 1 20); do [[ -s "$SIDECAR_PID" ]] && break; sleep 0.2; done
  echo "sidecar started pid=$(cat "$SIDECAR_PID")"
}

cmd_sidecar_stop() {
  [[ -f "$SIDECAR_PID" ]] || { echo "sidecar not running"; return; }
  kill "$(cat "$SIDECAR_PID")" 2>/dev/null || true
  rm -f "$SIDECAR_PID"
  echo "sidecar stopped"
}

cmd_status() {
  if server_pid >/dev/null; then echo "server: running (pid $(server_pid))"; else echo "server: stopped"; fi
  if [[ -f "$SIDECAR_PID" ]] && kill -0 "$(cat "$SIDECAR_PID")" 2>/dev/null; then
    echo "sidecar: running (pid $(cat "$SIDECAR_PID"))"
  else
    echo "sidecar: stopped"
  fi
  [[ -f "$LOG" ]] && grep -E 'Starting RCON interface|Hosting game|Lua UDP' "$LOG" | tail -3 || true
}

# What an agent greps after a restart to decide whether the change loaded.
cmd_errors() {
  [[ -f "$LOG" ]] || { echo "no log yet"; return; }
  grep -nE 'Error|error while running|failed|cannot' "$LOG" | tail -20 || echo "no errors"
}

case "${1:-status}" in
  setup)          cmd_setup ;;
  start)          cmd_start ;;
  stop)           cmd_stop ;;
  restart)        cmd_stop; cmd_start; cmd_wait_ready ;;
  wait)           cmd_wait_ready ;;
  status)         cmd_status ;;
  errors)         cmd_errors ;;
  logs)           tail -40 "$LOG" ;;
  reset-save)     cmd_reset_save ;;
  sidecar)        cmd_sidecar_start ;;
  sidecar-stop)   cmd_sidecar_stop ;;
  rcon)           shift; cmd_rcon "$@" ;;
  rcon-lua)       shift; cmd_rcon_lua "$@" ;;
  *)              echo "usage: $0 {setup|start|stop|restart|wait|status|errors|logs|reset-save|sidecar|sidecar-stop|rcon}" >&2; exit 64 ;;
esac
