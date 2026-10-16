#!/bin/sh
# Checks that dockma-motd always runs and that every quip, in its speech
# bubble, fits an 80-column terminal. Runs in the Dockerfile's rootfs stage.
# Usage: dockma-motd-test.sh <dockma-motd> <guest busybox>
set -eu
script=$1
busybox=$2

all=$("$busybox" sh "$script" --all)
# Plain ASCII keeps byte counts equal to display columns. The bubble adds four
# columns around a quip, so everything must fit in 76.
if printf '%s\n' "$all" | LC_ALL=C grep -n '[^ -~]'; then
	echo "FAIL: non-printable or non-ASCII characters in the whale or quips"
	exit 1
fi
if printf '%s\n' "$all" | awk 'length > 76 { print NR ": " $0; bad = 1 } END { exit !bad }'; then
	echo "FAIL: lines wider than 76 columns"
	exit 1
fi

i=0
while [ "$i" -lt 20 ]; do
	out=$(TERM=xterm "$busybox" sh "$script")
	case $out in
	*Linux\ *) ;;
	*) echo "FAIL: run $i printed no status line: $out"; exit 1 ;;
	esac
	i=$((i + 1))
done
echo "dockma-motd: 20 random runs ok, every quip bubble fits 80 columns"
