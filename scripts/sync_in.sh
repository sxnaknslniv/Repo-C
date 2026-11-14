#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/lib.sh"
log "Pulling latest snapshot..."
restic restore latest --tag home --target / --overwrite if-changed --retry-lock 3m || exit 1
chown -R dev:dev "$HOME_DIR" 2>/dev/null || true
install_extras
echo all > "$RUN/mode"
echo active > "$RUN/role"
log "Promoted to ACTIVE"