#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
BRIDGE=br-uapi53
WG_KEY=yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
IFACES="uapi53 uapi53d uapi53v6 uapi53p uapi53w uapi53x uapi53t"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }
body() { printf '%s\n' "$1" | sed '$d'; }
status() { printf '%s\n' "$1" | tail -1; }
send() { call -X "$1" -H 'Content-Type: application/json' "$URL/network/interfaces$2" -d "$3"; }
codes() { body "$1" | jq -r --arg f "$2" '[.errors[]? | select(.field == $f) | .code] | unique | join(",")'; }
uci_get() { $SSH "uci -q get network.$1" || true; }
routes4207() { $SSH 'ip -4 route show table all' | grep 'table 4207' || true; }
# ps truncates long lines, so the full command line comes from /proc.
args_of() {
	$SSH "for p in \$(pgrep -f '^$1 .*$BRIDGE'); do tr '\\0' ' ' < /proc/\$p/cmdline; echo; done" || true
}
wait_for() {
	local what="$1" check="$2"
	for _ in $(seq 20); do
		eval "$check" && return 0
		sleep 1
	done
	fail "$what"
}

# Interfaces first and the bridge afterwards, each with its own reload: removing both in one
# reload once left netifd hung until procd respawned it.
cleanup() {
	local del=""
	for i in $IFACES; do del="$del uci -q delete network.$i;"; done
	$SSH "$del uci commit network; /etc/init.d/network reload; sleep 2;
		uci -q delete network.uapi53_dev; uci commit network; /etc/init.d/network reload" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Every route the test makes goes into table 4207, so the box's own default route never moves.
MAIN_DEFAULT=$($SSH 'ip -4 route show default')
$SSH "uci set network.uapi53_dev=device; uci set network.uapi53_dev.name=$BRIDGE;
	uci set network.uapi53_dev.type=bridge; uci set network.uapi53_dev.bridge_empty=1;
	uci commit network; /etc/init.d/network reload"

echo "--- core options on static: metric, ip4table and defaultroute reach netifd's routes ---"
r=$(send POST "" "{\"id\":\"uapi53\",\"proto\":\"static\",\"device\":\"$BRIDGE\",\"ipaddrs\":[\"10.253.7.1/24\"],
	\"gateway\":\"10.253.7.254\",\"metric\":4207,\"ip4table\":\"4207\",\"delegate\":false}")
[ "$(status "$r")" = 200 ] || fail "create static with core options expected 200: $r"
[ "$(uci_get uapi53.metric)" = 4207 ] || fail "metric was not stored on a static interface"
[ "$(uci_get uapi53.ip4table)" = 4207 ] || fail "ip4table was not stored on a static interface"
[ "$(uci_get uapi53.delegate)" = 0 ] || fail "delegate was not stored on a static interface"
wait_for "no default route in table 4207 with metric 4207" \
	'routes4207 | grep -q "^default via 10.253.7.254 dev $BRIDGE table 4207 .*metric 4207"'
[ "$($SSH 'ip -4 route show default')" = "$MAIN_DEFAULT" ] || fail "the main table's default route moved"
r=$(send PATCH /uapi53 '{"defaultroute":false}')
[ "$(status "$r")" = 200 ] || fail "PATCH defaultroute expected 200: $r"
wait_for "defaultroute false left the default route in table 4207" '! routes4207 | grep -q "^default"'
routes4207 | grep -q "^10.253.7.0/24 dev $BRIDGE" || fail "the subnet route left table 4207"
read_back=$(body "$(call "$URL/network/interfaces/uapi53")")
r=$(send PUT /uapi53 "$read_back")
[ "$(status "$r")" = 200 ] || fail "PUT of the read expected 200: $r"
for o in metric=4207 ip4table=4207 defaultroute=0 delegate=0; do
	[ "$(uci_get "uapi53.${o%%=*}")" = "${o#*=}" ] || fail "a PUT of the read changed ${o%%=*}"
done

echo "--- a field the proto does not take answers 422 conflict and writes nothing ---"
r=$(send POST "" "{\"id\":\"uapi53x\",\"proto\":\"dhcp\",\"device\":\"$BRIDGE\",\"netmask\":\"255.255.255.0\"}")
[ "$(status "$r")" = 422 ] && [ "$(codes "$r" netmask)" = conflict ] || fail "netmask on dhcp expected 422 conflict: $r"
[ -z "$(uci_get uapi53x)" ] || fail "a refused create left a section"
for bad in '{"hostname":"h"}' '{"listen_port":51820}' '{"sourcefilter":false}'; do
	r=$(send PATCH /uapi53 "$bad")
	[ "$(status "$r")" = 422 ] || fail "expected 422 for $bad on static: $r"
done
[ -z "$(uci_get uapi53.hostname)" ] || fail "a refused write stored hostname"
r=$(send PATCH /uapi53 '{"hostname":null,"clientid":"","addresses":[]}')
[ "$(status "$r")" = 200 ] || fail "null or empty values for fields the proto does not take expected 200: $r"

echo "--- a proto switch drops the old proto's options and keeps the core ones ---"
r=$(send PUT /uapi53 "{\"proto\":\"dhcp\",\"device\":\"$BRIDGE\",\"ipaddrs\":[\"10.253.7.1/24\"]}")
[ "$(status "$r")" = 422 ] && [ "$(codes "$r" ipaddrs)" = conflict ] || fail "a PUT to dhcp carrying ipaddrs expected 422 conflict: $r"
r=$(call -X PATCH -H 'Content-Type: application/json-patch+json' "$URL/network/interfaces/uapi53" \
	-d '[{"op":"test","path":"/ipaddrs","value":["10.253.7.1/24"]},{"op":"replace","path":"/proto","value":"dhcp"}]')
[ "$(status "$r")" = 200 ] || fail "a JSON Patch switch to dhcp with a test op expected 200: $r"
[ -z "$(uci_get uapi53.ipaddr)" ] && [ -z "$(uci_get uapi53.gateway)" ] || fail "the switch kept static options"
[ "$(uci_get uapi53.metric)" = 4207 ] && [ "$(uci_get uapi53.ip4table)" = 4207 ] || fail "the switch dropped core options"
$SSH "uci set network.uapi53.private_key=$WG_KEY; uci commit network"
r=$(send PATCH /uapi53 '{}')
[ "$(status "$r")" = 200 ] || fail "an empty PATCH next to a leftover private_key expected 200: $r"

echo "--- broadcast_flag is uci's broadcast on dhcp, and reaches udhcpc as -B ---"
r=$(send POST "" "{\"id\":\"uapi53d\",\"proto\":\"dhcp\",\"device\":\"$BRIDGE\",\"defaultroute\":false,
	\"ip4table\":\"4207\",\"broadcast_flag\":true}")
[ "$(status "$r")" = 200 ] || fail "create dhcp with broadcast_flag expected 200: $r"
[ "$(uci_get uapi53d.broadcast)" = 1 ] || fail "broadcast_flag true was not stored as broadcast '1'"
body "$r" | jq -e '.broadcast_flag == true and (has("broadcast") | not)' >/dev/null || fail "the read did not show broadcast_flag alone: $r"
# An empty bridge has no carrier, so the DHCP client only starts with force_link, which uapi does
# not model; a PATCH keeps it, a PUT would not.
$SSH 'uci set network.uapi53d.force_link=1; uci commit network; /etc/init.d/network reload'
wait_for "udhcpc did not get -B" 'args_of udhcpc | grep -q " -B "'
r=$(send PATCH /uapi53d '{"broadcast_flag":false}')
[ "$(status "$r")" = 200 ] || fail "PATCH broadcast_flag false expected 200: $r"
wait_for "udhcpc kept -B" 'args_of udhcpc | grep -q "^udhcpc " && ! args_of udhcpc | grep -q " -B "'
r=$(send PUT /uapi53d "{\"proto\":\"dhcp\",\"device\":\"$BRIDGE\",\"broadcast\":\"1\"}")
[ "$(status "$r")" = 422 ] && [ "$(codes "$r" broadcast)" = conflict ] || fail "an address broadcast on dhcp expected 422 conflict: $r"
$SSH 'uci set network.uapi53d.broadcast=1; uci commit network'
read_back=$(body "$(call "$URL/network/interfaces/uapi53d")")
printf '%s' "$read_back" | jq -e '.broadcast_flag == true' >/dev/null || fail "LuCI's broadcast '1' did not read as broadcast_flag: $read_back"
r=$(send PUT /uapi53d "$read_back")
[ "$(status "$r")" = 200 ] && [ "$(uci_get uapi53d.broadcast)" = 1 ] || fail "a PUT of the read lost broadcast '1': $r"

echo "--- reqprefix in the prefix form and clientid reach odhcp6c ---"
r=$(send POST "" "{\"id\":\"uapi53v6\",\"proto\":\"dhcpv6\",\"device\":\"$BRIDGE\",\"defaultroute\":false,
	\"reqprefix\":\"2001:db8::/56\",\"clientid\":\"000300010a0b0c0d0e0f\"}")
[ "$(status "$r")" = 200 ] || fail "create dhcpv6 with a prefix-form reqprefix expected 200: $r"
$SSH 'uci set network.uapi53v6.force_link=1; uci commit network; /etc/init.d/network reload'
wait_for "odhcp6c did not get the prefix and the client id" \
	'args_of odhcp6c | grep -q -- "-P2001:db8::/56" && args_of odhcp6c | grep -q -- "-c000300010a0b0c0d0e0f"'
sleep 3
args_of odhcp6c | grep -q -- "-P2001:db8::/56" || fail "odhcp6c did not keep running with the prefix form"

echo "--- static options left on a dhcp section are hidden, kept by PATCH and removed by PUT ---"
$SSH 'uci set network.uapi53d.netmask=255.255.255.0; uci set network.uapi53d.ipaddr=10.253.9.1; uci commit network'
sweep=$(body "$(call "$URL/diagnostics?validate=1")")
printf '%s' "$sweep" | jq -e '.invalid_sections | tostring | contains("uapi53d") | not' >/dev/null \
	|| fail "the sweep flagged options a dhcp section keeps for another proto: $sweep"
read_back=$(body "$(call "$URL/network/interfaces/uapi53d")")
printf '%s' "$read_back" | jq -e '(has("netmask") or has("ipaddr")) | not' >/dev/null || fail "the read showed static options on dhcp: $read_back"
r=$(send PATCH /uapi53d '{"auto":false}')
[ "$(status "$r")" = 200 ] && [ "$(uci_get uapi53d.netmask)" = 255.255.255.0 ] || fail "a PATCH removed options it did not name: $r"
r=$(send PUT /uapi53d "$(body "$(call "$URL/network/interfaces/uapi53d")")")
[ "$(status "$r")" = 200 ] && [ -z "$(uci_get uapi53d.netmask)" ] && [ -z "$(uci_get uapi53d.ipaddr)" ] \
	|| fail "a PUT of the read kept static options on dhcp: $r"

echo "--- on a proto uapi does not model, a read shows what uci stores and a PATCH refuses nothing ---"
# No 6in4 handler on the box, so netifd leaves the section down whatever it holds.
$SSH "uci set network.uapi53t=interface; uci set network.uapi53t.proto=6in4; uci set network.uapi53t.auto=0;
	uci set network.uapi53t.ipaddr=192.0.2.1; uci set network.uapi53t.ip6prefix=2001:db8:53::/48; uci commit network"
read_back=$(body "$(call "$URL/network/interfaces/uapi53t")")
printf '%s' "$read_back" | jq -e '.ipaddr == "192.0.2.1" and .ip6prefix == ["2001:db8:53::/48"] and (has("hostname") | not)' \
	>/dev/null || fail "a 6in4 read did not show what uci stores: $read_back"
r=$(send PATCH /uapi53t '{"ip6prefix":"2001:db8:54::/48","nohostroute":true}')
[ "$(status "$r")" = 200 ] && [ "$(uci_get uapi53t.ip6prefix)" = 2001:db8:54::/48 ] && [ "$(uci_get uapi53t.nohostroute)" = 1 ] \
	&& [ "$(uci_get uapi53t.ipaddr)" = 192.0.2.1 ] || fail "a PATCH on a 6in4 section was refused or lost ipaddr: $r"
before=$($SSH 'uci show network.uapi53t')
r=$(send PUT /uapi53t "$(body "$(call "$URL/network/interfaces/uapi53t")" | jq -c 'del(.id, .managed, .ipaddr, .has_private_key, .runtime)')")
[ "$(status "$r")" = 422 ] && body "$r" | jq -e '.errors | length == 1 and .[0].field == "proto" and .[0].code == "not_in_enum"' >/dev/null \
	&& [ "$($SSH 'uci show network.uapi53t')" = "$before" ] || fail "a PUT of a 6in4 read was not refused on proto alone: $r"

echo "--- every read validates against the published Response schema ---"
r=$(send POST "" "{\"id\":\"uapi53p\",\"proto\":\"pppoe\",\"device\":\"$BRIDGE\",\"auto\":false,
	\"peerdns\":false,\"reqprefix\":\"56\",\"sourcefilter\":false}")
[ "$(status "$r")" = 200 ] || fail "create pppoe expected 200: $r"
r=$(send POST "" "{\"id\":\"uapi53w\",\"proto\":\"wireguard\",\"auto\":false,\"private_key\":\"$WG_KEY\",
	\"addresses\":[\"10.253.8.1/24\"],\"ip6prefix\":[\"fd00:53::/48\",\"fd00:54::/48\"]}")
[ "$(status "$r")" = 200 ] || fail "create wireguard without listen_port expected 200: $r"
for i in uapi53 uapi53d uapi53v6 uapi53p uapi53w uapi53t; do
	printf '%s\t' "$i"
	body "$(call "$URL/network/interfaces/$i")" | jq -c .
done > /tmp/uapi53_bodies.tsv
python3 - <<'PY' || fail "a read does not match NetworkInterfacesResponse"
import json, sys
from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

spec = json.load(open('build/openapi.json'))
registry = Registry().with_resource(uri='urn:spec', resource=Resource(contents=spec, specification=DRAFT202012))
def rebase(s):
    if isinstance(s, dict):
        return {k: ('urn:spec' + v) if k == '$ref' and isinstance(v, str) and v.startswith('#/') else rebase(v)
                for k, v in s.items()}
    if isinstance(s, list):
        return [rebase(x) for x in s]
    return s
validator = Draft202012Validator(rebase({'$ref': '#/components/schemas/NetworkInterfacesResponse'}), registry=registry)
failed = 0
for line in open('/tmp/uapi53_bodies.tsv'):
    name, raw = line.rstrip('\n').split('\t', 1)
    for e in validator.iter_errors(json.loads(raw)):
        failed += 1
        print('  %s %s: %s' % (name, '/'.join(str(x) for x in e.absolute_path) or '<root>', e.message))
sys.exit(1 if failed else 0)
PY

echo "network/interfaces proto scope ok"
