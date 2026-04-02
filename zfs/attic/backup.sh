#!/bin/bash
# zfs-sync.sh — incremental ZFS send/receive between two hosts
#
# Usage:
#   First run (full send):   ./zfs-sync.sh <dataset> --full
#   Subsequent runs:         ./zfs-sync.sh <dataset>
#
# Example: ./zfs-sync.sh appdata
#
# Configuration — edit these:
SRC_POOL="tank"
DST_HOST="root@borgprox.local"
DST_POOL="ssdtank"

DATASET="${1:-}"
[ -z "${DATASET}" ] && { echo "Usage: $0 <dataset> [--full]" >&2; exit 1; }

SRC_DATASET="${SRC_POOL}/${DATASET}"
DST_DATASET="${DST_POOL}/${DATASET}"

SNAP_PREV="${SRC_DATASET}@sync-prev"
SNAP_NEW="${SRC_DATASET}@sync-new"
DST_SNAP_PREV="${DST_DATASET}@sync-prev"

# Colour output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*" >&2; exit 1; }

# ─── Full send (first run) ────────────────────────────────────────────────────

full_send() {
    log "Starting full send of ${SRC_DATASET}"

    # Clean up any stale @sync-prev on source before starting
    zfs list -t snapshot "${SNAP_PREV}" > /dev/null 2>&1 \
        && { warn "Stale @sync-prev found on source — destroying"; zfs destroy -r "${SNAP_PREV}"; }

    zfs snapshot -r "${SNAP_PREV}" \
        || die "Failed to create snapshot ${SNAP_PREV}"

    log "Sending full stream to ${DST_HOST}:${DST_DATASET} ..."
    zfs send -Rcv "${SNAP_PREV}" \
        | ssh "${DST_HOST}" zfs receive -F "${DST_DATASET}" \
        || die "zfs send/receive failed"

    log "Full send complete. Destination has @sync-prev ready for incrementals."
}

# ─── Incremental send ─────────────────────────────────────────────────────────

incremental_send() {
    log "Starting incremental send of ${SRC_DATASET}"

    # Verify base snapshot exists on source
    zfs list -t snapshot "${SNAP_PREV}" > /dev/null 2>&1 \
        || die "${SNAP_PREV} not found on source — run with --full first"

    # Verify base snapshot exists on destination
    ssh "${DST_HOST}" zfs list -t snapshot "${DST_SNAP_PREV}" > /dev/null 2>&1 \
        || die "@sync-prev not found on destination — run with --full first"

    # Clean up any stale @sync-new from a previous failed run
    zfs list -t snapshot "${SNAP_NEW}" > /dev/null 2>&1 \
        && { warn "Stale @sync-new found on source — destroying"; zfs destroy -r "${SNAP_NEW}"; }
    ssh "${DST_HOST}" zfs list -t snapshot "${DST_DATASET}@sync-new" > /dev/null 2>&1 \
        && { warn "Stale @sync-new found on destination — destroying"; ssh "${DST_HOST}" zfs destroy -r "${DST_DATASET}@sync-new"; }

    # On the destination, rename @sync-prev to a timestamp BEFORE the receive.
    # This preserves it as a recovery point and clears the way for -F to work
    # cleanly without destroying our accumulated history.
    TODAY=$(date +%Y-%m-%d-%H-%M-%S)
    log "Archiving @sync-prev to @${TODAY} on destination ..."
    ssh "${DST_HOST}" zfs rename "${DST_SNAP_PREV}" \
                                 "${DST_DATASET}@${TODAY}" \
        || die "Failed to archive @sync-prev on destination — aborting"

    # Take new snapshot on source
    zfs snapshot -r "${SNAP_NEW}" \
        || die "Failed to create snapshot ${SNAP_NEW}"

    # Send incremental — -F is safe now because @sync-prev no longer exists on
    # the destination; the only snapshot there is the timestamped archive.
    log "Sending incremental stream to ${DST_HOST}:${DST_DATASET} ..."
    zfs send -Rcv -i "${SNAP_PREV}" "${SNAP_NEW}" \
        | ssh "${DST_HOST}" zfs receive -F "${DST_DATASET}" \
        || {
            zfs destroy -r "${SNAP_NEW}"
            # Restore @sync-prev on destination so next run can retry
            ssh "${DST_HOST}" zfs rename "${DST_DATASET}@${TODAY}" "${DST_SNAP_PREV}"
            die "zfs send/receive failed — rolled back, @sync-prev restored on destination"
        }

    # Rename the received @sync-new to @sync-prev on destination
    log "Renaming @sync-new to @sync-prev on destination ..."
    ssh "${DST_HOST}" zfs rename "${DST_DATASET}@sync-new" \
                                 "${DST_SNAP_PREV}" \
        || die "Failed to rename @sync-new to @sync-prev on destination — manual intervention needed"

    # Rotate on source — only now that receive succeeded
    log "Rotating snapshots on source ..."
    zfs destroy -r "${SNAP_PREV}" \
        || warn "Failed to destroy old @sync-prev on source — continuing anyway"
    zfs rename -r "${SNAP_NEW}" "${SNAP_PREV}" \
        || die "Failed to rename @sync-new to @sync-prev on source — manual intervention needed"

    log "Incremental send complete."
}

# ─── Entry point ──────────────────────────────────────────────────────────────

case "${2:-}" in
    --full) full_send ;;
    "")     incremental_send ;;
    *)      die "Unknown argument: $2. Use --full or no argument." ;;
esac
