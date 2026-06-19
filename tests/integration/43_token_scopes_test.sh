#!/bin/sh
set -eu

# 2.3.0: `uapi-token scopes` enumerates the known scope tree for external
# consumers (the upcoming luci-app-uapi scope picker, fleet tooling).

. tests/integration/lib/install_uapi.sh
install_uapi

fail() { echo "FAIL: $*"; exit 1; }

echo "--- uapi-token scopes prints one path per line, sorted, including sentinels ---"
plain=$($SSH "uapi-token scopes" 2>&1)
echo "$plain" | head -5
[ -n "$plain" ] || fail "plain output empty"
echo "$plain" | grep -qx '\*' || fail "missing '*' sentinel"
echo "$plain" | grep -qx 'raw' || fail "missing 'raw' sentinel"
echo "$plain" | grep -qx 'system' || fail "missing 'system' scope"
echo "$plain" | grep -qx 'firewall:zones' || fail "missing 'firewall:zones' sample"
echo "$plain" | grep -qx 'network:interfaces' || fail "missing 'network:interfaces' sample"

echo "--- output is sorted (LC_ALL=C asciibetical) ---"
sorted=$(printf '%s' "$plain" | LC_ALL=C sort)
[ "$plain" = "$sorted" ] || fail "output is not sorted"

echo "--- --json emits a parseable JSON array of strings ---"
json=$($SSH "uapi-token scopes --json" 2>&1)
echo "$json" | head -c 80; echo
echo "$json" | grep -q '^\[' || fail "json output does not start with '['"
echo "$json" | grep -q '\]$' || fail "json output does not end with ']'"
echo "$json" | grep -q '"\*"' || fail "json missing '*' sentinel"
echo "$json" | grep -q '"network:interfaces"' || fail "json missing network:interfaces"

echo "OK"
