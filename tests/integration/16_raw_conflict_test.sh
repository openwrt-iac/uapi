#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- POST /raw/firewall with explicit id 'rUapiTestRule' ---"
first=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/firewall" -d '{
	".type": "rule",
	"id": "rUapiTestRule",
	"target": "ACCEPT",
	"src": "lan"
}')
echo "$first"
status=$(echo "$first" | tail -1)
[ "$status" = "200" ] || fail "first POST expected 200, got $status"

cleanup() {
	curl -sS -H "$ADMIN" -X DELETE "$URL/raw/firewall/rUapiTestRule" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "--- POST same explicit id again → expect 409 conflict ---"
second=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/firewall" -d '{
	".type": "rule",
	"id": "rUapiTestRule",
	"target": "DROP",
	"src": "lan"
}')
echo "$second"
status=$(echo "$second" | tail -1)
[ "$status" = "409" ] || fail "duplicate-id POST expected 409, got $status"
echo "$second" | grep -q '"code": "conflict"' || fail "missing conflict code"

echo "--- POST with malformed id (dot) → expect 422 invalid_format ---"
bad=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/firewall" -d '{
	".type": "rule",
	"id": "bad.name",
	"target": "ACCEPT",
	"src": "lan"
}')
echo "$bad"
status=$(echo "$bad" | tail -1)
[ "$status" = "422" ] || fail "malformed-id POST expected 422, got $status"
echo "$bad" | grep -q '"code": "validation_failed"' || fail "missing validation_failed code"
echo "$bad" | grep -q '"field": "id"' || fail "missing field=id in errors"
echo "$bad" | grep -q '"code": "invalid_format"' || fail "missing invalid_format field code"

echo "raw create: 409 on duplicate id, 422 on malformed id."
