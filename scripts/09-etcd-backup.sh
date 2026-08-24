#!/usr/bin/env bash
# Gate 7 / Category E — take an etcd backup via the standard
# cluster-backup.sh on the control-plane node, then copy it off-node.
#
# Usage: ./09-etcd-backup.sh <node-name> [local-destination-dir]
#
# Note: on SNO, restore support is limited (Constraint C6) — this backup
# exists primarily for forensics / rebuild-and-restore, not necessarily a
# fast in-place rollback. Take it anyway, every time.
set -euo pipefail

NODE="${1:?node name required, e.g. master01}"
DEST="${2:-./etcd-backups/$(date +%Y%m%dT%H%M%S)}"
mkdir -p "$DEST"

echo "Confirming cluster-backup.sh exists on $NODE ..."
oc debug --as-root node/"$NODE" -- chroot /host ls -l /usr/local/bin/cluster-backup.sh

echo
echo "Running backup on the node (writes under /home/core/assets/backup by convention;"
echo "adjust the path below if your cluster uses a different backup directory) ..."
BACKUP_DIR_ON_NODE="/home/core/assets/backup/$(date +%Y%m%dT%H%M%S)"
oc debug --as-root node/"$NODE" -- chroot /host mkdir -p "$BACKUP_DIR_ON_NODE"
oc debug --as-root node/"$NODE" -- chroot /host /usr/local/bin/cluster-backup.sh "$BACKUP_DIR_ON_NODE"

echo
echo "Backup written on-node at: $BACKUP_DIR_ON_NODE"
echo "Copy it off-node NOW — a backup that only exists on the node you are about"
echo "to upgrade is not a backup. Example (adjust for your access method):"
echo
echo "  oc debug --as-root node/${NODE} -- chroot /host tar -C $(dirname "$BACKUP_DIR_ON_NODE") -czf - $(basename "$BACKUP_DIR_ON_NODE") \\"
echo "    > \"$DEST/etcd-backup-${NODE}.tar.gz\""
echo
echo "Or via SSH/console access to the node directly with scp/rsync to $DEST."
