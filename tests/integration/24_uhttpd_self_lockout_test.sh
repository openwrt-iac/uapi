#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

UAPI_PREFIX="/api/v1=/usr/share/uapi/main.uc"

echo "--- uhttpd/instances: GET main shows uapi's ucode_prefix entry ---"
got=$(call "$URL/uhttpd/instances/main")
echo "$got" | head -1 | grep -q "$UAPI_PREFIX" \
	|| fail "main instance should already have $UAPI_PREFIX in ucode_prefix"

echo "--- uhttpd/instances: PATCH main without ucode_prefix is rejected with 422 conflict ---"
patch_response=$(call -X PATCH -H 'Content-Type: application/json' \
	"$URL/uhttpd/instances/main" -d '{ "ucode_prefix": [] }')
echo "$patch_response"
status=$(echo "$patch_response" | tail -1)
[ "$status" = "422" ] || fail "expected 422 (self-lockout block), got $status"
echo "$patch_response" | head -1 | grep -q '"code": "conflict"' \
	|| fail "expected field-level conflict on ucode_prefix"

echo "--- uhttpd/instances: PATCH main with bogus listen_http is rejected with 422 invalid_format ---"
bad_listen=$(call -X PATCH -H 'Content-Type: application/json' \
	"$URL/uhttpd/instances/main" -d '{ "listen_http": ["not-a-host:port"] }')
echo "$bad_listen" | tail -1 | grep -q '^422$' \
	|| fail "expected 422 on bad listen_http format"

echo "--- uhttpd/instances: PATCH main that keeps the uapi prefix succeeds ---"
keep=$(call -X PATCH -H 'Content-Type: application/json' \
	"$URL/uhttpd/instances/main" -d "{\"ucode_prefix\": [\"$UAPI_PREFIX\"]}")
echo "$keep" | tail -1 | grep -q '^200$' \
	|| fail "expected 200 for a PATCH that retains the uapi prefix"

echo "uhttpd/instances self-lockout protection ok."
