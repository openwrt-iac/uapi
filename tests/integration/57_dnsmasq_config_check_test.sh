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
	$SSH 'rm -f /tmp/dnsmasq*.d/uapi_t57.conf /tmp/uapi_t57.fifo
	      [ "$(uci -q get system.@system[0].notes)" = uapi-t57 ] && { uci delete system.@system[0].notes; uci commit system; }
	      uci -q delete dhcp.tdhcp; uci commit dhcp
	      uci -q delete network.tdhcp; uci -q delete network.br_tdhcp; uci commit network
	      ubus call network reload; /etc/init.d/dnsmasq reload' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
cleanup

# dnsmasq.init sends SIGHUP right after procd restarts an instance, and on a slow machine the
# signal can stop the new dnsmasq until procd starts it again 5 s later.
dnsmasq_running() {
	n=0
	until $SSH "ubus call service list '{\"name\":\"dnsmasq\"}'" | grep -q '"running": true'; do
		n=$((n + 1))
		[ $n -lt 10 ] || return 1
		sleep 1
	done
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
	-d '{"id":"tdhcp","interface":"tdhcp","dhcpv4":"server","start":100,"limit":50,"leasetime":"12h"}')
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
echo "$body" | jq -e '.reload_error | startswith("dnsmasq refuses its config ") and contains("bad IP address")' >/dev/null \
	|| fail "expected the dnsmasq --test refusal in reload_error: $body"
[ "$(stored_options)" = "$TWO" ] || fail "uci did not get the old list back: $(stored_options)"
assert_dnsmasq_omits "dhcp-option=tdhcp,3,not-an-address"
dnsmasq_running || fail "dnsmasq is not running after the restore"
assert_dnsmasq_loads

echo "--- a valid option still answers 200, a text option with a space before 6, included ---"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/servers/tdhcp" \
	-d '{"dhcp_option":["3,10.99.0.1","6,10.99.0.1","15,my 6,domain"]}')
[ "$(echo "$r" | tail -1)" = "200" ] || fail "a valid option expected 200: $r"
assert_dnsmasq_emits 'dhcp-option=tdhcp,15,my 6,domain'
dnsmasq_running || fail "dnsmasq is not running after a valid option"
assert_dnsmasq_loads

# A conf-file that dnsmasq cannot open, as on a mount that hangs, held the locks until uhttpd
# killed the request at its 60 s script timeout, and the client got no answer. A FIFO without a
# writer blocks the open in the same way. A killed --test judges nothing, so the write keeps its
# commit and says that the check did not finish.
echo "--- a --test that does not finish is killed after 10 s, and the write answers unverified ---"
$SSH 'rm -f /tmp/uapi_t57.fifo; mkfifo /tmp/uapi_t57.fifo
      for d in /tmp/dnsmasq*.d; do echo conf-file=/tmp/uapi_t57.fifo > "$d/uapi_t57.conf"; done'
hdrs=$(mktemp)
start=$(date +%s)
r=$(curl -sS -m 55 -D "$hdrs" -H "$ADMIN" -w "\n%{http_code}" -X PATCH -H 'Content-Type: application/json' \
	"$URL/dhcp/servers/tdhcp" -d '{"leasetime":"6h"}' || true)
took=$(( $(date +%s) - start ))
status=$(grep -i '^X-Reload-Status:' "$hdrs" | tr -d '\r' || true)
rm -f "$hdrs"
[ "$(echo "$r" | tail -1)" = "200" ] || fail "a --test that hangs expected 200 within 55 s, after $took s: $r"
[ "$status" = "X-Reload-Status: unverified" ] || fail "expected X-Reload-Status: unverified, got: $status"
[ "$took" -ge 10 ] || fail "the write answered after $took s, before the bound, so the --test did not hang"
[ "$took" -lt 30 ] || fail "the write took $took s, so the bound did not hold"
[ "$($SSH 'uci -q get dhcp.tdhcp.leasetime')" = "6h" ] || fail "uci does not keep the leasetime that the write committed"
echo "the write answered after $took s"

# A system write reloads dnsmasq for the hostname and NTP but runs no check, so the hang does not
# delay or fail it.
echo "--- a PATCH of system with the same hang answers ok, without the check ---"
hdrs=$(mktemp)
start=$(date +%s)
r=$(curl -sS -m 55 -D "$hdrs" -H "$ADMIN" -w "\n%{http_code}" -X PATCH -H 'Content-Type: application/json' \
	"$URL/system" -d '{"notes":"uapi-t57"}' || true)
took=$(( $(date +%s) - start ))
status=$(grep -i '^X-Reload-Status:' "$hdrs" | tr -d '\r' || true)
services=$(grep -i '^X-Reload-Services:' "$hdrs" | tr -d '\r' || true)
rm -f "$hdrs"
[ "$(echo "$r" | tail -1)" = "200" ] || fail "PATCH of system expected 200: $r"
[ "$status" = "X-Reload-Status: ok" ] || fail "expected X-Reload-Status: ok on a system write, got: $status"
echo "$services" | grep -q 'dnsmasq' || fail "expected the system write to reload dnsmasq: $services"
[ "$took" -lt 8 ] || fail "the system write took $took s, so it waited for a check"
$SSH 'rm -f /tmp/dnsmasq*.d/uapi_t57.conf /tmp/uapi_t57.fifo; /etc/init.d/dnsmasq restart'
dnsmasq_running || fail "dnsmasq is not running once the FIFO is gone"

echo "dhcp_option refusal and the dnsmasq --test check ok."
