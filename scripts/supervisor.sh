#!/usr/bin/env bash
# supervises ~/services/*/run according to /run/vps/mode  (all | hot | stop)
shopt -s nullglob
SV=/home/dev/services
RUN=/run/vps
export HOME=/home/dev
export USER=dev
export NPM_CONFIG_PREFIX=$HOME/.npm-global
export PATH=$HOME/.npm-global/bin:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p "$SV" /home/dev/.logs

running() { [ -f "$RUN/pid.$1" ] && kill -0 "$(cat "$RUN/pid.$1")" 2>/dev/null; }

start_svc() {
  (
    cd "$SV/$1" || exit 1
    setsid bash "$SV/$1/run" >> "/home/dev/.logs/$1.log" 2>&1 < /dev/null &
    echo $! > "$RUN/pid.$1"
    echo "[$(date +%T)] start $1 (pid $!)"
  )
}

stop_svc() {
  local p; p=$(cat "$RUN/pid.$1" 2>/dev/null)
  if [ -n "$p" ]; then
    kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
    sleep 5
    kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true
  fi
  rm -f "$RUN/pid.$1"
  echo "[$(date +%T)] stop $1"
}

while true; do
  mode=$(cat "$RUN/mode" 2>/dev/null || echo stop)
  for d in "$SV"/*/; do
    [ -f "${d}run" ] || continue
    n=$(basename "$d")
    want=no
    case "$mode" in
      all) want=yes ;;
      hot) [ -f "${d}exclusive" ] || want=yes ;;
    esac
    [ -f "${d}disabled" ] && want=no
    if [ "$want" = yes ] && ! running "$n"; then start_svc "$n"; fi
    if [ "$want" = no ] && running "$n"; then stop_svc "$n"; fi
  done
  sleep 5
done
