#!/bin/sh
# openwrt-sdk.sh - resolve and fetch the OpenWrt SDK tarball for one target.
#
# Usage:
#   tools/openwrt-sdk.sh name <target>           print the tarball filename
#   tools/openwrt-sdk.sh key <target>            print the cache key: the filename and the start of its sha256
#   tools/openwrt-sdk.sh fetch <target> [dest]   download, verify, extract into dest
#
# target is an OpenWrt target path, e.g. x86/64 or armsr/armv8. The series comes
# from $OPENWRT_SERIES (stable by default, main on the v4 line) and the stable
# version from $OPENWRT_VERSION.
#
# The stable series pins the tarball by checksum in build/sdk.sha256: a version
# bump that forgets the pin fails here, before any build. A main snapshot has no
# filename to pin (the gcc version is part of it), so the sha256sums published
# beside the tarball are the pin there.
set -eu

cmd=${1:?usage: openwrt-sdk.sh name|key|fetch <target> [dest]}
target=${2:?usage: openwrt-sdk.sh name|key|fetch <target> [dest]}
dest=${3:-build/sdk}
series=${OPENWRT_SERIES:-stable}
version=${OPENWRT_VERSION:-25.12.6}

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# x86/64 -> x86-64, armsr/armv8 -> armsr-armv8: the target path is the filename
# segment the SDK tarball is named by.
segment=$(printf '%s' "$target" | tr / -)

if [ "$series" = main ]; then
	base=https://downloads.openwrt.org/snapshots/targets/$target
	sums=$(mktemp)
	curl -fsSL --http1.1 --retry 3 --retry-all-errors "$base/sha256sums" -o "$sums"
	line=$(grep -m1 "openwrt-sdk-${segment}_gcc-.*Linux-x86_64\.tar\.zst" "$sums")
else
	base=https://downloads.openwrt.org/releases/$version/targets/$target
	if ! line=$(grep -m1 "  openwrt-sdk-$version-${segment}_gcc-" "$root/build/sdk.sha256"); then
		echo "ERROR: build/sdk.sha256 does not pin the $version SDK for $target." >&2
		echo "Refresh the pins from the upstream sha256sums whenever OPENWRT_VERSION bumps." >&2
		exit 1
	fi
	sums="$root/build/sdk.sha256"
fi

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
if [ "$series" = main ]; then
	printf '%s\n' "$line" > /tmp/openwrt-sdk-sums.one
	( cd /tmp && sha256sum -c openwrt-sdk-sums.one )
else
	# --ignore-missing: the pin file covers every arch, /tmp holds only this one.
	( cd /tmp && sha256sum --check "$sums" --ignore-missing )
fi
tar --use-compress-program=unzstd -xf "/tmp/$tarball" -C "$dest" --strip-components=1
rm -f "/tmp/$tarball"
