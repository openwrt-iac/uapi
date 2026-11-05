#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
SSH="tests/vm/ssh.sh"
fail() { echo "FAIL: $*"; exit 1; }

echo "--- /diagnostics reports no interrupted write on a clean box ---"
curl -sS -H "$ADMIN" "$URL/diagnostics" | jq -c '.interrupted_writes' | grep -q '^\[\]$' \
	|| fail "expected empty interrupted_writes"

echo "--- a record whose process is gone is reported ---"
$SSH 'mkdir -p /var/run/uapi-interrupted-writes && printf "%s" "{\"pid\":99999999,\"request_id\":\"req-old\",\"packages\":[\"network\"],\"staged\":[\"wan\"],\"started_at\":1,\"reload_started\":true}" > /var/run/uapi-interrupted-writes/99999999.json'
out=$(curl -sS -H "$ADMIN" "$URL/diagnostics" | jq -c '.interrupted_writes')
echo "$out" | grep -q '"pid":99999999' || fail "stale record not reported: $out"
echo "$out" | grep -q '"request_id":"req-old"' || fail "request_id missing: $out"
echo "$out" | grep -q '"reload_started":true' || fail "reload_started missing: $out"
$SSH 'rm -f /var/run/uapi-interrupted-writes/99999999.json'

echo "--- after cleanup the list is empty again ---"
curl -sS -H "$ADMIN" "$URL/diagnostics" | jq -c '.interrupted_writes' | grep -q '^\[\]$' \
	|| fail "interrupted_writes not empty after cleanup"

echo "Write journal test ok."
