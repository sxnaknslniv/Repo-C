#!/usr/bin/env bash
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f /etc/vps/env ] && . /etc/vps/env

export RCLONE_CONFIG=/etc/vps/rclone.conf
export RESTIC_REPOSITORY="rclone:gdrive:vps/restic"
export RESTIC_PASSWORD_FILE=/etc/vps/restic.pw
HOME_DIR=/home/dev
RUN=/run/vps

log() { echo "[$(date +%H:%M:%S)] $*"; }

flush_data() {
  for _ in $(seq 1 150); do
    q=$(curl -s -X POST http://127.0.0.1:5572/vfs/queue 2>/dev/null | jq '.queue | length' 2>/dev/null)
    [ "${q:-0}" = "0" ] && return 0
    sleep 2
  done
  log "Warning: some files in /data are still uploading to Drive"
}

install_extras() {
  local f="$HOME_DIR/.vps/apt-extra.txt"
  export DEBIAN_FRONTEND=noninteractive
  if [ -s "$f" ]; then
    log "Installing saved apt packages..."
    apt-get update -qq || true
    if ! xargs -r -a "$f" apt-get install -y -qq > /dev/null 2>&1; then
      while read -r p; do
        [ -z "$p" ] && continue
        apt-get install -y -qq "$p" > /dev/null 2>&1 || log "Failed to install: $p"
      done < "$f"
    fi
  fi
  if [ -f "$HOME_DIR/.vps/setup.sh" ]; then
    log "Running setup.sh..."
    sudo -u dev -H bash "$HOME_DIR/.vps/setup.sh" || log "setup.sh failed"
  fi
}