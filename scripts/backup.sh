#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"
H=$HOME_DIR
mkdir -p "$H/.vps"
apt-mark showmanual | sort > /tmp/apt-now.txt
comm -13 /var/lib/vps-apt-baseline.txt /tmp/apt-now.txt > "$H/.vps/apt-extra.txt"
chown dev:dev "$H/.vps/apt-extra.txt"

restic backup "$H" --tag home \
  --exclude "$H/.cache" \
  --exclude "$H/data" \
  --exclude "$H/downloads" \
  --exclude "$H/.local/share/Trash" \
  --retry-lock 3m --quiet || exit 1

log "Backup completed successfully"