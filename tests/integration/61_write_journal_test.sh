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
plant() { $SSH "mkdir -p /var/run/uapi-interrupted-writes && printf '%s' '{\"pid\":$1,\"request_id\":\"$3\",\"packages\":[\"network\"],\"staged\":[\"wan\"],\"started_at\":1,\"reload_started\":true}' > /var/run/uapi-interrupted-writes/$1-$2.json"; }
plant 99999999 1 req-old
out=$(curl -sS -H "$ADMIN" "$URL/diagnostics" | jq -c '.interrupted_writes')
echo "$out" | grep -q '"pid":99999999' || fail "stale record not reported: $out"
echo "$out" | grep -q '"request_id":"req-old"' || fail "request_id missing: $out"
echo "$out" | grep -q '"reload_started":true' || fail "reload_started missing: $out"

# pid 1 runs, but under another start time: a later process that reused the pid of a killed request.
echo "--- a record whose pid another process now holds is reported ---"
plant 1 999999999 req-reused
out=$(curl -sS -H "$ADMIN" "$URL/diagnostics" | jq -c '.interrupted_writes')
echo "$out" | grep -q '"request_id":"req-reused"' || fail "a record whose pid was reused is hidden: $out"
$SSH 'rm -f /var/run/uapi-interrupted-writes/99999999-1.json /var/run/uapi-interrupted-writes/1-999999999.json'

echo "--- after cleanup the list is empty again ---"
curl -sS -H "$ADMIN" "$URL/diagnostics" | jq -c '.interrupted_writes' | grep -q '^\[\]$' \
	|| fail "interrupted_writes not empty after cleanup"

echo "--- a write that ends leaves no record ---"
r=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" -H 'Content-Type: application/json' -X PATCH "$URL/system" -d '{"description":"uapi-t61"}')
[ "$r" = "200" ] || fail "PATCH /system expected 200, got $r"
[ -z "$($SSH 'ls /var/run/uapi-interrupted-writes 2>/dev/null')" ] || fail "a write that ended left a record: $($SSH 'ls /var/run/uapi-interrupted-writes')"
curl -sS -o /dev/null -H "$ADMIN" -H 'Content-Type: application/json' -X PATCH "$URL/system" -d '{"description":null}'

echo "Write journal test ok."
