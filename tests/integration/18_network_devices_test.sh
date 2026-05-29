#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- POST /network/devices creates a bridge ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/network/devices" -d '{
	"name": "br-uapi-test",
	"type": "bridge",
	"ports": ["eth0"]
}')
echo "$created"
echo "$created" | tail -1 | grep -q '^200$' || fail "POST expected 200"
id=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$id" ] || fail "POST missing id"

cleanup() { curl -sS -H "$ADMIN" -X DELETE "$URL/network/devices/$id" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

echo "--- GET /network/devices/$id ---"
got=$(call "$URL/network/devices/$id")
echo "$got" | tail -1 | grep -q '^200$' || fail "GET expected 200"
echo "$got" | grep -q '"name": "br-uapi-test"' || fail "GET missing name"
echo "$got" | grep -q '"type": "bridge"' || fail "GET missing type"

echo "--- validate: bridge without ports is rejected ---"
bad=$(call -X POST -H 'Content-Type: application/json' "$URL/network/devices" -d '{
	"name": "br-bad", "type": "bridge"
}')
echo "$bad" | tail -1 | grep -q '^422$' || fail "bridge without ports expected 422"
echo "$bad" | grep -q '"field": "ports"' || fail "expected error on ports field"

echo "--- validate: type 8021q without vid is rejected ---"
bad_vlan=$(call -X POST -H 'Content-Type: application/json' "$URL/network/devices" -d '{
	"name": "vlan-bad", "type": "8021q"
}')
echo "$bad_vlan" | tail -1 | grep -q '^422$' || fail "8021q without vid expected 422"

echo "--- PATCH /network/devices/$id (update ports list) ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/devices/$id" -d '{
	"ports": ["eth0", "eth1"]
}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200"
echo "$patched" | grep -q '"eth1"' || fail "PATCH did not record new port"

echo "--- DELETE /network/devices/$id ---"
call -X DELETE "$URL/network/devices/$id" | tail -1 | grep -q '^204$' || fail "DELETE expected 204"

echo "network.devices CRUD ok."
