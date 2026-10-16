#!/bin/sh
# Checks dockma-disk's decision on disk images: only a blank disk may ever be
# formatted. Runs in the Dockerfile's rootfs stage.
# Usage: dockma-disk-test.sh <dockma-disk> <guest busybox>
set -eu
script=$1
busybox=$2

tmpdir=$(mktemp -d)
trap 'rm -rf -- "${tmpdir:?}"' EXIT
# The guest's blkid is busybox's; it prints nothing for a damaged superblock.
mkdir "$tmpdir/bin"
ln -s "$busybox" "$tmpdir/bin/blkid"
export PATH="$tmpdir/bin:$PATH"

failures=0
expect() {
	got=$(DOCKMA_DISK_DRYRUN=1 sh "$script" "$tmpdir/$1" /unused)
	if [ "$got" = "$2" ]; then
		echo "ok   $1: $got"
	else
		echo "FAIL $1: got $got, want $2"
		failures=$((failures + 1))
	fi
}
image() { truncate -s 1G "$tmpdir/$1"; }
ext4() { image "$1" && mke2fs -q -t ext4 -L dockma-data "$tmpdir/$1"; }
zero() { dd if=/dev/zero of="$tmpdir/$1" bs=1024 seek="$2" count="$3" conv=notrunc 2>/dev/null; }

image blank.img
expect blank.img format

ext4 intact.img
expect intact.img check

ext4 bad-superblock.img
zero bad-superblock.img 1 1
expect bad-superblock.img refuse

ext4 zeroed-start.img
zero zeroed-start.img 0 1024
expect zeroed-start.img refuse

image random.img
dd if=/dev/urandom of="$tmpdir/random.img" bs=4096 count=1 conv=notrunc 2>/dev/null
expect random.img refuse

[ "$failures" -eq 0 ] || { echo "$failures dockma-disk check(s) failed"; exit 1; }
echo "dockma-disk never formats a non-blank disk"
