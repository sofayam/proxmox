#!/bin/bash
# cron-backup.sh — wake borgprox if needed, run ZFS sync, shut it back down if we woke it

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DST_HOST="root@borgprox.local"
WOL_SCRIPT="${SCRIPT_DIR}/../wol/wol.py"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*" >&2; exit 1; }

is_up() {
    ssh -o ConnectTimeout=5 -o BatchMode=yes "${DST_HOST}" exit 2>/dev/null
}

# ─── Check if already running ─────────────────────────────────────────────────

WE_WOKE_IT=false

if is_up; then
    log "borgprox is already up"
else
    log "borgprox is down — sending WoL magic packet ..."
    python3 "${WOL_SCRIPT}" || die "WoL script failed"
    WE_WOKE_IT=true

    log "Waiting for borgprox to come up ..."
    TIMEOUT=120
    ELAPSED=0
    while ! is_up; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))
        if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
            die "borgprox did not come up after ${TIMEOUT}s"
        fi
        log "  ... still waiting (${ELAPSED}s)"
    done
    log "borgprox is up (${ELAPSED}s)"
fi

# ─── Run backup ───────────────────────────────────────────────────────────────

"${SCRIPT_DIR}/backup.sh" || die "Backup failed"

# ─── Shut down if we woke it ──────────────────────────────────────────────────

if [ "${WE_WOKE_IT}" = true ]; then
    log "Shutting borgprox back down ..."
    ssh "${DST_HOST}" "./adios.sh" \
        || warn "Shutdown command failed — borgprox may still be running"
fi
