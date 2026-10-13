#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
BRIDGE=br-uapi54
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }
body() { printf '%s\n' "$1" | sed '$d'; }
status() { printf '%s\n' "$1" | tail -1; }
uci_get() { $SSH "uci -q get network.$1" || true; }
routes4254() { $SSH 'ip -4 route show table all' | grep 'table 4254' || true; }
wait_for() {
	local what="$1" check="$2"
	for _ in $(seq 20); do
		eval "$check" && return 0
		sleep 1
	done
	fail "$what"
}

ensure_wireguard || fail "no usable wireguard support, so the mtu check cannot run"

# Interfaces first and the bridge afterwards, each with its own reload: removing both in one
# reload once left netifd hung until procd respawned it.
cleanup() {
	$SSH "uci -q delete network.uapi54; uci -q delete network.uapi54w; uci commit network;
		/etc/init.d/network reload; sleep 2; uci -q delete network.uapi54_dev; uci commit network;
		/etc/init.d/network reload" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Written through uci, as a hand edit leaves them: uapi itself writes decimals and lists. The
# routes go into table 4254, so the box's own routes never move.
$SSH "uci set network.uapi54_dev=device; uci set network.uapi54_dev.name=$BRIDGE;
	uci set network.uapi54_dev.type=bridge; uci set network.uapi54_dev.bridge_empty=1;
	uci set network.uapi54=interface; uci set network.uapi54.proto=static; uci set network.uapi54.device=$BRIDGE;
	uci set network.uapi54.ipaddr='10.253.4.1/24 10.253.4.2/24'; uci set network.uapi54.metric=0x10;
	uci set network.uapi54.ip4table=4254; uci set network.uapi54.ip6weight=010;
	uci set network.uapi54.dns='192.0.2.1 192.0.2.2';
	uci set network.uapi54w=interface; uci set network.uapi54w.proto=wireguard;
	uci set network.uapi54w.private_key=yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=;
	uci set network.uapi54w.addresses=10.253.5.1/24; uci set network.uapi54w.ip4table=4254;
	uci set network.uapi54w.mtu=0x578;
	uci commit network; /etc/init.d/network reload"

echo "--- hex and octal integers read as the values netifd uses ---"
wait_for "no route with metric 16 in table 4254" \
	'routes4254 | grep -q "^10.253.4.0/24 dev $BRIDGE table 4254 .*metric 16"'
wait_for "wireguard did not set mtu 1400 from 0x578" '$SSH "ip link show uapi54w" | grep -q " mtu 1400 "'
r=$(body "$(call "$URL/network/interfaces/uapi54")")
printf '%s' "$r" | jq -e '.metric == 16 and .ip6weight == 8' >/dev/null || fail "metric 0x10 or ip6weight 010 read wrong: $r"
r=$(body "$(call "$URL/network/interfaces/uapi54w")")
printf '%s' "$r" | jq -e '.mtu == 1400' >/dev/null || fail "mtu 0x578 read wrong: $r"

echo "--- a scalar list reads as the words netifd uses ---"
$SSH "ip -4 addr show dev $BRIDGE" | grep -q "inet 10.253.4.2/24" || fail "netifd did not add the second address"
[ "$($SSH "ubus call network.interface.uapi54 status" | jq -c '.["dns-server"]')" = '["192.0.2.1","192.0.2.2"]' ] \
	|| fail "netifd did not split dns into two servers"
read_back=$(body "$(call "$URL/network/interfaces/uapi54")")
printf '%s' "$read_back" | jq -e '.ipaddrs == ["10.253.4.1/24","10.253.4.2/24"] and .ipaddr == "10.253.4.1/24"
	and .dns == ["192.0.2.1","192.0.2.2"]' >/dev/null || fail "the scalar lists read wrong: $read_back"

echo "--- a PUT of the read writes the same values in the form uapi writes ---"
r=$(call -X PUT -H 'Content-Type: application/json' "$URL/network/interfaces/uapi54" -d "$read_back")
[ "$(status "$r")" = 200 ] || fail "PUT of the read expected 200: $r"
[ "$(uci_get uapi54.metric)" = 16 ] && [ "$(uci_get uapi54.ip6weight)" = 8 ] || fail "PUT did not write the decimals"
# uci get prints a list and a scalar alike, so the form comes from uci show.
[ "$($SSH 'uci -q show network.uapi54.ipaddr')" = "network.uapi54.ipaddr='10.253.4.1/24' '10.253.4.2/24'" ] \
	&& [ "$($SSH 'uci -q show network.uapi54.dns')" = "network.uapi54.dns='192.0.2.1' '192.0.2.2'" ] \
	|| fail "PUT did not write the addresses and dns as lists: $($SSH 'uci -q show network.uapi54')"
wait_for "the route lost metric 16 after the PUT" \
	'routes4254 | grep -q "^10.253.4.0/24 dev $BRIDGE table 4254 .*metric 16"'

echo "--- an integer that netifd drops reads null ---"
$SSH "uci set network.uapi54.metric='16 '; uci commit network; /etc/init.d/network reload"
# Matched loosely: on the CI image, the route did not match an exact `scope link$` line.
for _ in $(seq 20); do
	route=$(routes4254 | grep "^10.253.4.0/24 dev $BRIDGE " || true)
	[ -n "$route" ] && ! printf '%s' "$route" | grep -q metric && break
	sleep 1
done
[ -n "$route" ] && ! printf '%s' "$route" | grep -q metric \
	|| fail "netifd kept a metric for '16 ', or the route is gone: '$route'"
r=$(body "$(call "$URL/network/interfaces/uapi54")")
printf '%s' "$r" | jq -e '.metric == null' >/dev/null || fail "metric '16 ' read as a number: $r"

echo "--- ip6prefix reads as the list netifd uses, and one prefix is written as a scalar ---"
# uci show prints a one-entry list like a scalar, so the stored form comes from uci export.
stored() { $SSH "uci export network" | sed -n "/^config interface '$1'\$/,/^\$/p" | grep ip6prefix || true; }
prefixes() { $SSH "ubus call network.interface.uapi54 status" | jq -c '[.["ipv6-prefix"][]? | "\(.address)/\(.mask)"] | sort'; }
$SSH "uci add_list network.uapi54.ip6prefix=fd54:1::/48; uci add_list network.uapi54.ip6prefix=fd54:2::/48;
	uci add_list network.uapi54w.ip6prefix=fd54:3::/48; uci commit network; /etc/init.d/network reload"
wait_for "netifd did not take both routed prefixes" '[ "$(prefixes)" = "[\"fd54:1::/48\",\"fd54:2::/48\"]" ]'
read_back=$(body "$(call "$URL/network/interfaces/uapi54")")
printf '%s' "$read_back" | jq -e '.ip6prefix == ["fd54:1::/48","fd54:2::/48"]' >/dev/null || fail "two prefixes read wrong: $read_back"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/interfaces/uapi54" -d '{"ip6weight":9}')
[ "$(status "$r")" = 200 ] || fail "a PATCH next to a list ip6prefix expected 200: $r"
r=$(call -X PUT -H 'Content-Type: application/json' "$URL/network/interfaces/uapi54" \
	-d "$(body "$(call "$URL/network/interfaces/uapi54")" | jq -c 'del(.runtime)')")
[ "$(status "$r")" = 200 ] && [ "$(stored uapi54 | grep -c "list ip6prefix")" = 2 ] \
	|| fail "a PUT of the read did not keep two listed prefixes: $r $(stored uapi54)"
wait_for "netifd lost a routed prefix after the PUT" '[ "$(prefixes)" = "[\"fd54:1::/48\",\"fd54:2::/48\"]" ]'
[ "$(stored uapi54w)" = "	list ip6prefix 'fd54:3::/48'" ] || fail "the LuCI-style one-entry list is not in place: $(stored uapi54w)"
r=$(body "$(call "$URL/network/interfaces/uapi54w")" | jq -c 'del(.runtime)')
printf '%s' "$r" | jq -e '.ip6prefix == ["fd54:3::/48"]' >/dev/null || fail "a one-entry list read wrong: $r"
r=$(call -X PUT -H 'Content-Type: application/json' "$URL/network/interfaces/uapi54w" -d "$r")
[ "$(status "$r")" = 200 ] && [ "$(stored uapi54w)" = "	option ip6prefix 'fd54:3::/48'" ] \
	|| fail "a PUT of the read did not write one prefix as a scalar: $r $(stored uapi54w)"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/interfaces/uapi54w" \
	-d '{"ip6prefix":"fd54:3::/48 fd54:4::/48"}')
[ "$(status "$r")" = 200 ] && [ "$(stored uapi54w | grep -c "list ip6prefix")" = 2 ] \
	|| fail "a string of two prefixes was not stored as a list: $r $(stored uapi54w)"
sweep=$(body "$(call "$URL/diagnostics?validate=1")")
printf '%s' "$sweep" | jq -e '.invalid_sections | tostring | contains("uapi54") | not' >/dev/null \
	|| fail "the sweep flagged a section with a list ip6prefix: $sweep"

echo "--- an mtu below 68 is refused on write, and a stored one reads as it is and is swept ---"
mtu_before=$(uci_get uapi54w.mtu)
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/interfaces/uapi54w" -d '{"mtu":60}')
[ "$(status "$r")" = 422 ] || fail "an mtu of 60 expected 422: $r"
[ "$(uci_get uapi54w.mtu)" = "$mtu_before" ] || fail "a refused mtu changed uci: $(uci_get uapi54w.mtu)"
$SSH "uci set network.uapi54w.mtu=60; uci commit network"
r=$(body "$(call "$URL/network/interfaces/uapi54w")")
printf '%s' "$r" | jq -e '.mtu == 60' >/dev/null || fail "a stored mtu of 60 did not read as 60: $r"
sweep=$(body "$(call "$URL/diagnostics?validate=1")")
printf '%s' "$sweep" | jq -e '.invalid_sections | tostring | contains("uapi54w")' >/dev/null \
	|| fail "the sweep did not list a stored mtu below 68: $sweep"

echo "network/interfaces reads ok"
