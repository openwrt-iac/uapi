#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

# The lan of the test VM is a DHCP client, and dnsmasq.init writes the options of a dhcp section
# only for a static interface, so these cases run on tdhcp, on an empty bridge of its own.
cleanup() {
	$SSH 'uci -q delete dhcp.tdhcp; uci commit dhcp
	      uci -q delete network.tdhcp; uci -q delete network.br_tdhcp; uci commit network
	      ubus call network reload; /etc/init.d/dnsmasq reload' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
cleanup

dnsmasq_running() {
	$SSH "ubus call service list '{\"name\":\"dnsmasq\"}'" | grep -q '"running": true'
}

stored_options() {
	$SSH "uci -q show dhcp.tdhcp.dhcp_option" || true
}

echo "--- a static interface tdhcp on the empty bridge br-tdhcp ---"
$SSH 'uci set network.br_tdhcp=device
      uci set network.br_tdhcp.type=bridge
      uci set network.br_tdhcp.name=br-tdhcp
      uci set network.br_tdhcp.bridge_empty=1
      uci set network.tdhcp=interface
      uci set network.tdhcp.proto=static
      uci set network.tdhcp.device=br-tdhcp
      uci set network.tdhcp.ipaddr=10.99.0.1
      uci set network.tdhcp.netmask=255.255.255.0
      uci commit network
      ubus call network reload'
n=0
until $SSH 'ubus call network.interface.tdhcp status' 2>/dev/null | grep -q '"up": true'; do
	n=$((n + 1))
	[ $n -lt 15 ] || fail "tdhcp did not come up"
	sleep 1
done

echo "--- POST /dhcp/servers on tdhcp, then two options ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/servers" \
	-d '{"id":"tdhcp","interface":"tdhcp","start":100,"limit":50,"leasetime":"12h"}')
[ "$(echo "$r" | tail -1)" = "200" ] || fail "POST expected 200: $r"
assert_dnsmasq_emits "dhcp-range=set:tdhcp,10.99.0.100,10.99.0.149,255.255.255.0,12h"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/servers/tdhcp" \
	-d '{"dhcp_option":["3,10.99.0.1","6,10.99.0.1"]}')
[ "$(echo "$r" | tail -1)" = "200" ] || fail "PATCH of two options expected 200: $r"
assert_dnsmasq_emits "dhcp-option=tdhcp,3,10.99.0.1"
assert_dnsmasq_emits "dhcp-option=tdhcp,6,10.99.0.1"
dnsmasq_running || fail "dnsmasq is not running after two valid options"
TWO="dhcp.tdhcp.dhcp_option='3,10.99.0.1' '6,10.99.0.1'"

echo "--- an entry that holds two options answers 422, and dnsmasq keeps running ---"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/servers/tdhcp" \
	-d '{"dhcp_option":["3,10.99.0.1 6,10.99.0.1"]}')
[ "$(echo "$r" | tail -1)" = "422" ] || fail "an entry of two options expected 422: $r"
echo "$r" | sed '$d' | jq -e '.errors[0].field == "dhcp_option[0]" and .errors[0].code == "invalid_format"' >/dev/null \
	|| fail "expected invalid_format on dhcp_option[0]: $r"
[ "$(stored_options)" = "$TWO" ] || fail "the refused write changed uci: $(stored_options)"
assert_dnsmasq_omits "dhcp-option=tdhcp,3,10.99.0.1 6,10.99.0.1"
dnsmasq_running || fail "dnsmasq is not running after the refused write"

echo "--- a value that the pattern takes and dnsmasq refuses answers 500 reload_failed_restored ---"
$SSH 'printf "dhcp-option=tdhcp,3,not-an-address\n" > /tmp/uapi_dhcp_option.conf
      dnsmasq --test -C /tmp/uapi_dhcp_option.conf 2>&1; rm -f /tmp/uapi_dhcp_option.conf' \
	| grep -q 'bad IP address' || fail "dnsmasq took 3,not-an-address, so the case below proves nothing"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/servers/tdhcp" \
	-d '{"dhcp_option":["3,not-an-address"]}')
body=$(echo "$r" | sed '$d')
[ "$(echo "$r" | tail -1)" = "500" ] || fail "a value that dnsmasq refuses expected 500: $r"
echo "$body" | jq -e '.code == "reload_failed_restored"' >/dev/null || fail "expected reload_failed_restored: $body"
echo "$body" | jq -e '.reload_error | startswith("dnsmasq stopped after the reload")' >/dev/null \
	|| fail "expected the stay-up error in reload_error: $body"
[ "$(stored_options)" = "$TWO" ] || fail "uci did not get the old list back: $(stored_options)"
assert_dnsmasq_omits "dhcp-option=tdhcp,3,not-an-address"
dnsmasq_running || fail "dnsmasq is not running after the restore"
assert_dnsmasq_loads

echo "--- a valid option still answers 200 ---"
t=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' -H "$ADMIN" -X PATCH -H 'Content-Type: application/json' \
	"$URL/dhcp/servers/tdhcp" -d '{"dhcp_option":["3,10.99.0.1","6,10.99.0.1","15,\"my domain\""]}')
[ "${t% *}" = "200" ] || fail "a valid option expected 200, got $t"
echo "the write took ${t#* } s with dnsmasq running"
assert_dnsmasq_emits 'dhcp-option=tdhcp,15,"my domain"'
dnsmasq_running || fail "dnsmasq is not running after a valid option"

echo "dhcp_option refusal and the dnsmasq stay-up watch ok."
