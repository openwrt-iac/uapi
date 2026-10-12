#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
IFACE=uapi52
V6IFACE=uapi52v6
BRIDGE=br-uapi52
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }
body() { printf '%s\n' "$1" | sed '$d'; }
status() { printf '%s\n' "$1" | tail -1; }
send() { call -X "$1" -H 'Content-Type: application/json' "$URL/network/interfaces$2" -d "$3"; }
uci_get() { $SSH "uci -q get network.$1" || true; }

# netifd assigns from the ULA prefix that stock OpenWrt generates at first boot, which makes the
# effect of the ip6assign group visible without an upstream prefix.
ULA=$($SSH 'uci -q get network.globals.ula_prefix' || true)
case "$ULA" in
	*::/48) ;;
	*) fail "the test box needs a /48 network.globals.ula_prefix, got '$ULA'" ;;
esac
ULA48=${ULA%::/48}

# Interfaces first and the bridge afterwards, each with its own reload: removing both in one
# reload once left netifd hung until procd respawned it.
cleanup() {
	$SSH "uci -q delete network.$IFACE; uci -q delete network.$V6IFACE; uci commit network;
		/etc/init.d/network reload; sleep 2; uci -q delete network.${IFACE}_dev; uci commit network;
		/etc/init.d/network reload" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# An empty bridge comes up without ports, so the test interface gets a prefix without touching
# any real link.
$SSH "uci set network.${IFACE}_dev=device; uci set network.${IFACE}_dev.name=$BRIDGE;
	uci set network.${IFACE}_dev.type=bridge; uci set network.${IFACE}_dev.bridge_empty=1;
	uci commit network; /etc/init.d/network reload"

# Waits until netifd reports the expected assignment, or none at all for the empty pattern.
wait_assignment() {
	local want="$1" got=""
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		got=$($SSH "ubus call network.interface.$IFACE status" 2>/dev/null \
			| jq -r '[."ipv6-prefix-assignment"[]? | "\(.address)/\(.mask) \(."local-address".address // "-")"] | join(",")')
		[ "$got" = "$want" ] && return 0
		sleep 1
	done
	fail "netifd assignment for $IFACE: expected '$want', got '$got'"
}

echo "--- the group is stored on a static interface, and a hint change moves its subnet ---"
r=$(send POST "" "{\"id\":\"$IFACE\",\"proto\":\"static\",\"device\":\"$BRIDGE\",\"ipaddrs\":[\"10.252.0.1/24\"],
	\"ip6assign\":64,\"ip6hint\":\"5a5\",\"ip6ifaceid\":\"::5\",\"ip6weight\":10}")
[ "$(status "$r")" = 200 ] || fail "create expected 200: $r"
[ "$(uci_get $IFACE.ip6hint)" = 5a5 ] || fail "ip6hint was not stored on a static interface"
[ "$(uci_get $IFACE.ip6ifaceid)" = ::5 ] || fail "ip6ifaceid was not stored on a static interface"
[ "$(uci_get $IFACE.ip6weight)" = 10 ] || fail "ip6weight was not stored"
# netifd 25.12.5 gives an interface created after the prefix exists no assignment at all, with or
# without a hint, until one of its assignment options changes. So the effect is checked on a change.
r=$(send PATCH "/$IFACE" '{"ip6hint":"5a6"}')
[ "$(status "$r")" = 200 ] || fail "PATCH ip6hint expected 200: $r"
wait_assignment "$ULA48:5a6::/64 $ULA48:5a6::5"
r=$(send PATCH "/$IFACE" '{"ip6hint":"5a5"}')
[ "$(status "$r")" = 200 ] || fail "PATCH ip6hint expected 200: $r"
wait_assignment "$ULA48:5a5::/64 $ULA48:5a5::5"

echo "--- ip6class: a class no prefix carries removes the subnet, and local brings it back ---"
r=$(send PATCH "/$IFACE" '{"ip6class":["nosuchclass"]}')
[ "$(status "$r")" = 200 ] || fail "PATCH ip6class expected 200: $r"
wait_assignment ""
r=$(send PATCH "/$IFACE" '{"ip6class":["local"]}')
[ "$(status "$r")" = 200 ] || fail "PATCH ip6class expected 200: $r"
$SSH "uci export network" | grep -qF "list ip6class 'local'" || fail "ip6class was not stored as a uci list"
wait_assignment "$ULA48:5a5::/64 $ULA48:5a5::5"
r=$(send PATCH "/$IFACE" '{"ip6class":null}')
[ "$(status "$r")" = 200 ] || fail "PATCH ip6class null expected 200: $r"
[ -z "$(uci_get $IFACE.ip6class)" ] || fail "PATCH ip6class null left the option in uci"

echo "--- a PUT of the read keeps the whole group ---"
read_back=$(body "$(call "$URL/network/interfaces/$IFACE")")
printf '%s' "$read_back" | jq -e '.ip6hint == "5a5" and .ip6ifaceid == "::5" and .ip6weight == 10' >/dev/null \
	|| fail "the read did not carry the group: $read_back"
r=$(send PUT "/$IFACE" "$read_back")
[ "$(status "$r")" = 200 ] || fail "PUT of the read expected 200: $r"
[ "$(uci_get $IFACE.ip6hint)" = 5a5 ] || fail "a PUT of the read erased ip6hint"
[ "$(uci_get $IFACE.ip6ifaceid)" = ::5 ] || fail "a PUT of the read erased ip6ifaceid"

echo "--- values netifd cannot use are refused, and the forms LuCI accepts are not ---"
for bad in '{"ip6hint":"2001:db8::/56"}' '{"ip6hint":"ffffffff"}' '{"ip6ifaceid":"2001:db8::1"}' '{"ip6class":["bad class"]}'; do
	r=$(send PATCH "/$IFACE" "$bad")
	[ "$(status "$r")" = 422 ] || fail "expected 422 for $bad: $r"
done
[ "$(uci_get $IFACE.ip6hint)" = 5a5 ] || fail "a refused write changed ip6hint"
r=$(send PATCH "/$IFACE" '{"ip6ifaceid":"eui64"}')
[ "$(status "$r")" = 200 ] || fail "ip6ifaceid eui64 expected 200: $r"
[ "$(uci_get $IFACE.ip6ifaceid)" = eui64 ] || fail "ip6ifaceid eui64 was not stored"

echo "--- a prefix-form ip6hint, which uapi 3.1.0 required, blocks every write until it is cleared ---"
$SSH "uci set network.$IFACE.ip6hint=2001:db8::/56; uci commit network"
r=$(send PATCH "/$IFACE" '{"mtu":1500}')
[ "$(status "$r")" = 422 ] || fail "a write to an interface with a prefix-form ip6hint expected 422: $r"
body "$r" | jq -e '[.errors[].field] | index("ip6hint")' >/dev/null || fail "the 422 did not name ip6hint: $r"
r=$(send PATCH "/$IFACE" '{"ip6hint":""}')
[ "$(status "$r")" = 200 ] || fail "clearing ip6hint with an empty string expected 200: $r"
[ -z "$(uci_get $IFACE.ip6hint)" ] || fail "an empty ip6hint did not clear the option"

echo "--- sourcefilter is stored on dhcpv6, and a switch to static removes it ---"
r=$(send POST "" "{\"id\":\"$V6IFACE\",\"proto\":\"dhcpv6\",\"device\":\"$BRIDGE\",\"auto\":false,\"sourcefilter\":false}")
[ "$(status "$r")" = 200 ] || fail "create dhcpv6 expected 200: $r"
[ "$(uci_get $V6IFACE.sourcefilter)" = 0 ] || fail "sourcefilter false was not stored as '0'"
body "$r" | jq -e '.sourcefilter == false' >/dev/null || fail "sourcefilter did not read back as false: $r"
r=$(send PATCH "/$V6IFACE" '{"proto":"static","ipaddrs":["10.252.1.1/24"]}')
[ "$(status "$r")" = 200 ] || fail "switch to static expected 200: $r"
[ -z "$(uci_get $V6IFACE.sourcefilter)" ] || fail "sourcefilter stayed after the switch to static"

echo "network/interfaces ip6assign group and sourcefilter ok"
