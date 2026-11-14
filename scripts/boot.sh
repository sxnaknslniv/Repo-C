#!/usr/bin/env bash
# runs once when a node starts (as root)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
export DEBIAN_FRONTEND=noninteractive

mkdir -p /etc/vps "$RUN" /data /var/cache/rclone-vps
chmod 1777 "$RUN"
printf '%s\n' "$RCLONE_CONF" > "$RCLONE_CONFIG";            chmod 600 "$RCLONE_CONFIG"
printf '%s\n' "$RESTIC_PASSWORD" > "$RESTIC_PASSWORD_FILE"; chmod 600 "$RESTIC_PASSWORD_FILE"

apt-get update -qq
apt-get install -y -qq fuse3 restic jq curl rsync tmux python3-pip python3-venv > /dev/null
curl -fsSL https://rclone.org/install.sh | bash > /dev/null 2>&1 || apt-get install -y -qq rclone > /dev/null

grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null || echo "user_allow_other" >> /etc/fuse.conf

# baseline of manually installed packages (so we can tell what YOU install later)
apt-mark showmanual | sort > /var/lib/vps-apt-baseline.txt

id dev > /dev/null 2>&1 || useradd -m -u 2000 -s /bin/bash dev
echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev; chmod 440 /etc/sudoers.d/dev

# ---------- shared Drive storage on /data ----------
rclone mkdir gdrive:vps/data
rclone mount gdrive:vps/data /data --daemon --allow-other --uid 2000 --gid 2000 --umask 022 \
  --vfs-cache-mode full --vfs-cache-max-size 6G --vfs-cache-max-age 24h \
  --dir-cache-time 15s --poll-interval 15s --vfs-write-back 5s \
  --cache-dir /var/cache/rclone-vps --rc --rc-addr 127.0.0.1:5572 --rc-no-auth

for _ in $(seq 1 30); do mountpoint -q /data && break; sleep 1; done
mountpoint -q /data || { log "Drive mount failed, check RCLONE_CONF"; exit 1; }

# ---------- restore machine state (home + package list) ----------
rclone mkdir gdrive:vps/restic
restic cat config > /dev/null 2>&1 || restic init
if [ "$(restic snapshots --tag home --json | jq 'length')" -gt 0 ]; then
  log "Restoring state from Drive..."
  restic restore latest --tag home --target / --overwrite if-changed --retry-lock 3m
else
  log "First boot: no saved state found"
fi

H=$HOME_DIR
mkdir -p "$H/.vps" "$H/services" "$H/.logs" "$H/projects" "$H/.local/bin" "$H/.npm-global"
chown -R dev:dev "$H"

[ -L "$H/data" ] || [ -e "$H/data" ] || sudo -u dev ln -s /data "$H/data"
sudo -u dev mkdir -p /data/downloads
[ -L "$H/downloads" ] || [ -e "$H/downloads" ] || sudo -u dev ln -s /data/downloads "$H/downloads"

if ! grep -q NPM_CONFIG_PREFIX "$H/.bashrc" 2>/dev/null; then
  cat >> "$H/.bashrc" << 'RC'
export NPM_CONFIG_PREFIX=$HOME/.npm-global
export PATH=$HOME/.npm-global/bin:$HOME/.local/bin:$PATH
RC
  chown dev:dev "$H/.bashrc"
fi

if ! grep -q ".bashrc" "$H/.bash_profile" 2>/dev/null; then
  echo '[ -f ~/.bashrc ] && . ~/.bashrc' >> "$H/.bash_profile"
  chown dev:dev "$H/.bash_profile"
fi

install_extras

# ---------- role: standby (waits for handoff) or active ----------
if [ "${STANDBY:-false}" = "true" ]; then
  echo standby > "$RUN/role"; echo hot > "$RUN/mode"
else
  echo active > "$RUN/role"; echo all > "$RUN/mode"
fi
chmod 666 "$RUN/role" "$RUN/mode"

sudo -u dev -H setsid nohup bash "$SCRIPTS/supervisor.sh" > /tmp/supervisor.log 2>&1 &
TSIP=$(tailscale ip -4 | head -1)
setsid nohup python3 "$SCRIPTS/ctl.py" "$TSIP" "$SCRIPTS" > /tmp/ctl.log 2>&1 &
setsid nohup bash "$SCRIPTS/periodic.sh" > /tmp/periodic.log 2>&1 &
sleep 3
touch "$RUN/ready"
log "Node is ready. Role: $(cat "$RUN/role") | IP: $TSIP"
