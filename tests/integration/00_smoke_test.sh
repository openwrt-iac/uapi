#!/bin/sh
set -eu

SSH="tests/vm/ssh.sh"

# ubus is the canonical liveness signal for OpenWrt.
out=$($SSH 'ubus call system info' 2>&1)
echo "$out" | head -3

echo "$out" | grep -q '"uptime"' || { echo "FAIL: ubus call system info missing uptime"; exit 1; }
echo "$out" | grep -q '"memory"' || { echo "FAIL: ubus call system info missing memory"; exit 1; }

$SSH 'uci get system.@system[0].hostname' | grep -q . \
	|| { echo "FAIL: uci get returned empty hostname"; exit 1; }

$SSH 'pgrep uhttpd' >/dev/null \
	|| { echo "FAIL: uhttpd is not running in the VM"; exit 1; }

echo "smoke ok"
