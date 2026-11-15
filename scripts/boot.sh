#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
export DEBIAN_FRONTEND=noninteractive

MNT=/mnt/vpsdata

mkdir -p /etc/vps /etc/vps/scripts "$RUN" "$MNT" /var/cache/rclone-vps
chmod 755 /etc/vps /etc/vps/scripts
chmod 1777 "$RUN"
cp -f "$SCRIPTS"/* /etc/vps/scripts/
chmod 755 /etc/vps/scripts/*
SCRIPTS=/etc/vps/scripts

apt-get update -qq
apt-get install -y -qq fuse3 restic jq curl rsync tmux python3-pip python3-venv > /dev/null
curl -fsSL https://rclone.org/install.sh | bash > /dev/null 2>&1 || apt-get install -y -qq rclone > /dev/null

grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null || echo "user_allow_other" >> /etc/fuse.conf

apt-mark showmanual | sort > /var/lib/vps-apt-baseline.txt

id dev > /dev/null 2>&1 || useradd -m -u 2000 -s /bin/bash dev
echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev; chmod 440 /etc/sudoers.d/dev

rclone mkdir gdrive:vps/data

modprobe fuse 2>/dev/null || true
chmod 666 /dev/fuse 2>/dev/null || true

MOUNT_OPTS="--allow-other --uid 2000 --gid 2000 --umask 022 \
  --vfs-cache-mode full --vfs-cache-max-size 6G --vfs-cache-max-age 24h \
  --dir-cache-time 15s --poll-interval 15s --vfs-write-back 5s \
  --cache-dir /var/cache/rclone-vps --rc --rc-addr 127.0.0.1:5572 --rc-no-auth \
  --log-file /tmp/rclone-mount.log -v"

start_mount() {
  : > /tmp/rclone-mount.log
  nohup rclone mount gdrive:vps/data "$MNT" $MOUNT_OPTS > /dev/null 2>&1 &
  for _ in $(seq 1 30); do mountpoint -q "$MNT" && return 0; sleep 1; done
  return 1
}

if ! start_mount; then
  log "mount failed, log:"
  cat /tmp/rclone-mount.log || true
  pkill -f "rclone mount" 2>/dev/null || true
  log "disabling fusermount3 AppArmor profile and retrying..."
  apparmor_parser -R /etc/apparmor.d/fusermount3 2>/dev/null || true
  sleep 2
  start_mount || true
fi

mountpoint -q "$MNT" || { log "Drive mount failed"; cat /tmp/rclone-mount.log; dmesg 2>/dev/null | grep -i apparmor | tail -n 5 || true; exit 1; }

if [ -d /data ] && [ ! -L /data ]; then rmdir /data 2>/dev/null || true; fi
ln -sfn "$MNT" /data
log "Drive mounted on $MNT (linked as /data)"

rclone mkdir gdrive:vps/restic
restic cat config > /dev/null 2>&1 || restic init 2>/dev/null || log "Restic repo already exists, continuing..."
if [ "$(restic snapshots --tag home --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
  log "Restoring state from Drive..."
  restic restore latest --tag home --target / --overwrite if-changed --retry-lock 3m || log "Restic restore warning (non-fatal)"
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
[ "$PWD" = "$HOME" ] && cd "$HOME/downloads" 2>/dev/null || true
RC
  chown dev:dev "$H/.bashrc"
fi

if ! grep -q ".bashrc" "$H/.bash_profile" 2>/dev/null; then
  echo '[ -f ~/.bashrc ] && . ~/.bashrc' >> "$H/.bash_profile"
  chown dev:dev "$H/.bash_profile"
fi

install_extras

if [ "${STANDBY:-false}" = "true" ]; then
  echo standby > "$RUN/role"; echo hot > "$RUN/mode"
else
  echo active > "$RUN/role"; echo all > "$RUN/mode"
fi
chmod 666 "$RUN/role" "$RUN/mode"

sudo -u dev -H setsid nohup bash "$SCRIPTS/supervisor.sh" >> "$H/.logs/supervisor.log" 2>&1 &
TSIP=$(tailscale ip -4 | head -1)
setsid nohup python3 "$SCRIPTS/ctl.py" "$TSIP" "$SCRIPTS" > /tmp/ctl.log 2>&1 &
setsid nohup bash "$SCRIPTS/periodic.sh" > /tmp/periodic.log 2>&1 &
sleep 3
touch "$RUN/ready"
log "Node is ready. Role: $(cat "$RUN/role") | IP: $TSIP"
