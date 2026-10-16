#!/bin/sh
# Fails unless the kernel config meets moby's "Generally Necessary" list.
# The iptables/xtables options are exempt: dockerd runs with
# firewall-backend=nftables, which needs none of them.
# Usage: check-docker-config.sh <check-config.sh> <kernel .config>
set -eu
script=$1
config=$2

# check-config.sh greps through zgrep, falling back to zcat when zgrep is
# absent (Alpine), so hand it a gzipped config.
gz=$(mktemp)
gzip -c "$config" >"$gz"
out=$(CONFIG="$gz" NO_COLOR=1 sh "$script" 2>&1 || true)
rm -f "$gz"

required=$(printf '%s\n' "$out" | sed -n '/^Generally Necessary/,/^Optional Features/p')
printf '%s\n' "$required"
missing=$(printf '%s\n' "$required" | grep -oE 'CONFIG_[A-Z0-9_]+: missing' | cut -d: -f1 |
	grep -vE '^CONFIG_(IP_NF_|IP6_NF_|NETFILTER_XT_)' || true)
present=$(printf '%s\n' "$required" | grep -cE 'CONFIG_[A-Z0-9_]+: enabled' || true)

if [ "$present" -eq 0 ]; then
	echo "check-config.sh reported no enabled options; is the config readable?" >&2
	exit 1
fi
if [ -n "$missing" ]; then
	echo "missing required kernel options:" >&2
	echo "$missing" >&2
	exit 1
fi
echo "kernel config satisfies Docker's requirements ($present required options enabled)"
