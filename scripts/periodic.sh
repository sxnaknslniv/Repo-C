#!/usr/bin/env bash
# backup every 10 min (active only); an orphan standby promotes itself after 25 min
. "$(dirname "$0")/lib.sh"
START=$(date +%s)
while sleep 600; do
  role=$(cat "$RUN/role" 2>/dev/null)
  if [ "$role" = active ]; then
    bash "$SCRIPTS/backup.sh"
  elif [ "$role" = standby ] && [ $(( $(date +%s) - START )) -gt 1500 ]; then
    other=0
    for ip in $(tailscale status --json | jq -r '.Peer[]? | select(.Online==true) | select(.HostName|test("^vps-[0-9]+")) | .TailscaleIPs[] | select(startswith("100."))'); do
      [ "$(curl -s --max-time 3 "http://$ip:9001/role")" = active ] && other=1
    done
    if [ "$other" = 0 ]; then
      log "No active node found after 25m, self-promoting..."
      bash "$SCRIPTS/sync_in.sh"
    fi
  fi
done
