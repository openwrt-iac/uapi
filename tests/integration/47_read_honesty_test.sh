#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# The read-honesty property on a real box, covering what 44_stock_config_test.sh
# structurally cannot reach. Three differences from 44:
#
#   1. It changes one field before writing. 44 PUTs verbatim, and verbatim cannot
#      see a read whose fields are not independently writable: `ipaddr` agrees
#      with `ipaddrs[0]` until the list moves, so the 2.4.1 refusal only appears
#      once one field changes. This is also the shape of every real apply.
#   2. It covers wireguard and wireless. 44's scope is bare-image packages and it
#      excludes wireless outright, so the resources carrying masked credentials
#      are exactly the ones it never round-trips.
#   3. It reads the secret back out of uci. The view masks credentials, so a
#      write that replaced one with a different non-empty value satisfies any
#      view-level comparison. Only uci can say the stored bytes are unchanged.
#
# Both forms were validated by re-introducing the bug each claims to catch:
# neutering carry_write_only empties `preshared_key` in uci while the response
# stays 200. The modified-field form was validated the same way against 2.x, by
# neutering resolve_for_replace; 3.0.0 deleted that seam, so the check now stands
# on the class of bug rather than that one instance. The unit-level counterpart
# is tests/unit/read_honesty_test.uc.

ensure_wireguard || fail "no usable wireguard support, so the masked-credential cases cannot run"

WG_KEY='yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk='
WG_PUB='xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg='
PSK='X8fCLXStb+9BQ2c9WFN5r0Xp4y5oQ0f8Zk2mJm2A1nA='

STRIP='del(.id, .managed, .runtime)'


# Deleting the uci section does not remove the netdev, and a wireguard netdev that
# outlives its config takes only part of it back on the next ifup: a re-run saw
# the v6 addresses return without the v4 one. So the netdev goes too, or the
# kernel assertion below silently starts grading leftover state.
cleanup_probes() {
	# shellcheck disable=SC2016  # $s is the remote loop variable, not a local one
	$SSH 'for s in uapiwg uapipeer uapistat; do
	        ifdown $s 2>/dev/null
	        uci -q delete network.$s 2>/dev/null
	      done
	      uci commit network
	      ip link del uapiwg 2>/dev/null' >/dev/null 2>&1 || true
}
cleanup_probes
trap cleanup_probes EXIT

create() {
	status=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
		-o /tmp/uapi_rh_new.json -w '%{http_code}' -X POST "$URL/$1" -d "$2")
	[ "$status" = "200" ] || {
		cat /tmp/uapi_rh_new.json
		fail "POST /$1 returned $status"
	}
}

# Form one: write the body back untouched. Nothing may change or be rejected.
verbatim() {
	res=$1
	before=$(curl -sS -H "$ADMIN" "$URL/$res")
	status=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
		-o /tmp/uapi_rh_put.json -w '%{http_code}' -X PUT "$URL/$res" -d "$before")
	[ "$status" = "200" ] || {
		cat /tmp/uapi_rh_put.json
		fail "$res: PUT rejected the body it just served ($status)"
	}
	curl -sS -H "$ADMIN" "$URL/$res" | jq -S "$STRIP" > /tmp/uapi_rh_after.json
	echo "$before" | jq -S "$STRIP" > /tmp/uapi_rh_before.json
	if ! cmp -s /tmp/uapi_rh_before.json /tmp/uapi_rh_after.json; then
		diff /tmp/uapi_rh_before.json /tmp/uapi_rh_after.json || true
		fail "$res: verbatim round trip mutated the body"
	fi
	echo "  ok verbatim  $res"
}

# Form two: change exactly one field, leave every other field as read.
modified() {
	res=$1; key=$2; val=$3
	body=$(curl -sS -H "$ADMIN" "$URL/$res" | jq "del(.runtime) | .$key = $val")
	status=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
		-o /tmp/uapi_rh_put.json -w '%{http_code}' -X PUT "$URL/$res" -d "$body")
	[ "$status" = "200" ] || {
		cat /tmp/uapi_rh_put.json
		fail "$res: PUT rejected a one-field change to $key ($status)"
	}
	got=$(curl -sS -H "$ADMIN" "$URL/$res" | jq -c ".$key")
	want=$(echo "$val" | jq -c .)
	[ "$got" = "$want" ] || fail "$res: $key did not take, got $got want $want"
	echo "  ok modified  $res ($key)"
}

