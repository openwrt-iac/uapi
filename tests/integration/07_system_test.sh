#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
RO="Authorization: Bearer $RO_TOKEN"

fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

original_hostname=$($SSH 'uci -q get system.@system[0].hostname' || echo OpenWrt)
echo "  original hostname: $original_hostname"

echo "--- GET /system returns the current config ---"
got=$(call "$URL/system")
echo "$got"
echo "$got" | tail -1 | grep -q '^200$' || fail "GET expected 200"
echo "$got" | grep -q '"hostname"' || fail "missing hostname field"

echo "--- PATCH /system updates hostname ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/system" -d '{"hostname":"uapi-test-host"}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200"
echo "$patched" | grep -q '"hostname": "uapi-test-host"' || fail "PATCH did not update hostname"

echo "--- uci show confirms the change ---"
$SSH "uci get system.@system[0].hostname" | grep -q '^uapi-test-host$' || fail "uci show mismatch"

echo "--- POST /system returns 405 ---"
bad=$(call -X POST "$URL/system" -d '{}')
echo "$bad" | tail -1 | grep -q '^405$' || fail "POST expected 405"

echo "--- PATCH with bad hostname returns 422 ---"
invalid=$(call -X PATCH -H 'Content-Type: application/json' "$URL/system" -d '{"hostname":"bad name"}')
echo "$invalid" | tail -1 | grep -q '^422$' || fail "bad hostname expected 422"

echo "--- read-only token can GET but not PATCH ---"
ro_get=$(curl -sS -H "$RO" -w "\n%{http_code}" "$URL/system")
echo "$ro_get" | tail -1 | grep -q '^200$' || fail "ro GET expected 200"
ro_patch=$(curl -sS -H "$RO" -w "\n%{http_code}" -X PATCH -H 'Content-Type: application/json' "$URL/system" -d '{"hostname":"x"}')
echo "$ro_patch" | tail -1 | grep -q '^403$' || fail "ro PATCH expected 403"

echo "--- restore original hostname ---"
call -X PATCH -H 'Content-Type: application/json' "$URL/system" -d "{\"hostname\":\"$original_hostname\"}" >/dev/null

echo "system singleton ok"
