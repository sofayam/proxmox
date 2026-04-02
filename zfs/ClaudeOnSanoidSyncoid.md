# ZFS Snapshot Management: Sanoid & Syncoid

## Overview

This document describes the automated ZFS snapshot and replication setup on the Proxmox homelab. The solution uses two tools:

- **Sanoid** — manages local snapshots on the primary host (creates and prunes according to a retention policy)
- **Syncoid** — replicates snapshots from the primary host to the backup host over SSH

The primary host is `prox`. The backup host is `borgprox.local`, a secondary machine that is WOL'd before each backup run.

---

## Dataset Layout

The primary host has the following datasets under the `tank` pool:

```
tank/appdata              # Application data (Docker volumes, configs, etc.)
tank/vmstore              # Parent dataset for VM disks
  tank/vmstore/vm-100-disk-0
  tank/vmstore/vm-101-disk-0
  tank/vmstore/vm-102-disk-0
  tank/vmstore/vm-102-disk-1
```

The backup host mirrors this layout under a pool called `backup`:

```
backup/appdata
backup/vmstore            # Child datasets created automatically by Syncoid
```

---

## Sanoid Configuration

File location on primary host: `/etc/sanoid/sanoid.conf`

```ini
[tank/appdata]
    use_template = production

[tank/vmstore]
    use_template = production
    recursive = yes

[template_production]
    frequently = 0
    hourly     = 4
    daily      = 30
    monthly    = 3
    yearly     = 0
    autosnap   = yes
    autoprune  = yes
```

### Retention policy

| Frequency | Count kept |
|-----------|-----------|
| Hourly | 4 |
| Daily | 30 |
| Monthly | 3 |
| Yearly | 0 |

### Notes

- `tank/vmstore` uses `recursive = yes`, so all four VM disk datasets underneath are covered without listing them individually.
- `tank` itself is not snapshotted — it is just a container with negligible data of its own.
- Sanoid deliberately ignores snapshots prefixed with `syncoid_`, so it never prunes a snapshot that Syncoid needs for incremental replication.
- Snapshots of running VMs are crash-consistent, not application-consistent. This is the same behaviour as a manual `zfs snapshot`.

### Running Sanoid

Sanoid ships with a systemd timer. Enable it once on the primary host:

```bash
systemctl enable --now sanoid.timer
```

Verify it is working after the first run:

```bash
sanoid --take-snapshots --verbose
zfs list -t snapshot | head -20
```

---

## Syncoid Replication

Syncoid wraps `zfs send/receive` and handles incremental sends, SSH transport, and compression automatically. It finds the most recent common snapshot between source and destination and sends only the delta. The first run is always a full send.

### Replication script

```bash
#!/bin/bash
echo "=== $(date) ===" >> /var/log/syncoid.log
syncoid --no-privilege-elevation --no-sync-snap --recursive tank/appdata borgprox.local:backup/appdata >> /var/log/syncoid.log 2>&1
syncoid --no-privilege-elevation --no-sync-snap --recursive tank/vmstore borgprox.local:backup/vmstore >> /var/log/syncoid.log 2>&1
```

Two separate calls are needed because `tank/appdata` and `tank/vmstore` share no common parent worth replicating.

### Key flags

- `--no-privilege-elevation` — do not use sudo on the remote end. Since we SSH as root, privilege elevation is unnecessary and sudo may not be installed.
- `--no-sync-snap` — instead of creating named `syncoid_...` snapshots to track replication state, use ZFS bookmarks. Bookmarks are invisible to `zfs list -t snapshot`, keeping the snapshot listing clean.
- `--recursive` — replicate all child datasets.

### Prerequisites

- SSH key auth from `root@prox` to `root@borgprox.local` must be configured.
- The destination datasets must **not** exist before the first sync. Syncoid creates them itself as part of the initial full send. If they already exist with no common snapshot history, Syncoid will refuse to proceed.

---

## Sanoid on the Backup Host

Sanoid also runs on `borgprox.local` to prune replicated snapshots according to the same retention policy, but with `autosnap = no` so it never creates snapshots of its own.

File location: `/etc/sanoid/sanoid.conf` on `borgprox.local`

```ini
[backup/appdata]
    use_template = sink

[backup/vmstore]
    use_template = sink
    recursive = yes

[template_sink]
    frequently = 0
    hourly     = 4
    daily      = 30
    monthly    = 3
    yearly     = 0
    autosnap   = no
    autoprune  = yes
```

Enable the timer on the backup host:

```bash
systemctl enable --now sanoid.timer
```

---

## Logging and Log Rotation

Syncoid output is appended to `/var/log/syncoid.log` by the replication script above.

Logrotate config at `/etc/logrotate.d/syncoid`:

```
/var/log/syncoid.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
```

Sanoid logs via systemd. View with:

```bash
journalctl -u sanoid.service
```

---

## What is Not Covered

Syncoid only replicates ZFS datasets. Proxmox VM configuration files live outside ZFS at `/etc/pve/qemu-server/*.conf` and are not included in this backup setup. A separate mechanism (rsync, Proxmox Backup Server, or similar) is needed to back those up.

