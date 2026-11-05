#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }
body() { printf '%s\n' "$1" | sed '$d'; }

echo "--- dhcp/leases?family=v6: GET returns 200 with a JSON array; /dhcp/leases6 is gone (v4, #320) ---"
leases6=$(call "$URL/dhcp/leases?family=v6")
echo "$leases6" | tail -1 | grep -q '^200$' || fail "leases?family=v6 GET expected 200"
body=$(echo "$leases6" | head -1)
case "$body" in
	'['*) ;;
	*) fail "leases?family=v6 body must be a JSON array, got: $body" ;;
esac
old=$(call "$URL/dhcp/leases6")
echo "$old" | tail -1 | grep -q '^404$' || fail "leases6 endpoint expected 404 on v4: $old"

# odhcpd writes each lease as a line that starts with `#`, which the reader skipped, so the list was
# always empty. A client on one end of a veth pair takes a lease from odhcpd on the other end. Its
# pidfile keeps the kill off the odhcp6c of wan6.
echo "--- dhcp/leases?family=v6 and dhcp/servers report a lease that odhcpd gave ---"
cleanup() {
	$SSH '[ -f /tmp/uapi27.pid ] && kill -9 "$(cat /tmp/uapi27.pid)"; rm -f /tmp/uapi27.pid
		uci -q delete dhcp.uapi27; uci commit dhcp; uci -q delete network.uapi27; uci -q delete network.uapi27dev
		uci commit network; ubus call network reload; /etc/init.d/odhcpd reload' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
$SSH 'apk info -e kmod-veth >/dev/null 2>&1 || apk add kmod-veth 2>&1 | tail -2'
$SSH 'uci set network.uapi27dev=device; uci set network.uapi27dev.type=veth; uci set network.uapi27dev.name=uapi27a
	uci set network.uapi27dev.peer_name=uapi27b; uci set network.uapi27=interface; uci set network.uapi27.device=uapi27a
	uci set network.uapi27.proto=static; uci set network.uapi27.ip6addr=fd27:6::1/64; uci commit network
	uci set dhcp.uapi27=dhcp; uci set dhcp.uapi27.interface=uapi27; uci set dhcp.uapi27.dhcpv6=server
	uci set dhcp.uapi27.ra=server; uci commit dhcp; ubus call network reload; sleep 2; ifup uapi27'
sleep 4
$SSH 'ip link set uapi27b up; /etc/init.d/odhcpd reload; sleep 2; odhcp6c -d -p /tmp/uapi27.pid -s /bin/true -N force uapi27b'
own_lease() { body "$(call "$URL/dhcp/leases?family=v6")" | jq -c '[.[] | select(.interface == "uapi27a")]'; }
n=0
until [ "$(own_lease | jq length)" = 1 ]; do
	n=$((n + 1)); [ $n -lt 20 ] || fail "no lease on uapi27a in dhcp/leases?family=v6: $(body "$(call "$URL/dhcp/leases?family=v6")")"
	sleep 1
done
lease=$(own_lease | jq -c '.[0]')
printf '%s' "$lease" | jq -e '.ia_type == "IA_NA" and .prefix_length == null and (.ip | startswith("fd27:6::")) and .expires_at > now' >/dev/null \
	|| fail "the lease on uapi27a read wrong: $lease"
r=$(call "$URL/dhcp/leases/$(printf '%s' "$lease" | jq -r .ip)?family=v6")
[ "$(echo "$r" | tail -1)" = 200 ] || fail "GET of the lease by its ip: $r"
srv=$(body "$(call "$URL/dhcp/servers/uapi27")")
printf '%s' "$srv" | jq -e '.runtime.active_leases_v6_iface == 1' >/dev/null || fail "dhcp/servers/uapi27 counts the lease wrong: $srv"
cleanup
trap - EXIT INT TERM

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

echo "runtime blocks + dhcp/leases?family=v6 ok."
