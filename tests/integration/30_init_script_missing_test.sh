#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- sqm-scripts is intentionally NOT installed on the VM; sqm/queues writes should fail-fast ---"
$SSH "test -x /etc/init.d/sqm" && fail "test assumption violated: /etc/init.d/sqm exists on this VM"

echo "--- POST /sqm/queues returns 503 init_script_missing (NOT 500 reload_failed_*) ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/sqm/queues" -d '{
  "interface": "wan", "download": 90000, "upload": 10000,
  "qdisc": "cake", "script": "piece_of_cake.qos"
}')
status=$(echo "$r" | tail -1)
body=$(echo "$r" | head -1)
echo "$body"
[ "$status" = "503" ] || fail "expected 503, got $status"
echo "$body" | grep -q '"code": "init_script_missing"' || fail "expected init_script_missing code"
echo "$body" | grep -q '/etc/init.d/sqm not found' || fail "expected init.d path in message"

echo "--- uci state UNCHANGED (pre-flight fired before any write) ---"
$SSH "uci show sqm 2>&1 | grep -E '^sqm\.q_' && exit 1; true" \
  || fail "uci has a managed sqm queue section despite the 503"

echo "--- resources with no reload services are unaffected ---"
# dhcp/leases is read-only; should still be 200.
call "$URL/dhcp/leases" | tail -1 | grep -q '^200$' \
  || fail "/dhcp/leases regression"

echo "--- resources whose daemon IS installed work normally ---"
# firewall reload uses /etc/init.d/firewall which exists on every OpenWrt.
r=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/rules" -d '{
  "name": "uapi-init-test", "target": "ACCEPT", "enabled": true,
  "match": { "src_zone": "wan", "proto": ["tcp"], "dest_port": ["55555"] }
}')
echo "$r" | tail -1 | grep -q '^200$' || fail "firewall rule create regression"
fid=$(echo "$r" | head -1 | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
call -X DELETE "$URL/firewall/rules/$fid" | tail -1 | grep -q '^204$' \
  || fail "firewall rule delete regression"

echo "init_script_missing pre-flight ok."
