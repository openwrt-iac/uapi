#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"

fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- seed /tmp/dhcp.leases ---"
$SSH 'cat > /tmp/dhcp.leases' <<'EOF'
1735689600 aa:bb:cc:dd:ee:01 192.168.1.50 printer 01:aa:bb:cc:dd:ee:01
1735689700 aa:bb:cc:dd:ee:02 192.168.1.51 * *
EOF

echo "--- GET /dhcp/leases returns the parsed list ---"
got=$(call "$URL/dhcp/leases")
echo "$got"
echo "$got" | tail -1 | grep -q '^200$' || fail "GET expected 200"
echo "$got" | grep -q '"mac": "aa:bb:cc:dd:ee:01"' || fail "missing first lease"
echo "$got" | grep -q '"hostname": "printer"' || fail "missing hostname"
echo "$got" | grep -q '"hostname": null' || fail "expected null hostname for *"

echo "--- GET /dhcp/leases/<mac> returns the single lease ---"
single=$(call "$URL/dhcp/leases/aa:bb:cc:dd:ee:02")
echo "$single" | tail -1 | grep -q '^200$' || fail "GET single expected 200"
echo "$single" | grep -q '"ip": "192.168.1.51"' || fail "wrong ip"

echo "--- GET /dhcp/leases/<unknown> returns 404 ---"
missing=$(call "$URL/dhcp/leases/zz:zz:zz:zz:zz:zz")
echo "$missing" | tail -1 | grep -q '^404$' || fail "unknown mac expected 404"

echo "--- POST /dhcp/leases returns 405 ---"
post=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/leases" -d '{}')
echo "$post" | tail -1 | grep -q '^405$' || fail "POST expected 405"

echo "--- DELETE /dhcp/leases/<mac> returns 405 ---"
del=$(call -X DELETE "$URL/dhcp/leases/aa:bb:cc:dd:ee:01")
echo "$del" | tail -1 | grep -q '^405$' || fail "DELETE expected 405"

echo "dhcp leases ok"
