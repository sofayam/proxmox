# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A small collection of Proxmox/homelab shell scripts for ZFS backup sync and Wake-on-LAN management.

## Structure

- `wol/` — Wake-on-LAN helpers run on the Proxmox host before shutdown
- `zfs/` — ZFS send/receive sync script (`backup.sh`); `backup.sh.orig` is the original template with placeholder values

## Key design: ZFS sync (`zfs/backup.sh`)

Uses a two-snapshot rotation (`@sync-prev`, `@sync-new`) to drive incremental `zfs send | ssh zfs receive`:

1. `--full`: creates `@sync-prev`, sends full stream, renames destination snapshot to `@YYYY-MM-DD`
2. *(no args)*: creates `@sync-new`, sends incremental from `@sync-prev`, renames destination to `@YYYY-MM-DD-HH-MM-SS`, then rotates source (`destroy @sync-prev`, rename `@sync-new` → `@sync-prev`)

The destination SSH check (`zfs list -t snapshot … @sync-prev`) is intentionally commented out in the current version — the `.orig` file has it active.

## Deployment context

Scripts run directly on a Proxmox host (root). No build step, no tests, no package manager. Edit and deploy via `scp` or direct edit on the host.

Target hosts:
- Source: Proxmox node (runs the scripts)
- Destination: `root@borgprox.local`, dataset `ssdtank/appdata`
- NIC for WoL: `enp37s0`
