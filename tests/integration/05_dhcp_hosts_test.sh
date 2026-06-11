#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"

fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- POST /dhcp/hosts creates a static lease ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/hosts" -d '{
	"name": "printer",
	"mac": "aa:bb:cc:dd:ee:ff",
	"ip": "192.168.1.50",
	"leasetime": "12h"
}')
echo "$created"
echo "$created" | tail -1 | grep -q '^200$' || fail "POST expected 200"
id=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$id" ] || fail "POST missing id"
echo "  new id: $id"

echo "--- GET shows the lease ---"
got=$(call "$URL/dhcp/hosts/$id")
echo "$got" | tail -1 | grep -q '^200$' || fail "GET expected 200"
echo "$got" | grep -q '"mac": "aa:bb:cc:dd:ee:ff"' || fail "mac missing"

echo "--- POST with invalid MAC returns 422 ---"
invalid=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/hosts" -d '{
	"mac": "garbage", "ip": "10.0.0.1"
}')
echo "$invalid" | tail -1 | grep -q '^422$' || fail "invalid mac expected 422"

echo "--- PATCH updates IP ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/hosts/$id" -d '{"ip": "192.168.1.51"}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200"
echo "$patched" | grep -q '"ip": "192.168.1.51"' || fail "PATCH did not update ip"

echo "--- DELETE returns 204 ---"
deleted=$(call -X DELETE "$URL/dhcp/hosts/$id")
echo "$deleted" | tail -1 | grep -q '^204$' || fail "DELETE expected 204"

echo "--- DNS-only entry: mac + name, no ip ---"
dns_only=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/hosts" -d '{
	"name": "noiphost", "mac": "aa:bb:cc:dd:ee:01"
}')
echo "$dns_only" | tail -1 | grep -q '^200$' || fail "DNS-only host expected 200"
dns_id=$(echo "$dns_only" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/dhcp/hosts/$dns_id"

echo "dhcp hosts CRUD ok"
