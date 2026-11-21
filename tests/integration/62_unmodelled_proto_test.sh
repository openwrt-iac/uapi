#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi
ensure_proto_handlers || { echo "FAIL: the box lacks a tunnel handler, the uapitest handler of this tree, an ip of iproute2 or ucode-mod-rtnl"; exit 1; }

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
IFACES="uapi62a uapi62b uapi62c uapi62d uapi62e"
# On stderr, so that a fail of ends, which runs in a command substitution, still shows.
fail() { echo "FAIL: $*" >&2; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }
body() { printf '%s\n' "$1" | sed '$d'; }
status() { printf '%s\n' "$1" | tail -1; }
send() { call -X "$1" -H 'Content-Type: application/json' "$URL/network/interfaces$2" -d "$3"; }
# uci show prints an option and a one-entry list alike: only the export tells them apart.
form() {
	$SSH "uci export network" | sed -n "/^config interface '$1'/,/^\$/p" \
		| grep -E "^[[:space:]]+(option|list) $2 " | sed 's/^[[:space:]]*//' | tr '\n' ' ' | sed 's/ $//'
}
# "<mtu> <local> <remote>" of a tunnel, or nothing when the link is gone: ip-tiny decodes no vxlan,
# and the rtnl module of ucode decodes no end of a sit, gre or ipip tunnel. A missing tool would
# read as a link that uapi got wrong, so ends stops the test: each call assigns its value, and
# set -e stops on an assignment that fails.
ends() {
	[ -n "$1" ] || return 0
	if [ "$2" = vxlan ]; then
		$SSH "ucode -e 'import * as rtnl from \"rtnl\"; let l = rtnl.request(rtnl.const.RTM_GETLINK, 0, { dev: \"$1\" });
			if (l) print(l.mtu, \" \", l.linkinfo.local, \" \", l.linkinfo.group, \"\\n\");'" \
			|| fail "ucode could not read the link $1 through ucode-mod-rtnl"
	else
		$SSH 'ip -V 2>&1 | grep -q iproute2' || fail "ip on the box is the one of busybox, which decodes no tunnel"
		$SSH "ip -d link show $1" 2>/dev/null | awk '
			NR == 1 { for (i = 1; i < NF; i++) if ($i == "mtu") m = $(i + 1) }
			/ remote / { for (i = 1; i < NF; i++) { if ($i == "remote") r = $(i + 1); if ($i == "local") l = $(i + 1) } }
			END { if (m != "") print m, l, r }'
	fi
}
dev_of() { $SSH "ubus call network.interface.$1 status" 2>/dev/null | jq -r '.l3_device // empty'; }
swept() {
	body "$(call "$URL/uapi/diagnostics?validate=1")" \
		| jq -c --arg id "$1" '[.invalid_sections[]? | select(.id == $id) | .errors[] | .field + ":" + .code]'
}
settled() { wait_iface_settled "$1" || fail "$2: netifd did not set $1 up"; }
idle() {
	sleep 2
	n=0
	until $SSH "ubus call network.interface.$1 status" 2>/dev/null | jq -e '.pending == false' >/dev/null; do
		n=$((n + 1)); [ $n -lt 20 ] || fail "netifd did not settle $1"; sleep 1
	done
}

cleanup() {
	local del=""
	for i in $IFACES; do del="$del uci -q delete network.$i;"; done
	$SSH "$del uci commit network; /etc/init.d/network reload" 2>/dev/null || true
}
trap cleanup EXIT
# A trap that only cleans up lets the test go on after the signal. An exit runs the EXIT trap.
trap 'exit 130' INT
trap 'exit 143' TERM
cleanup

LOCAL=$($SSH 'ubus call network.interface.lan status' | jq -r '."ipv4-address"[0].address // empty')
[ -n "$LOCAL" ] || fail "lan has no IPv4 address to carry the tunnels"
# The kernel takes a local end that no interface holds, so a write of it shows in the link.
MOVED=192.0.2.200

# The tunnels need no peer to come up. nohostroute keeps netifd from waiting for a route to the
# TEST-NET peer, which the CI VM does not have.
echo "--- netifd runs a tunnel that uapi does not model, and a write reaches the handler with every option ---"
for spec in "6in4 uapi62a 192.0.2.62" "gre uapi62b 192.0.2.63" "ipip uapi62c 192.0.2.64" "vxlan uapi62d 192.0.2.65"; do
	set -- $spec
	proto=$1 name=$2 peer=$3
	extra="uci set network.$name.nohostroute=1"
	[ "$proto" = 6in4 ] && extra="$extra; uci set network.$name.ip6addr=2001:db8:62::2/64"
	[ "$proto" = vxlan ] && extra="uci set network.$name.port=4789; uci set network.$name.vid=62"
	$SSH "uci set network.$name=interface; uci set network.$name.proto=$proto; uci set network.$name.ipaddr=$LOCAL
		uci set network.$name.peeraddr=$peer; uci set network.$name.mtu=1400; $extra; uci commit network
		/etc/init.d/network reload"
	settled "$name" "$proto"

	view=$(body "$(call "$URL/network/interfaces/$name")")
	printf '%s' "$view" | jq -e --arg p "$proto" --arg l "$LOCAL" \
		'.proto == $p and .runtime.up and .runtime.effective_proto == $p and .mtu == 1400 and .ipaddrs == [$l]' >/dev/null \
		|| fail "$proto: the read does not report what uci holds and netifd runs: $view"
	dev=$(printf '%s' "$view" | jq -r '.runtime.l3_device')
	link=$(ends "$dev" "$proto")
	[ "$link" = "1400 $LOCAL $peer" ] || fail "$proto: the kernel link is not the one of uci: $link"
	[ "$(swept "$name")" = '[]' ] || fail "$proto: the sweep listed the section: $(swept "$name")"

	before=$($SSH "uci show network.$name" | grep -v '\.mtu=')
	r=$(send PATCH "/$name" '{"mtu":1380}')
	[ "$(status "$r")" = 200 ] || fail "$proto: PATCH mtu: $(body "$r")"
	settled "$name" "$proto after the PATCH of mtu"
	[ "$($SSH "uci show network.$name" | grep -v '\.mtu=')" = "$before" ] \
		|| fail "$proto: the PATCH of mtu changed another option: $($SSH "uci show network.$name")"
	link=$(ends "$(dev_of "$name")" "$proto")
	[ "$link" = "1380 $LOCAL $peer" ] || fail "$proto: the handler did not get the mtu of the PATCH or lost an option: $link"

	r=$(send PATCH "/$name" "{\"ipaddrs\":[\"$MOVED\"]}")
	[ "$(status "$r")" = 200 ] || fail "$proto: PATCH ipaddrs: $(body "$r")"
	[ "$(form "$name" ipaddr)" = "option ipaddr '$MOVED'" ] \
		|| fail "$proto: one address is not stored as an option, which the handler reads: $(form "$name" ipaddr)"
	settled "$name" "$proto after the PATCH of ipaddrs"
	link=$(ends "$(dev_of "$name")" "$proto")
	[ "$link" = "1380 $MOVED $peer" ] || fail "$proto: the handler did not get the address of the PATCH: $link"

	r=$(send PATCH "/$name" '{"disabled":true}')
	[ "$(status "$r")" = 200 ] || fail "$proto: PATCH disabled true: $(body "$r")"
	n=0
	until ! $SSH "ubus call network.interface.$name status" >/dev/null 2>&1; do
		n=$((n + 1)); [ $n -lt 20 ] || fail "$proto: netifd still runs the disabled interface"; sleep 1
	done
	r=$(send PATCH "/$name" '{"disabled":false}')
	[ "$(status "$r")" = 200 ] || fail "$proto: PATCH disabled false: $(body "$r")"
	settled "$name" "$proto after enabling it"
	link=$(ends "$(dev_of "$name")" "$proto")
	[ "$link" = "1380 $MOVED $peer" ] || fail "$proto: the enabled tunnel lost an option: $link"
	echo "  ok: $proto"
done

echo "--- 6in4 reads ip6addr and ipaddr as one value: several are refused, and a stored list is reported ---"
r=$(send PATCH /uapi62a '{"ip6addrs":["2001:db8:62::5/64"]}')
[ "$(status "$r")" = 200 ] || fail "PATCH ip6addrs: $(body "$r")"
settled uapi62a "6in4 after the PATCH of ip6addrs"
$SSH "ip -6 addr show dev $(dev_of uapi62a)" | grep -q 'inet6 2001:db8:62::5/64' \
	|| fail "the handler did not get the ip6addr of the PATCH: $($SSH "ip -6 addr show dev $(dev_of uapi62a)")"
before=$($SSH 'uci show network.uapi62a')
r=$(send PATCH /uapi62a "{\"ipaddrs\":[\"$LOCAL\",\"$MOVED\"]}")
[ "$(status "$r")" = 422 ] && body "$r" | jq -e '[.errors[] | .field + ":" + .code] == ["ipaddrs:conflict"]' >/dev/null \
	|| fail "two addresses for the one ipaddr of 6in4 were not refused: $(body "$r")"
[ "$($SSH 'uci show network.uapi62a')" = "$before" ] || fail "the refused PATCH changed the section"
# A list from a hand edit or an earlier uapi never reaches the handler, which then takes the address
# of the interface that holds the default route as the local end, or stays down without one. No
# interface holds MOVED, so the handler has it only from uci.
$SSH "uci delete network.uapi62a.ipaddr; uci add_list network.uapi62a.ipaddr=$MOVED; uci commit network; /etc/init.d/network reload"
idle uapi62a
link=$(ends 6in4-uapi62a 6in4)
case "$link" in
	*" $MOVED "*) fail "the handler got a uci list for its string ipaddr, so the report guards nothing" ;;
