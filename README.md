# ZFS Backups from prox->borgprox and WOL for borgprox


There are two different /etc/sanoid/sanoid.conf files  :

## etc
Defines snapshotting and pruning policy on prox 
## etcborg
Defines pruning only on borgprox

# Set up

Link to the file in the correct subdir


> ln -sf /root/repos/proxmox/zfs/etc(borg)/sanoid/sanoid.conf /etc/sanoid/sanoid.conf

start the sanoid timer on each machine

> systemctl enable --now sanoid.timer

cron job on prox deals with WOL and running the two syncoid commands. Install with crontab -e
to run at 3 every morning

 3 * * * /root/repos/proxmox/zfs/cron-backup.sh >> /var/log/zfs-backup.log 2>&1

