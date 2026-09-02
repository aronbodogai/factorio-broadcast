#!/usr/bin/env bash
# Cross-check the sidecar's UPS figure against a direct tick measurement.
# The sidecar derives UPS from snapshot arrivals; this measures it independently
# by asking the server for game.tick twice, a known wall-clock apart.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECONDS_TO_SAMPLE="${1:-8}"
NODE="${FB_NODE:-$HOME/fb/node/bin/node}"

tick() {
  bash "$REPO/scripts/dev.sh" rcon '/silent-command rcon.print(game.tick)' | tr -dc '0-9'
}

t1="$(tick)"
s1="$(date +%s.%N)"
sleep "$SECONDS_TO_SAMPLE"
t2="$(tick)"
s2="$(date +%s.%N)"

sidecar="$(curl -s http://127.0.0.1:8099/health | "$NODE" -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const u=JSON.parse(d).ups;process.stdout.write(u===null?"n/a":u.toFixed(2))})')"

"$NODE" -e "
const t1=$t1, t2=$t2, s1=$s1, s2=$s2;
console.log('ticks   ', t1, '->', t2, '(' + (t2-t1) + ' ticks in ' + (s2-s1).toFixed(2) + 's)');
console.log('measured', ((t2-t1)/(s2-s1)).toFixed(2), 'UPS');
console.log('sidecar ', '$sidecar', 'UPS');
"
