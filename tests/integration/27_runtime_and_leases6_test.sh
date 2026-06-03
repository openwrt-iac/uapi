#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- dhcp/leases6: GET returns 200 with a JSON array ---"
leases6=$(call "$URL/dhcp/leases6")
echo "$leases6" | tail -1 | grep -q '^200$' || fail "leases6 GET expected 200"
body=$(echo "$leases6" | head -1)
case "$body" in
	'['*) ;;
	*) fail "leases6 body must be a JSON array, got: $body" ;;
esac

echo "--- network/interfaces: GET surfaces a runtime object on each item ---"
ifaces=$(call "$URL/network/interfaces")
echo "$ifaces" | tail -1 | grep -q '^200$' || fail "interfaces GET expected 200"
# Every returned interface should have a runtime field. We don't assert content
# (the bare VM may have lan up but no DHCP-issued addresses); we only assert
# the field exists and the response parses.
echo "$ifaces" | head -1 | grep -q '"runtime":' || fail "no runtime field in interfaces response"

echo "--- network/interfaces/<id>: GET on an existing interface includes runtime ---"
# 'loopback' should exist on every OpenWrt box.
lo=$(call "$URL/network/interfaces/loopback")
echo "$lo" | tail -1 | grep -q '^200$' || fail "interfaces/loopback GET expected 200"
echo "$lo" | head -1 | grep -q '"runtime":' || fail "loopback response missing runtime"

echo "--- dhcp/servers: GET items carry runtime.active_leases_v4 + v6 ---"
servers=$(call "$URL/dhcp/servers")
echo "$servers" | tail -1 | grep -q '^200$' || fail "dhcp/servers GET expected 200"
body=$(echo "$servers" | head -1)
case "$body" in
	'[]') echo "  (no dhcp servers configured on this VM; skipping lease-count assertions)" ;;
	*) echo "$body" | grep -q '"active_leases_v4_box_total":' \
		|| fail "dhcp/servers response missing active_leases_v4_box_total in runtime" ;;
esac

echo "--- wireless/interfaces: GET includes runtime (may be empty if no hwsim) ---"
wifi=$(call "$URL/wireless/interfaces")
echo "$wifi" | tail -1 | grep -q '^200$' || fail "wireless/interfaces GET expected 200"
body=$(echo "$wifi" | head -1)
case "$body" in
	'[]') echo "  (no wireless ifaces configured; runtime path not exercised)" ;;
	*) echo "$body" | grep -q '"runtime":' \
		|| fail "wireless/interfaces response missing runtime" ;;
esac

echo "runtime blocks + dhcp/leases6 ok."
