#!/bin/bash
# zfs-sync.sh — incremental ZFS send/receive between two hosts
#
# Usage:
#   First run (full send):   ./zfs-sync.sh --full
#   Subsequent runs:         ./zfs-sync.sh
#
# Configuration — edit these:
SRC_DATASET="sourcepool/data/vm-100-disk-0"
DST_HOST="root@192.168.1.100"
DST_DATASET="destpool/data/vm-100-disk-0"

SNAP_PREV="${SRC_DATASET}@sync-prev"
SNAP_NEW="${SRC_DATASET}@sync-new"

# Colour output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $*"; }
die()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*" >&2; exit 1; }

# ─── Full send (first run) ────────────────────────────────────────────────────

full_send() {
    log "Starting full send of ${SRC_DATASET}"

    zfs snapshot "${SNAP_PREV}" \
        || die "Failed to create snapshot ${SNAP_PREV}"

    log "Sending full stream to ${DST_HOST}:${DST_DATASET} ..."
    zfs send -cv "${SNAP_PREV}" \
        | ssh "${DST_HOST}" zfs receive "${DST_DATASET}" \
        || die "zfs send/receive failed"

    # Stamp the snapshot on the destination with today's date
    TODAY=$(date +%Y-%m-%d)
    log "Renaming @sync-prev to @${TODAY} on destination ..."
    ssh "${DST_HOST}" zfs rename "${DST_DATASET}@sync-prev" \
                                 "${DST_DATASET}@${TODAY}" \
        || warn "Rename on destination failed — snapshot is safe but name is still @sync-prev"

    log "Full send complete."
}

# ─── Incremental send ─────────────────────────────────────────────────────────

incremental_send() {
    log "Starting incremental send of ${SRC_DATASET}"

    # Verify base snapshot exists on source
    zfs list -t snapshot "${SNAP_PREV}" > /dev/null 2>&1 \
        || die "${SNAP_PREV} not found on source — run with --full first"

    # Verify base snapshot exists on destination
    ssh "${DST_HOST}" zfs list -t snapshot "${DST_DATASET}@sync-prev" > /dev/null 2>&1 \
        || die "@sync-prev not found on destination — run with --full first"

    # Take new snapshot
    zfs snapshot "${SNAP_NEW}" \
        || die "Failed to create snapshot ${SNAP_NEW}"

    # Send incremental
    log "Sending incremental stream to ${DST_HOST}:${DST_DATASET} ..."
    zfs send -cv -i "${SNAP_PREV}" "${SNAP_NEW}" \
        | ssh "${DST_HOST}" zfs receive -F "${DST_DATASET}" \
        || { zfs destroy "${SNAP_NEW}"; die "zfs send/receive failed — rolled back, @sync-prev intact"; }

    # Stamp the received snapshot on the destination with today's date
    TODAY=$(date +%Y-%m-%d)
    log "Renaming @sync-new to @${TODAY} on destination ..."
    ssh "${DST_HOST}" zfs rename "${DST_DATASET}@sync-new" \
                                 "${DST_DATASET}@${TODAY}" \
        || warn "Rename on destination failed — snapshot is safe but name is still @sync-new"

    # Rotate on source — only now that receive and rename succeeded
    log "Rotating snapshots on source ..."
    zfs destroy "${SNAP_PREV}" \
        || warn "Failed to destroy old @sync-prev — continuing anyway"
    zfs rename "${SNAP_NEW}" "${SNAP_PREV}" \
        || die "Failed to rename @sync-new to @sync-prev — manual intervention needed"

    log "Incremental send complete."
}

# ─── Entry point ──────────────────────────────────────────────────────────────

case "${1:-}" in
    --full) full_send ;;
    "")     incremental_send ;;
    *)      die "Unknown argument: $1. Use --full or no argument." ;;
esac
