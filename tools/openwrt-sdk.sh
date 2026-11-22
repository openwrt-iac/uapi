#!/bin/sh
# openwrt-sdk.sh - resolve and fetch the OpenWrt main snapshot SDK for one target.
#
# Usage:
#   tools/openwrt-sdk.sh name <target>           print the tarball filename
#   tools/openwrt-sdk.sh key <target>            print the cache key: the filename and the start of its sha256
#   tools/openwrt-sdk.sh fetch <target> [dest]   download, verify, extract into dest
#
# target is an OpenWrt target path, e.g. x86/64 or armsr/armv8.
#
# A snapshot SDK changes daily and keeps its filename, and OpenWrt deletes the previous one, so no
# checksum in the repo can pin it. The pin is the key instead: fetch checks the signature of the
# sha256sums published beside the tarball against build/openwrt-snapshot-usign.pub, the usign key
# of the OpenWrt snapshot builds, and then the tarball against those sums. SIGNIFY names the
# verifier, signify-openbsd by default; usign takes the same arguments.
set -eu

cmd=${1:?usage: openwrt-sdk.sh name|key|fetch <target> [dest]}
target=${2:?usage: openwrt-sdk.sh name|key|fetch <target> [dest]}
dest=${3:-build/sdk}

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# x86/64 -> x86-64, armsr/armv8 -> armsr-armv8: the target path is the filename
# segment the SDK tarball is named by.
segment=$(printf '%s' "$target" | tr / -)

base=https://downloads.openwrt.org/snapshots/targets/$target
sums=$(mktemp)
curl -fsSL --http1.1 --retry 3 --retry-all-errors "$base/sha256sums" -o "$sums"
line=$(grep -m1 "openwrt-sdk-${segment}_gcc-.*Linux-x86_64\.tar\.zst" "$sums")

tarball=${line##* }
tarball=${tarball#\*}

if [ "$cmd" = name ]; then
	echo "$tarball"
	exit 0
fi
# A snapshot SDK keeps its filename across the daily rebuilds, so the name alone kept serving the
# SDK of the first run.
if [ "$cmd" = key ]; then
	echo "$tarball-$(printf '%s' "${line%% *}" | cut -c1-16)"
	exit 0
fi
if [ "$cmd" != fetch ]; then
	echo "unknown command: $cmd" >&2
	exit 2
fi

curl -fsSL --http1.1 --retry 3 --retry-all-errors "$base/sha256sums.sig" -o "$sums.sig"
"${SIGNIFY:-signify-openbsd}" -V -q -p "$root/build/openwrt-snapshot-usign.pub" -x "$sums.sig" -m "$sums"

mkdir -p "$dest"
# The CDN cuts long transfers, and curl's own --retry starts the file over even with -C -, so each
# attempt is a new curl that resumes from the partial file. A partial file left by an earlier run
# would be resumed too. A fixed count of attempts ran out 38 MB short of a 300 MB snapshot SDK, so
# only attempts that add nothing count against the limit.
rm -f "/tmp/$tarball"
got=0
stalled=0
until curl -fsSL --http1.1 -C - -o "/tmp/$tarball" "$base/$tarball"; do
	now=$(wc -c < "/tmp/$tarball" 2>/dev/null || echo 0)
	if [ "$now" -gt "$got" ]; then stalled=0; else stalled=$((stalled + 1)); fi
	got=$now
	[ $stalled -lt 5 ] || exit 1
	sleep 5
done
printf '%s\n' "$line" > /tmp/openwrt-sdk-sums.one
( cd /tmp && sha256sum -c openwrt-sdk-sums.one )
tar --use-compress-program=unzstd -xf "/tmp/$tarball" -C "$dest" --strip-components=1
rm -f "/tmp/$tarball"
