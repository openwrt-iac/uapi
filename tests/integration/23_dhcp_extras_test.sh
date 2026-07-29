#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- dhcp/servers: POST against an interface that exists ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/servers" -d '{
	"interface": "lan", "start": 100, "limit": 150, "leasetime": "12h"
}')
echo "$created"
status=$(echo "$created" | tail -1)
[ "$status" = "200" ] || fail "servers POST expected 200, got $status"
sid=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')

echo "--- dhcp/servers: PATCH leasetime, and dnsmasq recompiles the range ---"
call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/servers/$sid" -d '{"leasetime":"24h"}' | tail -1 | grep -q '^200$' \
	|| fail "PATCH servers expected 200"
assert_dnsmasq_emits ",24h"
assert_dnsmasq_loads

echo "--- dhcp/servers: DELETE ---"
call -X DELETE "$URL/dhcp/servers/$sid" | tail -1 | grep -q '^204$' || fail "DELETE servers expected 204"
assert_dnsmasq_loads

echo "--- dhcp/dnsmasq singleton: GET returns the existing config ---"
got=$(call "$URL/dhcp/dnsmasq")
echo "$got" | tail -1 | grep -q '^200$' || fail "dnsmasq GET expected 200"
echo "$got" | grep -q '"managed": true' || fail "dnsmasq singleton missing managed"

echo "--- dhcp/dnsmasq: PATCH adds a forwarder ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/dnsmasq" -d '{
	"noresolv": true, "server": ["127.0.0.1#5353"]
}')
echo "$patched"
echo "$patched" | tail -1 | grep -q '^200$' || fail "dnsmasq PATCH expected 200"
echo "$patched" | grep -q '"noresolv": true' || fail "PATCH did not update noresolv"

echo "--- dhcp/dnsmasq: PATCH reset (restore) ---"
call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/dnsmasq" -d '{
	"noresolv": false, "server": []
}' | tail -1 | grep -q '^200$' || fail "dnsmasq reset PATCH expected 200"

echo "--- dhcp/odhcpd singleton: GET returns the existing config ---"
got=$(call "$URL/dhcp/odhcpd")
echo "$got" | tail -1 | grep -q '^200$' || fail "odhcpd GET expected 200"

echo "dhcp/servers + dnsmasq + odhcpd ok."
