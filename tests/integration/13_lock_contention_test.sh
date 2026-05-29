#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# Hold the global flock from outside uapi so the next write transaction can't
# acquire it. This is the same lock acquired by transaction.run_inner.
echo "--- start a background lock-holder on /var/lock/uapi.lock ---"
$SSH 'flock -nx /var/lock/uapi.lock -c "sleep 5" >/dev/null 2>&1 &' &
sleep 1

echo "--- POST while the lock is held → expect 423 locked + Retry-After ---"
resp=$(curl -sS -i -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" -d '{
	"target": "ACCEPT",
	"match": { "src_zone": "lan", "dest_port": ["8888"], "proto": ["tcp"] }
}')
echo "$resp" | head -30
echo "$resp" | head -1 | grep -q ' 423 ' || fail "expected 423 status line"
echo "$resp" | grep -i '^Retry-After:' || fail "expected Retry-After header"
echo "$resp" | grep -q '"code": "locked"' || fail "expected locked envelope"

echo "--- wait for the background lock-holder to release ---"
sleep 5

echo "--- the same POST now succeeds (lock released) ---"
resp=$(curl -sS -w "\n%{http_code}" -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" -d '{
	"target": "ACCEPT",
	"match": { "src_zone": "lan", "dest_port": ["8889"], "proto": ["tcp"] }
}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "post-release POST expected 200, got $status"

id=$(echo "$body" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$id" ] && curl -sS -H "$ADMIN" -X DELETE "$URL/firewall/rules/$id" >/dev/null || true

echo "lock contention returns 423 with Retry-After."
