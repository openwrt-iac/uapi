#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

cleanup() {
	$SSH "uci show dropbear 2>/dev/null | grep -E 'd_[a-z0-9]+=dropbear' | sed 's/=.*//' | xargs -r -n1 uci delete; uci commit dropbear" >/dev/null 2>&1 || true
	$SSH "/etc/init.d/dropbear reload" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "--- dropbear/instances: POST a second instance on a high port ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/dropbear/instances" -d '{
	"Port": 22422,
	"PasswordAuth": false,
	"RootPasswordAuth": false,
	"RootLogin": true
}')
echo "$created"
status=$(echo "$created" | tail -1)
[ "$status" = "200" ] || fail "POST expected 200, got $status"
did=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')

echo "--- dropbear/instances: response normalizes PasswordAuth to a JSON bool ---"
echo "$created" | head -1 | grep -q '"PasswordAuth": false' \
	|| fail "expected PasswordAuth=false on read"

echo "--- dropbear/instances: PATCH changes the port ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' \
	"$URL/dropbear/instances/$did" -d '{ "Port": 22423 }')
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200"

echo "--- dropbear/instances: invalid Port rejected with 422 ---"
bad=$(call -X POST -H 'Content-Type: application/json' "$URL/dropbear/instances" -d '{
	"Port": 99999
}')
echo "$bad" | tail -1 | grep -q '^422$' || fail "expected 422 on bad Port"

echo "--- dropbear/instances: DELETE returns 204 ---"
call -X DELETE "$URL/dropbear/instances/$did" | tail -1 | grep -q '^204$' \
	|| fail "DELETE expected 204"

echo "dropbear/instances CRUD + bool normalization ok."
