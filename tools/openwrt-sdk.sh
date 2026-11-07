#!/bin/sh
# openwrt-sdk.sh - resolve and fetch the OpenWrt SDK tarball for one target.
#
# Usage:
#   tools/openwrt-sdk.sh name <target>           print the tarball filename
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

cmd=${1:?usage: openwrt-sdk.sh name|fetch <target> [dest]}
target=${2:?usage: openwrt-sdk.sh name|fetch <target> [dest]}
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
	curl -fsSL --retry 3 --retry-all-errors "$base/sha256sums" -o "$sums"
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
if [ "$cmd" != fetch ]; then
	echo "unknown command: $cmd" >&2
	exit 2
fi

mkdir -p "$dest"
curl -fsSL --retry 3 --retry-all-errors -o "/tmp/$tarball" "$base/$tarball"
if [ "$series" = main ]; then
	printf '%s\n' "$line" > /tmp/openwrt-sdk-sums.one
	( cd /tmp && sha256sum -c openwrt-sdk-sums.one )
else
	# --ignore-missing: the pin file covers every arch, /tmp holds only this one.
	( cd /tmp && sha256sum --check "$sums" --ignore-missing )
fi
tar --use-compress-program=unzstd -xf "/tmp/$tarball" -C "$dest" --strip-components=1
rm -f "/tmp/$tarball"
