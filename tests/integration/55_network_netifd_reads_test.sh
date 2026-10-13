#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
BRIDGE=br-uapi55
PEER=TrMvSoP4jYQlY6RIzBgbssQqY3vxI2Pi+y71lOWWXX0=
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }
body() { printf '%s\n' "$1" | sed '$d'; }
status() { printf '%s\n' "$1" | tail -1; }
send() { call -X "$1" -H 'Content-Type: application/json' "$URL/$2" -d "$3"; }
read_back() { body "$(call "$URL/$1")" | jq -c 'del(.runtime)'; }
uci_show() { $SSH "uci -q show network.$1" || true; }
routes() { $SSH 'ip -4 route show table all' || true; }
members() { $SSH "ubus call network.device status '{\"name\":\"br-uapi55p\"}'" | jq -c '.["bridge-members"]'; }
wait_for() {
	local what="$1" check="$2"
	for _ in $(seq 20); do
		eval "$check" && return 0
		sleep 1
	done
	fail "$what"
}

ensure_wireguard || fail "no usable wireguard support, so the peer checks cannot run"

# Interfaces and their routes first, devices afterwards, each with its own reload: removing
# both in one reload once left netifd hung until procd respawned it.
cleanup() {
	$SSH "for s in uapi55r uapi55z uapi55n uapi55peer uapi55 uapi55w; do uci -q delete network.\$s; done;
		uci commit network; /etc/init.d/network reload; sleep 2;
		uci -q delete network.uapi55_dev; uci -q delete network.uapi55p; uci commit network;
		/etc/init.d/network reload; sed -i '/^205 uapi55\$/d' /etc/iproute2/rt_tables" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# busybox ip refuses an id above 255 in rt_tables, which would hide the routes from the checks.
$SSH "grep -q '^205[[:space:]]' /etc/iproute2/rt_tables && exit 1; echo '205 uapi55' >> /etc/iproute2/rt_tables" \
	|| fail "table 205 already has a name on this box"

# Written through uci, as LuCI and hand edits leave them: uapi itself writes ids, decimals and lists.
$SSH "uci set network.uapi55_dev=device; uci set network.uapi55_dev.name=$BRIDGE;
	uci set network.uapi55_dev.type=bridge; uci set network.uapi55_dev.bridge_empty=1;
	uci set network.uapi55=interface; uci set network.uapi55.proto=static; uci set network.uapi55.device=$BRIDGE;
	uci set network.uapi55.ipaddr=10.253.6.1/24;
	uci set network.uapi55r=route; uci set network.uapi55r.interface=uapi55; uci set network.uapi55r.target=10.253.60.0/24;
	uci set network.uapi55r.gateway=10.253.6.254; uci set network.uapi55r.table=uapi55; uci set network.uapi55r.metric=0x10;
	uci set network.uapi55z=route; uci set network.uapi55z.interface=uapi55; uci set network.uapi55z.target=10.253.61.0/24;
	uci set network.uapi55z.gateway=10.253.6.254; uci set network.uapi55z.table=0;
	uci set network.uapi55n=rule; uci set network.uapi55n.src=10.253.6.0/24; uci set network.uapi55n.lookup=uapi55;
	uci set network.uapi55n.priority=0x7531;
	uci set network.uapi55p=device; uci set network.uapi55p.name=br-uapi55p; uci set network.uapi55p.type=bridge;
	uci set network.uapi55p.bridge_empty=1; uci set network.uapi55p.ports='uapi55a uapi55b';
	uci set network.uapi55w=interface; uci set network.uapi55w.proto=wireguard;
	uci set network.uapi55w.private_key=yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=;
	uci set network.uapi55w.addresses=10.253.9.1/24;
	uci set network.uapi55peer=wireguard_uapi55w; uci set network.uapi55peer.public_key=$PEER;
	uci set network.uapi55peer.allowed_ips='10.253.62.0/24 10.253.63.0/24'; uci set network.uapi55peer.route_allowed_ips=1;
	uci commit network; /etc/init.d/network reload"

echo "--- a route table name reads as its id, and a hex metric as the number netifd uses ---"
wait_for "no route in table uapi55 with metric 16" \
	'routes | grep -q "^10.253.60.0/24 via 10.253.6.254 dev $BRIDGE table uapi55 .*metric 16"'
r=$(read_back network/routes/uapi55r)
printf '%s' "$r" | jq -e '.table == 205 and .metric == 16' >/dev/null || fail "the route read wrong: $r"
r=$(send PATCH network/routes/uapi55r '{"metric":17}')
[ "$(status "$r")" = 200 ] || fail "PATCH metric expected 200: $r"
[ "$(uci_show uapi55r.table)" = "network.uapi55r.table='uapi55'" ] || fail "PATCH rewrote the table name: $(uci_show uapi55r.table)"
wait_for "the route did not move to metric 17" \
	'routes | grep -q "^10.253.60.0/24 via 10.253.6.254 dev $BRIDGE table uapi55 .*metric 17"'
r=$(send PUT network/routes/uapi55r "$(read_back network/routes/uapi55r)")
[ "$(status "$r")" = 200 ] && [ "$(uci_show uapi55r.table)" = "network.uapi55r.table='205'" ] \
	|| fail "PUT of the read did not write the table id: $r $(uci_show uapi55r.table)"
wait_for "the route left table uapi55 after the PUT" \
	'routes | grep -q "^10.253.60.0/24 via 10.253.6.254 dev $BRIDGE table uapi55 .*metric 17"'

echo "--- a table netifd cannot resolve reads 0, and a PUT of the read answers 422 ---"
routes | grep -q "^10.253.61.0/24" && fail "netifd installed a route with table 0"
r=$(read_back network/routes/uapi55z)
printf '%s' "$r" | jq -e '.table == 0' >/dev/null || fail "table 0 did not read 0: $r"
r=$(send PUT network/routes/uapi55z "$(read_back network/routes/uapi55z)")
[ "$(status "$r")" = 422 ] && [ "$(body "$r" | jq -r '[.errors[] | select(.field == "table") | .code] | unique | join(",")')" = out_of_range ] \
	|| fail "PUT of a table-0 read expected 422 out_of_range on table: $r"
[ "$(uci_show uapi55z.table)" = "network.uapi55z.table='0'" ] || fail "the refused PUT changed the table"

echo "--- a rule lookup name reads as its id, and a hex priority as the number netifd uses ---"
wait_for "no rule 30001 looking up uapi55" '$SSH "ip rule" | grep -q "^30001:.*from 10.253.6.0/24 lookup uapi55"'
r=$(read_back network/rules/uapi55n)
printf '%s' "$r" | jq -e '.lookup == 205 and .priority == 30001' >/dev/null || fail "the rule read wrong: $r"
r=$(send PATCH network/rules/uapi55n '{"priority":30002}')
[ "$(status "$r")" = 200 ] || fail "PATCH of a rule with a named lookup expected 200: $r"
wait_for "the rule did not move to 30002" '$SSH "ip rule" | grep -q "^30002:.*from 10.253.6.0/24 lookup uapi55"'

echo "--- a scalar ports option reads as the members netifd makes of it ---"
[ "$(members)" = '["uapi55a","uapi55b"]' ] || fail "netifd did not split the scalar ports: $(members)"
r=$(read_back network/devices/uapi55p)
printf '%s' "$r" | jq -e '.ports == ["uapi55a","uapi55b"]' >/dev/null || fail "the ports read wrong: $r"
r=$(send PUT network/devices/uapi55p "$r")
[ "$(status "$r")" = 200 ] && [ "$(uci_show uapi55p.ports)" = "network.uapi55p.ports='uapi55a' 'uapi55b'" ] \
	|| fail "PUT of the read did not write two ports: $r $(uci_show uapi55p.ports)"
wait_for "the bridge lost a member after the PUT" '[ "$(members)" = "[\"uapi55a\",\"uapi55b\"]" ]'

echo "--- a scalar allowed_ips reads as the prefixes wireguard.sh makes of it ---"
wait_for "wg did not get both prefixes" \
	'$SSH "wg show uapi55w allowed-ips" | grep -q "10.253.62.0/24 10.253.63.0/24"'
wait_for "wireguard.sh did not route both prefixes" \
	'[ "$(routes | grep -c "^10.253.6[23].0/24 dev uapi55w")" = 2 ]'
r=$(read_back network/wireguard_peers/uapi55peer)
printf '%s' "$r" | jq -e '.allowed_ips == ["10.253.62.0/24","10.253.63.0/24"]' >/dev/null || fail "allowed_ips read wrong: $r"
r=$(send PATCH network/wireguard_peers/uapi55peer '{"persistent_keepalive":25}')
[ "$(status "$r")" = 200 ] || fail "PATCH of a peer with a scalar allowed_ips expected 200: $r"
r=$(call -X DELETE "$URL/network/wireguard_peers/uapi55peer")
[ "$(status "$r")" = 200 ] || [ "$(status "$r")" = 204 ] || fail "DELETE of the peer failed: $r"
wait_for "a DELETE left a route of the peer" '! routes | grep -q "^10.253.6[23].0/24 dev uapi55w"'

echo "network routes, rules, devices and peers read ok"