secret_intact() {
	got=$($SSH "uci -q get $1" 2>/dev/null || true)
	[ "$got" = "$2" ] || fail "$1 changed in uci: got '$got' want '$2'"
	echo "  ok secret    $1 unchanged in uci"
}

echo "=== wireguard interface: masked private_key, dual-stack address list ==="
create network/interfaces "{\"id\":\"uapiwg\",\"proto\":\"wireguard\",\"private_key\":\"$WG_KEY\",\"addresses\":[\"10.9.0.1/24\",\"fd00:9::1/64\"],\"listen_port\":51820}"
verbatim network/interfaces/uapiwg
secret_intact network.uapiwg.private_key "$WG_KEY"
modified network/interfaces/uapiwg addresses '["10.9.0.1/24","fd00:9::1/64","fd00:99::1/64"]'
secret_intact network.uapiwg.private_key "$WG_KEY"

echo "=== wireguard peer: masked preshared_key, merge hook ==="
create network/wireguard_peers "{\"id\":\"uapipeer\",\"interface\":\"uapiwg\",\"public_key\":\"$WG_PUB\",\"preshared_key\":\"$PSK\",\"allowed_ips\":[\"10.9.0.2/32\"],\"endpoint_host\":\"198.51.100.7\",\"endpoint_port\":51820}"
verbatim network/wireguard_peers/uapipeer
secret_intact network.uapipeer.preshared_key "$PSK"
modified network/wireguard_peers/uapipeer allowed_ips '["10.9.0.2/32","10.9.0.3/32"]'
secret_intact network.uapipeer.preshared_key "$PSK"

echo "=== static interface: ipaddr and ipaddrs name one uci option ==="
create network/interfaces '{"id":"uapistat","proto":"static","ipaddr":"192.168.77.1/24","ipaddrs":["192.168.77.1/24","10.77.0.1/24"]}'
verbatim network/interfaces/uapistat
modified network/interfaces/uapistat ipaddrs '["192.168.78.1/24"]'

echo "=== the modified address list reached the kernel, not just uci ==="
# The write path reports X-Kernel-Status, but only the netdev can confirm the v6
# addresses actually landed: this list was rejected outright before 2.5.0.
$SSH 'ifup uapiwg' >/dev/null 2>&1 || true
n=0
while [ $n -lt 10 ]; do
	v6=$($SSH 'ip -6 addr show uapiwg 2>/dev/null | grep -c "inet6 fd00:"' 2>/dev/null || echo 0)
	[ "$v6" -ge 2 ] && break
	n=$((n + 1)); sleep 1
done
[ "$v6" -ge 2 ] || {
	$SSH 'ip addr show uapiwg 2>&1' || true
	fail "expected both fd00: addresses on uapiwg, found $v6"
}
$SSH 'ip -4 addr show uapiwg | grep -q "inet 10.9.0.1/24"' \
	|| fail "the v4 address did not survive alongside the v6 ones"
echo "  ok kernel    uapiwg carries 10.9.0.1/24 and both fd00: addresses"

echo "=== wireless: masked key, excluded from the stock-config round trip ==="
ensure_wireless_radio || fail "could not bring up a simulated radio via mac80211_hwsim"
wid=$(curl -sS -H "$ADMIN" "$URL/wireless/interfaces" | jq -r '.[0].id // empty')
[ -n "$wid" ] || fail "no wifi-iface section to round-trip"
if [ "$(curl -sS -H "$ADMIN" "$URL/wireless/interfaces/$wid" | jq -r '.managed')" = "false" ]; then
	wid=$(curl -sS -H "$ADMIN" -X POST "$URL/wireless/interfaces/$wid/adopt" | jq -r '.id')
fi
$SSH "uci set wireless.$wid.encryption=psk2
      uci set wireless.$wid.key=correcthorsebatterystaple
      uci commit wireless" >/dev/null
verbatim "wireless/interfaces/$wid"
secret_intact "wireless.$wid.key" correcthorsebatterystaple
modified "wireless/interfaces/$wid" ssid '"uapi-read-honesty"'
secret_intact "wireless.$wid.key" correcthorsebatterystaple

echo "PASS 47_read_honesty_test"
