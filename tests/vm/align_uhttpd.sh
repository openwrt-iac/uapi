#!/bin/sh
# The release image ships uhttpd and uhttpd-mod-ubus from the release build, and the feed is
# rebuilt after the release. uhttpd and its plugins share structs with no version pin between
# them: under uhttpd 2026.08.24, uhttpd-mod-ucode 2026.11.05 stops uhttpd at its start
# ("Unable to open ucode handler"), and under uhttpd 2026.11.05, uhttpd-mod-ubus 2026.08.24
# segfaults it on the first /ubus request. `apk add` of a dependency installs the plugin alone,
# so the family is aligned on the feed first, as docs/installation.md tells an operator to do.
set -eu
"$(dirname "$0")/ssh.sh" '
	apk update >/dev/null 2>&1 || { echo "apk update failed in the VM"; exit 1; }
	out=$(apk upgrade uhttpd uhttpd-mod-ubus uhttpd-mod-ucode uhttpd-mod-lua 2>&1) \
		|| { echo "$out"; echo "apk upgrade of the uhttpd family failed in the VM"; exit 1; }
	echo "$out" | tail -5
	apk list -I 2>/dev/null | grep "^uhttpd" | cut -d" " -f1
'
