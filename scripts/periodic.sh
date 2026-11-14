#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"
START=$(date +%s)
N=0
while sleep 60; do
  role=$(cat "$RUN/role" 2>/dev/null)
  if [ "$role" = active ]; then
    N=$((N+1))
    flock -n /run/vps/backup.lock bash "$SCRIPTS/backup.sh" || true
    if [ $((N % 30)) -eq 0 ]; then
      flock -n /run/vps/backup.lock restic forget --tag home --keep-last 30 --keep-hourly 24 --keep-daily 7 --retry-lock 3m --quiet || true
    fi
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