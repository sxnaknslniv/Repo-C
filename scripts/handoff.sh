#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/lib.sh"
elapsed() { echo $(( $(date +%s) - JOB_START )); }

IFS=',' read -ra REPOS <<< "$RING"
N=${#REPOS[@]}
cands=()
for k in $(seq 1 $((N-1))); do cands+=( $(( (MY_ID - 1 + k) % N + 1 )) ); done

runs_of() {
  for s in in_progress queued; do
    curl -sf -H "Authorization: Bearer $PAT" "https://api.github.com/repos/$1/actions/runs?status=$s&per_page=1" | jq '.total_count // 0' 2>/dev/null || echo 0
  done | awk '{n+=$1} END{print n+0}'
}
dispatch() {
  curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $PAT" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$1/actions/workflows/vps.yml/dispatches" \
    -d "{\"ref\":\"$BRANCH\",\"inputs\":{\"standby\":\"true\"}}"
}
discover() {
  tailscale status --json | jq -r --arg n "$1" \
    '[.Peer[]? | select(.Online==true) | select(.HostName | test("^" + $n + "(-[0-9]+)?$"))] | sort_by(.Created) | last | .TailscaleIPs[]? | select(startswith("100."))' | head -n 1
}

handoff_to() {
  local ip=$1
  log "Freezing exclusive services + taking final backup..."
  echo hot > "$RUN/mode"; sleep 10
  flush_data
  bash "$SCRIPTS/backup.sh" || { echo all > "$RUN/mode"; return 1; }
  if curl -sf -X POST --max-time 900 "http://$ip:9001/sync" > /tmp/sync.out; then
    echo retiring > "$RUN/role"
    log "New node is active. Overlapping for ${OVERLAP_SEC}s..."
    sleep "$OVERLAP_SEC"
    echo stop > "$RUN/mode"; sleep 15
    flush_data
    timeout 240 restic forget --tag home --keep-last 12 --prune --retry-lock 1m --quiet || true
    return 0
  fi
  log "Sync failed: $(cat /tmp/sync.out 2>/dev/null)"
  echo all > "$RUN/mode"
  return 1
}

w=$(( HANDOFF_MIN*60 - $(elapsed) )); [ "$w" -gt 0 ] && sleep "$w"

handed=0
while [ "$handed" = 0 ] && [ "$(elapsed)" -lt $((DEADLINE_MIN*60)) ]; do
  for c in "${cands[@]}"; do
    repo=${REPOS[$((c-1))]}; host="vps-$c"
    stop_at=$(( $(elapsed) + PER_CAND_MIN*60 )); max=$((DEADLINE_MIN*60))
    [ "$stop_at" -gt "$max" ] && stop_at=$max
    log "Trying candidate $host ($repo)"
    if [ "$(runs_of "$repo")" -eq 0 ]; then log "dispatch -> HTTP $(dispatch "$repo")"; fi
    IP=""
    while [ "$(elapsed)" -lt "$stop_at" ]; do
      ip=$(discover "$host")
      if [ -n "$ip" ] && curl -sf --max-time 5 "http://$ip:9001/ready" > /dev/null; then IP=$ip; break; fi
      sleep 10
    done
    [ -z "$IP" ] && { log "$host did not become ready in time"; continue; }
    if handoff_to "$IP"; then handed=1; break; fi
  done
  [ "$handed" = 0 ] && sleep 30
done

if [ "$handed" = 1 ]; then
  log "Handoff complete. Shutting down this node."
else
  log "Could not handoff to any candidate. Staying alive until deadline."
  while [ "$(elapsed)" -lt $((352*60)) ]; do sleep 20; done
  bash "$SCRIPTS/backup.sh" || true
fi
exit 0