esac
[ "$(swept uapi62a)" = '["ipaddrs:conflict"]' ] || fail "the sweep does not report the stored list: $(swept uapi62a)"
r=$(send PATCH /uapi62a "{\"ipaddrs\":[\"$MOVED\"]}")
[ "$(status "$r")" = 200 ] || fail "the PATCH that sends the address back: $(body "$r")"
settled uapi62a "6in4 after the address was sent back"
[ "$(form uapi62a ipaddr)" = "option ipaddr '$MOVED'" ] || fail "the PATCH kept the list: $(form uapi62a ipaddr)"
link=$(ends 6in4-uapi62a 6in4)
[ "$link" = "1380 $MOVED 192.0.2.62" ] || fail "the handler did not get the address: $link"
[ "$(swept uapi62a)" = '[]' ] || fail "the sweep still reports the section: $(swept uapi62a)"

echo "--- a handler that uapi does not know gets every option of uci after a write, its own lists too ---"
$SSH "rm -f /tmp/uapitest-uapi62e.json; uci set network.uapi62e=interface; uci set network.uapi62e.proto=uapitest
	uci set network.uapi62e.ipaddr=10.98.62.1; uci set network.uapi62e.peer=192.0.2.66; uci set network.uapi62e.flag=1
	uci add_list network.uapi62e.servers=a.example; uci add_list network.uapi62e.servers=b.example
	uci commit network; /etc/init.d/network reload"
