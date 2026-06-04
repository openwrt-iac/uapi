#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"

fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- POST /firewall/zones creates a zone ---"
zone=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/zones" -d '{
	"name": "uapi_test", "input": "ACCEPT", "output_policy": "ACCEPT", "forward": "REJECT"
}')
echo "$zone" | tail -1 | grep -q '^200$' || fail "zone POST expected 200"
zid=$(echo "$zone" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$zid" ] || fail "zone POST missing id"

echo "--- POST /firewall/redirects against the new zone ---"
redirect=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/redirects" -d '{
	"target": "DNAT",
	"match": { "src_zone": "uapi_test", "src_dport": ["8443"],
	           "dest_ip": ["192.168.1.10"], "dest_port": ["443"], "proto": ["tcp"] }
}')
echo "$redirect" | tail -1 | grep -q '^200$' || fail "redirect POST expected 200"
rid=$(echo "$redirect" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')

echo "--- POST /network/interfaces with proto: none ---"
iface=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" -d '{
	"proto": "none"
}')
echo "$iface" | tail -1 | grep -q '^200$' || fail "interface POST expected 200"
iid=$(echo "$iface" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')

echo "--- POST /network/interfaces with proto: static and bad ipaddr returns 422 ---"
bad_if=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" -d '{
	"proto": "static", "ipaddr": "999.0.0.1"
}')
echo "$bad_if" | tail -1 | grep -q '^422$' || fail "bad ipaddr expected 422"

echo "--- list each resource includes the new id ---"
call "$URL/firewall/zones"     | grep -q "\"id\": \"$zid\"" || fail "zone list missing"
call "$URL/firewall/redirects" | grep -q "\"id\": \"$rid\"" || fail "redirect list missing"
call "$URL/network/interfaces" | grep -q "\"id\": \"$iid\"" || fail "interface list missing"

echo "--- DELETE each ---"
call -X DELETE "$URL/firewall/redirects/$rid" | tail -1 | grep -q '^204$' || fail "redirect DELETE failed"
call -X DELETE "$URL/firewall/zones/$zid"     | tail -1 | grep -q '^204$' || fail "zone DELETE failed"
call -X DELETE "$URL/network/interfaces/$iid" | tail -1 | grep -q '^204$' || fail "interface DELETE failed"

echo "more resources ok"