settled uapi62e uapitest
got() { $SSH 'cat /tmp/uapitest-uapi62e.json' | jq -c '{ipaddr, peer, servers, flag}'; }
want='{"ipaddr":"10.98.62.1","peer":"192.0.2.66","servers":["a.example","b.example"],"flag":true}'
[ "$(got)" = "$want" ] || fail "the test handler did not get the config of uci: $(got)"
$SSH 'rm -f /tmp/uapitest-uapi62e.json'
r=$(send PATCH /uapi62e '{"ipaddrs":["10.98.62.2"],"mtu":1400}')
[ "$(status "$r")" = 200 ] || fail "PATCH on the test handler: $(body "$r")"
settled uapi62e "uapitest after the PATCH"
want='{"ipaddr":"10.98.62.2","peer":"192.0.2.66","servers":["a.example","b.example"],"flag":true}'
[ "$(got)" = "$want" ] || fail "the test handler lost an option or the value of the PATCH: $(got)"
r=$(send PATCH /uapi62e '{"ipaddrs":["10.98.62.2","10.98.62.3"]}')
[ "$(status "$r")" = 422 ] || fail "two addresses for the string ipaddr of the test handler were not refused: $(body "$r")"

for name in $IFACES; do
	dev=$(dev_of "$name")
	r=$(call -X DELETE "$URL/network/interfaces/$name")
	[ "$(status "$r")" = 204 ] || fail "DELETE $name: $(body "$r")"
	n=0
	while [ -n "$dev" ] && $SSH "ip link show $dev" >/dev/null 2>&1; do
		n=$((n + 1)); [ $n -lt 20 ] || fail "the link $dev of $name is still there after the DELETE"; sleep 1
	done
done

echo "OK: 62_unmodelled_proto"
