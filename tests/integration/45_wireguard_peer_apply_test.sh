#!/bin/sh
set -eu

# netifd reads peer sections with `config_foreach wireguard_<iface>` inside the
# proto setup step, so editing a peer leaves the parent `interface` section
# untouched and `/etc/init.d/network reload` converges nothing. Before 2.4.1 a
# peer was committed to uci, answered 200, and never reached the kernel, and a
# DELETE answered 204 while the peer stayed live: revoking access through the API
# did not revoke it. The peer steps check the kernel with `wg show` and `ip route`,
# and no ifup runs between a peer write and its check. The last steps check what a
# write of network/interfaces refuses for a stored value that wg cannot use, and
# bring the interface up by hand to show that wg would fail on that value.

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }
body_of() { printf '%s\n' "$1" | sed '$d'; }
status_of() { printf '%s\n' "$1" | tail -1; }
id_of() { echo "$1" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//'; }

# apk-tools 3 `list -i` prints any package present in the INDEX, installed or
# not, so the previous `apk list -i ... | grep -q` guard was always true, the
# install never ran, and this entire file skipped itself in CI while reporting
# success. Missing the module is now a failure: a wireguard file that quietly
# does nothing is worse than one that fails.
if ! ensure_wireguard; then
	echo "[45_wgpeer] FAIL: no usable wireguard support, so none of the assertions below ran"
	echo "[45_wgpeer] uname -r: $($SSH 'uname -r')"
	echo "[45_wgpeer] modules:  $($SSH 'find /lib/modules/$(uname -r)/ -name "wireguard*" 2>/dev/null | head -3')"
	echo "[45_wgpeer] protos:   $($SSH 'ubus call network get_proto_handlers 2>/dev/null | grep -c wireguard')"
	exit 1
fi

IFACE=wgpa
IFACE2=wgpb
IFACE3=wgpc
PRIV='yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk='
PEER1='xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg='
PEER2='TrMvSoP4jYQlY6RIzBgbssQqY3vxI2Pi+y71lOWWXX0='
PEER3='mDpFbfhjQlpPqYFJRSKBRRJdPjRlnQhqBSVvhoLLRWc='
PEER4='TWlzY2VsbGFuZW91c1BlZXJLZXlGb3JUZXN0aW5nMD0='

# Peers outlive their parent in uci, and a peer section whose interface is gone
# would be left behind for every later run to trip over, so they go first.
cleanup() {
	for i in $IFACE $IFACE2 $IFACE3; do
		$SSH "ifdown $i >/dev/null 2>&1 || true
		      for s in \$(uci show network | sed -n \"s/^network\\.\\([^.]*\\)=wireguard_$i\$/\\1/p\"); do
		          uci -q delete network.\$s
		      done
		      uci -q delete network.$i 2>/dev/null || true
		      uci -q commit network" >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

echo "--- create the parent wireguard interface ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d "{\"proto\":\"wireguard\",\"id\":\"$IFACE\",
	    \"private_key\":\"$PRIV\",\"addresses\":[\"10.98.98.1/30\"]}")
[ "$(status_of "$r")" = "200" ] || fail "POST interface: $(body_of "$r")"

# netifd keys admin-down state on the interface NAME and keeps it across the uci
# section being deleted and recreated, so the ifdown in the last step below would
# leave the next run's interface with autostart=false and no netdev. `up` clears
# it, where ifup runs down first and took away the netdev that the reload of the
# write had made, between the loop below and its last check. It is setup only: no
# ifup appears between a peer write and the `wg show` that checks it, which is the
# whole point of the file.
$SSH "ubus call network.interface.$IFACE up" >/dev/null 2>&1 || true
n=0
while [ $n -lt 15 ]; do
	$SSH "ip link show $IFACE" >/dev/null 2>&1 && break
	n=$((n + 1)); sleep 1
done
$SSH "ip link show $IFACE" >/dev/null 2>&1 || fail "netdev $IFACE never appeared"

kernel_peers() { $SSH "wg show $IFACE peers 2>/dev/null" || true; }
has_peer() { kernel_peers | grep -qxF "$1"; }
read_peer() { body_of "$(call "$URL/network/wireguard_peers/$1")" | jq -c "$2"; }

echo "--- POST a peer reaches the kernel with no ifup ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER1\",
	    \"allowed_ips\":[\"10.98.99.2/32\"],\"endpoint_host\":\"198.51.100.7\",
	    \"endpoint_port\":51820}")
[ "$(status_of "$r")" = "200" ] || fail "POST peer: $(body_of "$r")"
pid=$(id_of "$r")
has_peer "$PEER1" || fail "peer not in kernel after POST; wg show: $(kernel_peers)"

echo "--- a read reports what the kernel holds for the peer, and a write does not read it ---"
[ "$(body_of "$r" | jq -c .runtime)" = '{}' ] || fail "the POST answered the runtime $(body_of "$r" | jq -c .runtime)"
rt=$(read_peer "$pid" '.runtime | [.in_kernel, .endpoint, .allowed_ips, .persistent_keepalive, (.latest_handshake | type), (.rx_bytes | type), (.tx_bytes | type)]')
[ "$rt" = '[true,"198.51.100.7:51820",["10.98.99.2/32"],0,"number","number","number"]' ] \
	|| fail "the runtime after the POST reads $rt; wg show: $($SSH "wg show $IFACE dump | sed 1d | cut -f1,3-8")"

echo "--- PATCH the endpoint reaches the kernel ---"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/$pid" \
	-d '{"endpoint_host":"198.51.100.9"}')
[ "$(status_of "$r")" = "200" ] || fail "PATCH peer: $(body_of "$r")"
$SSH "wg show $IFACE endpoints" | grep -q '198.51.100.9' \
	|| fail "endpoint not updated in kernel: $($SSH "wg show $IFACE endpoints")"
[ "$(read_peer "$pid" '[.endpoint_host, .runtime.endpoint]')" = '["198.51.100.9","198.51.100.9:51820"]' ] \
	|| fail "the runtime after the PATCH reads $(read_peer "$pid" .runtime)"

# A PATCH that changed nothing still reloaded network and set the peer again in the kernel, which
# for a peer without an endpoint is a remove and a set, and resets its session. A PUT of the read
# did the same, alone and in a batch, because a PUT set every option that it sent. The keepalive
# that wg sets here by hand is drift from uci, which only a write that sets the peer gives back to
# uci. The POST stored no `route_allowed_ips` or `disabled`, and a PUT of the read wrote the
# defaults that the read fills in for them, so even the first PUT of the read has to change nothing.
echo "--- a PATCH that changes nothing, and a PUT of the read alone and in a batch, reload nothing and leave the kernel peer as it is ---"
keepalive() { $SSH "wg show $IFACE persistent-keepalive" | awk -v k="$PEER1" '$1 == k { print $2 }'; }
write_headers() {
	curl -sS -D - -o /tmp/uapi45_patch.json -H "$ADMIN" -H 'Content-Type: application/json' \
		-X "$1" "$URL$2" -d "$3" | tr -d '\r'
}
patch_headers() { write_headers PATCH "/network/wireguard_peers/$pid" "$1"; }
assert_noop() {
	echo "$2" | head -1 | grep -q " $3 " || fail "$1: $2 $(cat /tmp/uapi45_patch.json)"
	echo "$2" | grep -qix 'X-Reload-Status: no_reload' && echo "$2" | grep -qix 'X-Kernel-Status: no_kernel' \
		&& ! echo "$2" | grep -qi '^X-Reload-Services:' && ! echo "$2" | grep -qi '^X-Kernel-Applied:' \
		|| fail "$1 changed nothing and reported a reload or a kernel apply: $2"
	[ "$(keepalive)" = 77 ] || fail "$1 changed nothing and set the peer again: keepalive $(keepalive)"
}
$SSH "wg set $IFACE peer $PEER1 persistent-keepalive 77"
[ "$(read_peer "$pid" '[.persistent_keepalive, .runtime.in_kernel, .runtime.persistent_keepalive]')" = '[null,true,77]' ] \
	|| fail "a read does not report the keepalive that wg set by hand: $(read_peer "$pid" '[.persistent_keepalive, .runtime]')"
for body in '{}' '{"endpoint_host": "198.51.100.9", "endpoint_port": 51820}'; do
	assert_noop "PATCH $body" "$(patch_headers "$body")" 200
done
read_body=$(curl -sS -H "$ADMIN" "$URL/network/wireguard_peers/$pid" | jq -c 'del(.runtime)')
assert_noop "a PUT of the read" "$(write_headers PUT "/network/wireguard_peers/$pid" "$read_body")" 200
assert_noop "a batch PUT of the read" "$(write_headers POST /uapi/batch \
	"{\"operations\": [{\"path\": \"/network/wireguard_peers/$pid\", \"method\": \"PUT\", \"body\": $read_body}]}")" 207

echo "--- a PATCH that changes only the preshared key reaches the kernel ---"
PSK=$($SSH 'wg genpsk')
h=$(patch_headers "{\"preshared_key\": \"$PSK\"}")
echo "$h" | head -1 | grep -q ' 200 ' || fail "PATCH preshared_key: $h $(cat /tmp/uapi45_patch.json)"
echo "$h" | grep -qix 'X-Kernel-Status: ok' && echo "$h" | grep -qix "X-Kernel-Applied: $IFACE" \
	|| fail "a new preshared key did not reach the kernel: $h"
$SSH "wg show $IFACE preshared-keys" | grep -qF "$PSK" || fail "wg holds another preshared key"
body_of "$(call "$URL/network/wireguard_peers/$pid")" | grep -qF "$PSK" && fail "a read shows the preshared key"
call "$URL/network/wireguard_peers" | grep -qF "$PSK" && fail "a collection read shows the preshared key"

echo "--- DELETE actually revokes the peer ---"
r=$(call -X DELETE "$URL/network/wireguard_peers/$pid")
[ "$(status_of "$r")" = "204" ] || fail "DELETE peer: $(body_of "$r")"
has_peer "$PEER1" && fail "peer STILL live in kernel after DELETE (access not revoked)"

echo "--- a batch of peers on one interface all land ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/uapi/batch" -d "{\"operations\":[
	{\"path\":\"/network/wireguard_peers\",\"method\":\"POST\",
	 \"body\":{\"interface\":\"$IFACE\",\"public_key\":\"$PEER1\",
	           \"allowed_ips\":[\"10.98.99.4/32\"]}},
	{\"path\":\"/network/wireguard_peers\",\"method\":\"POST\",
	 \"body\":{\"interface\":\"$IFACE\",\"public_key\":\"$PEER2\",
	           \"allowed_ips\":[\"10.98.99.5/32\"]}}]}")
[ "$(status_of "$r")" = "207" ] || fail "batch: $(body_of "$r")"
has_peer "$PEER1" || fail "batch peer 1 not in kernel"
has_peer "$PEER2" || fail "batch peer 2 not in kernel"
held=$(body_of "$(call "$URL/network/wireguard_peers")" | jq -c --arg i "$IFACE" --arg a "$PEER1" --arg b "$PEER2" \
	'[.[] | select(.interface == $i and (.public_key == $a or .public_key == $b)) | [.public_key == $a, .runtime.in_kernel, .runtime.allowed_ips]] | sort')
[ "$held" = '[[false,true,["10.98.99.5/32"]],[true,true,["10.98.99.4/32"]]]' ] || fail "a collection read reports the batch peers as $held"
bid=$(body_of "$r" | jq -r '.results[0].body.id')
r=$(call -X POST -H 'Content-Type: application/json' "$URL/uapi/batch" -d "{\"operations\":[
	{\"path\":\"/network/wireguard_peers/$bid\",\"method\":\"PATCH\",\"body\":{\"description\":\"b\"}},
	{\"path\":\"/network/wireguard_peers/$bid\",\"method\":\"GET\"}]}")
[ "$(status_of "$r")" = "207" ] || fail "batch of a PATCH and a GET: $(body_of "$r")"
[ "$(body_of "$r" | jq -c '[.results[].body.runtime]')" = '[{},{}]' ] || fail "a batch that writes read the kernel: $(body_of "$r")"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/uapi/batch" \
	-d "{\"operations\":[{\"path\":\"/network/wireguard_peers/$bid\",\"method\":\"GET\"}]}")
[ "$(body_of "$r" | jq -c '.results[0].body.runtime.in_kernel')" = true ] || fail "a batch of reads did not read the kernel: $(body_of "$r")"
$SSH "ip link show $IFACE" >/dev/null 2>&1 || fail "tunnel torn down by the batch"

# runtime reports the kernel beside each section, so a peer with no section was the only
# wireguard state that no read showed. The collection lists the kernel peers that no section
# of their interface claims, and refuses every write.
echo "--- the kernel peers that no section claims are listed, read-only ---"
STRAY=$($SSH 'wg genkey | wg pubkey')
$SSH "wg set $IFACE peer '$STRAY' allowed-ips 10.98.99.90/32"
r=$(call "$URL/network/wireguard_kernel_peers")
[ "$(status_of "$r")" = "200" ] || fail "the kernel peers read expected 200, got $(status_of "$r"): $(body_of "$r")"
want_id=$($SSH "printf '%s' '$IFACE $STRAY' | sha256sum" | cut -c1-12)
got=$(body_of "$r" | jq -c --arg k "$STRAY" \
	'map(select(.public_key == $k)) | map({id, interface, public_key, endpoint, allowed_ips}) | .[0]')
[ "$got" = "{\"id\":\"$want_id\",\"interface\":\"$IFACE\",\"public_key\":\"$STRAY\",\"endpoint\":null,\"allowed_ips\":[\"10.98.99.90/32\"]}" ] \
	|| fail "the kernel peers read lists $got, want the stray peer with id $want_id: $(body_of "$r")"
listed=$(body_of "$(call "$URL/network/wireguard_kernel_peers")" | jq -r '[.[].public_key] | sort | join(",")')
[ "$listed" = "$STRAY" ] || fail "the kernel peers read lists '$listed', which is not only the stray peer"
r=$(call "$URL/network/wireguard_kernel_peers/$want_id")
[ "$(status_of "$r")" = "200" ] || fail "one kernel peer read expected 200, got $(status_of "$r"): $(body_of "$r")"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_kernel_peers" -d '{}')
[ "$(status_of "$r")" = "405" ] || fail "a POST expected 405, got $(status_of "$r"): $(body_of "$r")"
body_of "$r" | grep -q '"code": "method_not_allowed"' || fail "the POST refusal is not method_not_allowed: $(body_of "$r")"
r=$(call -X DELETE "$URL/network/wireguard_kernel_peers/$want_id")
[ "$(status_of "$r")" = "405" ] || fail "a DELETE expected 405, got $(status_of "$r"): $(body_of "$r")"
r=$(curl -sS -H "Authorization: Bearer $FW_RO_TOKEN" -w "\n%{http_code}" "$URL/network/wireguard_kernel_peers")
[ "$(status_of "$r")" = "403" ] || fail "a firewall-only token expected 403, got $(status_of "$r"): $(body_of "$r")"
$SSH "wg set $IFACE peer '$STRAY' remove"
[ "$(body_of "$(call "$URL/network/wireguard_kernel_peers")" | jq -c '.')" = '[]' ] \
	|| fail "the kernel peers read after the remove is not empty"

# The whole reason the apply is per-peer rather than a netifd interface renew. A
# renew is asynchronous and takes the interface down when the config it reads is
# bad, so this request used to answer 200 while dropping a working tunnel and its
# healthy peers. An unresolvable endpoint is not exotic: a typo produces it, and
# so does a dynamic-DNS name that has not propagated.
echo "--- a peer with an unresolvable endpoint fails alone, tunnel untouched ---"
before=$(kernel_peers | wc -l)
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",
	    \"allowed_ips\":[\"10.98.99.30/32\"],\"endpoint_host\":\"nx.invalid\",
	    \"endpoint_port\":51820}")
[ "$(status_of "$r")" = "500" ] || fail "bad endpoint expected 500, got $(status_of "$r"): $(body_of "$r")"
echo "$(body_of "$r")" | grep -q 'does not resolve' \
	|| fail "expected the resolver error to be reported: $(body_of "$r")"
$SSH "ip link show $IFACE" >/dev/null 2>&1 || fail "tunnel was torn down by a bad peer"
[ "$(kernel_peers | wc -l)" = "$before" ] \
	|| fail "healthy peers changed: was $before, now $(kernel_peers | wc -l)"
$SSH "uci show network | grep -q nx.invalid" && fail "bad peer was not rolled back out of uci"

# The restore after a failed write reapplies every peer from uci, including ones written by hand
# that never passed validate(). It has to read them as wireguard.sh does, and run nothing.
echo "--- a restore applies a hand-written peer as wireguard.sh would, and runs nothing from it ---"
SIB=$($SSH 'wg genkey | wg pubkey')
$SSH "rm -f /tmp/uapi45_ran; uci set network.uapi45sib=wireguard_$IFACE; uci set network.uapi45sib.public_key='$SIB';
	uci set network.uapi45sib.allowed_ips=10.98.99.60/32; uci set network.uapi45sib.endpoint_host=198.51.100.7;
	uci set network.uapi45sib.endpoint_port=https; uci set network.uapi45sib.persistent_keepalive='0;touch /tmp/uapi45_ran';
	uci commit network"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",
	    \"allowed_ips\":[\"10.98.99.30/32\"],\"endpoint_host\":\"nx.invalid\",\"endpoint_port\":51820}")
[ "$(status_of "$r")" = "500" ] || fail "bad endpoint expected 500 again, got $(status_of "$r"): $(body_of "$r")"
endpoint=$($SSH "wg show $IFACE endpoints" | awk -v k="$SIB" '$1 == k { print $2 }')
$SSH "uci delete network.uapi45sib; uci commit network; wg set $IFACE peer '$SIB' remove"
$SSH "[ ! -e /tmp/uapi45_ran ]" || fail "a stored persistent_keepalive ran as a shell command"
[ "$endpoint" = "198.51.100.7:443" ] || fail "the restore applied endpoint_port 'https' as '$endpoint', not 198.51.100.7:443"

# The restore gives a hand-written endpoint_host to `wg set`, which must read it as one argument, as
# the write path above does. It runs alone, because the restore stops at the first peer that wg
# refuses.
echo "--- a restore gives a hand-written endpoint_host to wg as one argument, and runs nothing from it ---"
SIB2=$($SSH 'wg genkey | wg pubkey')
$SSH "rm -f /tmp/uapi45_ep; uci set network.uapi45sib2=wireguard_$IFACE; uci set network.uapi45sib2.public_key='$SIB2';
	uci set network.uapi45sib2.allowed_ips=10.98.99.62/32; uci set network.uapi45sib2.endpoint_port=51820;
	uci set network.uapi45sib2.endpoint_host='x\$(touch\${IFS}/tmp/uapi45_ep)y'; uci commit network"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",
	    \"allowed_ips\":[\"10.98.99.30/32\"],\"endpoint_host\":\"nx.invalid\",\"endpoint_port\":51820}")
[ "$(status_of "$r")" = "500" ] || fail "bad endpoint expected 500 again, got $(status_of "$r"): $(body_of "$r")"
$SSH "uci delete network.uapi45sib2; uci commit network"
$SSH "[ ! -e /tmp/uapi45_ep ]" || fail "a stored endpoint_host ran as a shell command"

# wireguard.sh writes no [Peer] for a section without a key, and no AllowedIPs line for a peer
# without allowed IPs, which LuCI leaves optional, so ifup takes both. The restore stopped at the
# first of them, answered reload_failed_unrecovered, and set none of the peers after it. The kernel
# holds an allowed IP for the peer that uci holds none for, so the restore has to clear the list,
# which it does with `wg set <if> peer <key> allowed-ips ""`. The peer has an endpoint, so the
# restore sets it without removing it first, and only that argument can clear the list.
echo "--- a restore skips a peer without a key, clears the allowed IPs of a peer without any, and sets the peers after them ---"
NOIPS=$($SSH 'wg genkey | wg pubkey')
AFTER=$($SSH 'wg genkey | wg pubkey')
$SSH "uci set network.uapi45nokey=wireguard_$IFACE; uci add_list network.uapi45nokey.allowed_ips=10.98.99.64/32
	uci set network.uapi45noips=wireguard_$IFACE; uci set network.uapi45noips.public_key='$NOIPS'
	uci set network.uapi45noips.endpoint_host=198.51.100.7; uci set network.uapi45noips.endpoint_port=51820
	uci set network.uapi45after=wireguard_$IFACE; uci set network.uapi45after.public_key='$AFTER'
	uci add_list network.uapi45after.allowed_ips=10.98.99.65/32; uci commit network
	wg set $IFACE peer '$NOIPS' allowed-ips 10.98.99.66/32"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",
	    \"allowed_ips\":[\"10.98.99.30/32\"],\"endpoint_host\":\"nx.invalid\",\"endpoint_port\":51820}")
noips=$($SSH "wg show $IFACE allowed-ips" | awk -v k="$NOIPS" '$1 == k { print $2 }')
after=$(has_peer "$AFTER" && echo yes || echo no)
$SSH "uci delete network.uapi45nokey; uci delete network.uapi45noips; uci delete network.uapi45after; uci commit network
	wg set $IFACE peer '$NOIPS' remove; wg set $IFACE peer '$AFTER' remove"
[ "$(status_of "$r")" = "500" ] || fail "bad endpoint expected 500 again, got $(status_of "$r"): $(body_of "$r")"
body_of "$r" | grep -q '"code": "reload_failed_restored"' || fail "the restore did not recover: $(body_of "$r")"
[ "$noips" = "(none)" ] || fail "the peer without allowed IPs holds '$noips' in the kernel, not (none)"
[ "$after" = "yes" ] || fail "the restore did not set the peer after the peer without a key"

# ifup sets no peer at all for a preshared key that wg cannot read, because wg refuses the whole
# config. The restore refused such a peer and set none of the peers after it. Set with /dev/null, the
# peer would lose the key that the kernel holds, so the restore keeps it as the kernel holds it, and
# fails, after it set the other peers, only when the kernel does not hold it.
echo "--- a restore keeps a peer whose stored preshared key wg cannot read as the kernel holds it, and sets the peers after it ---"
BADPSK=$($SSH 'wg genkey | wg pubkey')
AFTER2=$($SSH 'wg genkey | wg pubkey')
$SSH "wg genpsk > /tmp/uapi45psk; wg set $IFACE peer '$BADPSK' allowed-ips 10.98.99.80/32 preshared-key /tmp/uapi45psk
	uci set network.uapi45badpsk=wireguard_$IFACE; uci set network.uapi45badpsk.public_key='$BADPSK'
	uci add_list network.uapi45badpsk.allowed_ips=10.98.99.80/32; uci set network.uapi45badpsk.preshared_key=not-a-key
	uci set network.uapi45after2=wireguard_$IFACE; uci set network.uapi45after2.public_key='$AFTER2'
	uci add_list network.uapi45after2.allowed_ips=10.98.99.81/32; uci commit network"
bad_write() {
	call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
		-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",
		    \"allowed_ips\":[\"10.98.99.30/32\"],\"endpoint_host\":\"nx.invalid\",\"endpoint_port\":51820}"
}
r=$(bad_write)
psk=$($SSH "wg show $IFACE preshared-keys" | awk -v k="$BADPSK" '$1 == k { print $2 }')
after=$(has_peer "$AFTER2" && echo yes || echo no)
[ "$(status_of "$r")" = "500" ] || fail "bad endpoint expected 500 again, got $(status_of "$r"): $(body_of "$r")"
body_of "$r" | grep -q '"code": "reload_failed_restored"' || fail "the restore stopped at the malformed preshared key: $(body_of "$r")"
[ "$psk" = "$($SSH 'cat /tmp/uapi45psk')" ] || fail "the restore changed the preshared key that the kernel holds to '$psk'"
[ "$after" = "yes" ] || fail "the restore did not set the peer after the peer with a malformed preshared key"
# A batch that sets the peer before a later operation fails leaves the kernel with the key that it
# set, which the restore cannot take back, so it must not answer that it restored the peer.
PSK2=$($SSH 'wg genpsk')
r=$(call -X POST -H 'Content-Type: application/json' "$URL/uapi/batch" -d "{\"operations\":[
	{\"path\":\"/network/wireguard_peers/uapi45badpsk\",\"method\":\"PATCH\",
	 \"body\":{\"preshared_key\":\"$PSK2\",\"allowed_ips\":[\"10.98.99.80/32\",\"10.98.99.82/32\"]}},
	{\"path\":\"/network/wireguard_peers\",\"method\":\"POST\",
	 \"body\":{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",\"allowed_ips\":[\"10.98.99.30/32\"],
	           \"endpoint_host\":\"nx.invalid\",\"endpoint_port\":51820}}]}")
psk=$($SSH "wg show $IFACE preshared-keys" | awk -v k="$BADPSK" '$1 == k { print $2 }')
[ "$(status_of "$r")" = "500" ] || fail "batch with a bad endpoint expected 500, got $(status_of "$r"): $(body_of "$r")"
body_of "$r" | grep -q '"code": "reload_failed_unrecovered"' \
	|| fail "the restore answered that it restored a peer that the batch set: $(body_of "$r")"
[ "$psk" = "$PSK2" ] || fail "the kernel does not hold the preshared key that the batch set: '$psk'"
[ "$($SSH "uci get network.uapi45badpsk.preshared_key")" = "not-a-key" ] || fail "the restore did not put back the stored preshared key"
$SSH "wg set $IFACE peer '$BADPSK' remove; wg set $IFACE peer '$AFTER2' remove"
r=$(bad_write)
after=$(has_peer "$AFTER2" && echo yes || echo no)
held=$(has_peer "$BADPSK" && echo yes || echo no)
$SSH "uci delete network.uapi45badpsk; uci delete network.uapi45after2; uci commit network; rm -f /tmp/uapi45psk
	wg set $IFACE peer '$AFTER2' remove; wg set $IFACE peer '$BADPSK' remove"
[ "$(status_of "$r")" = "500" ] || fail "bad endpoint expected 500 again, got $(status_of "$r"): $(body_of "$r")"
body_of "$r" | grep -q '"code": "reload_failed_unrecovered"' && body_of "$r" | grep -q 'malformed preshared key' \
	|| fail "the restore did not report the peer that it left out: $(body_of "$r")"
[ "$after" = "yes" ] || fail "the restore did not set the peer after the peer that the kernel does not hold"
[ "$held" = "no" ] || fail "the restore set the peer with a malformed preshared key"

# Rotating a key leaves the kernel holding the previous peer under the old key
# unless the old one is removed first, which would keep its access alive.
echo "--- rotating a public key removes the old peer from the kernel ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",\"allowed_ips\":[\"10.98.99.31/32\"]}")
[ "$(status_of "$r")" = "200" ] || fail "POST peer to rotate: $(body_of "$r")"
rid=$(id_of "$r")
has_peer "$PEER3" || fail "peer not installed before rotation"
r=$(call -X PUT -H 'Content-Type: application/json' "$URL/network/wireguard_peers/$rid" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER4\",\"allowed_ips\":[\"10.98.99.31/32\"]}")
[ "$(status_of "$r")" = "200" ] || fail "PUT rotate: $(body_of "$r")"
has_peer "$PEER3" && fail "old public key STILL installed after rotation (access not revoked)"
has_peer "$PEER4" || fail "rotated public key not installed"

# netifd omits a disabled peer when it builds the config, so the kernel must not
# carry one either.
echo "--- disabling a peer removes it from the kernel, re-enabling puts it back ---"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/$rid" \
	-d '{"disabled":true}')
[ "$(status_of "$r")" = "200" ] || fail "PATCH disabled: $(body_of "$r")"
has_peer "$PEER4" && fail "disabled peer is still installed in the kernel"
[ "$(read_peer "$rid" '[.disabled, .runtime.in_kernel, .runtime.endpoint, .runtime.allowed_ips]')" = '[true,false,null,null]' ] \
	|| fail "the read of the disabled peer reports $(read_peer "$rid" .runtime)"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/$rid" \
	-d '{"disabled":false}')
[ "$(status_of "$r")" = "200" ] || fail "PATCH re-enable: $(body_of "$r")"
has_peer "$PEER4" || fail "re-enabled peer was not reinstalled"
call -X DELETE "$URL/network/wireguard_peers/$rid" >/dev/null

# endpoint_host reaches a shell command. validate_new() refuses only escapes, newlines, and
# brackets with a colon in it, so this host reaches `wg set`, which must read it as one argument and fail to
# resolve it. A regression here is remote command execution, not a cosmetic bug.
echo "--- a command substitution in endpoint_host does not execute ---"
$SSH "rm -f /tmp/uapi-wg-injection" >/dev/null 2>&1
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",\"allowed_ips\":[\"10.98.99.32/32\"],
	    \"endpoint_host\":\"x\$(touch /tmp/uapi-wg-injection)y\",\"endpoint_port\":51820}")
[ "$(status_of "$r")" = "500" ] || fail "endpoint_host with a command substitution expected 500 from wg, got $(status_of "$r")"
$SSH "test -f /tmp/uapi-wg-injection" >/dev/null 2>&1 \
	&& fail "endpoint_host was interpolated into the shell and executed"

# int() read "::/0;id>uapi45_route;" as ::/0, and the DELETE of a disabled peer handed the stored
# prefix to `ip route del` through a shell, which ran `id` as root. A write refuses that prefix now,
# also on a disabled peer, because another writer can enable it later. A peer written by hand
# with the prefix must run nothing when the API deletes it. wireguard.sh expands the escapes of the
# config it gives `wg syncconf`, so an escape in endpoint_host is refused too, with or without a
# bracket, and so is a bracketed IPv6 address, which wireguard.sh brackets again.
echo "--- an allowed IP with a tail, an escape or a bracketed IPv6 address in endpoint_host is refused, and a stored one runs nothing ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",\"allowed_ips\":[\"::/0;id>uapi45_route;\"],
	    \"route_allowed_ips\":true,\"disabled\":true}")
[ "$(status_of "$r")" = "422" ] || fail "allowed IP with a tail expected 422, got $(status_of "$r"): $(body_of "$r")"
for host in '192.0.2.1\\0072443\\nPublicKey=x' '192.0.2.1\\0072443\\n[Peer]' '[fd00::1]'; do
	r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
		-d '{"interface":"'"$IFACE"'","public_key":"'"$PEER3"'","allowed_ips":["10.98.99.33/32"],
		    "endpoint_host":"'"$host"'","endpoint_port":51820}')
	[ "$(status_of "$r")" = "422" ] || fail "endpoint_host $host expected 422, got $(status_of "$r"): $(body_of "$r")"
done
ROUTE_PEER=$($SSH 'wg genkey | wg pubkey')
$SSH "uci set network.uapi45rt=wireguard_$IFACE; uci set network.uapi45rt.public_key='$ROUTE_PEER'
	uci add_list network.uapi45rt.allowed_ips='::/0;id>uapi45_route;'
	uci set network.uapi45rt.route_allowed_ips=1; uci commit network"
r=$(call -X DELETE "$URL/network/wireguard_peers/uapi45rt")
[ "$(status_of "$r")" = "204" ] || fail "DELETE of the stored peer: $(body_of "$r")"
ran=$($SSH "find / /tmp -xdev -name uapi45_route 2>/dev/null" || true)
[ -z "$ran" ] || { $SSH "find / /tmp -xdev -name uapi45_route -exec rm -f {} +"; fail "a stored allowed IP ran as a shell command: $ran"; }

# route_allowed_ips means "install routes for this peer's allowed IPs". netifd
# does that from its proto handler, so without it here the peer sits in the
# kernel with no path to it and the feature only half works. The spelling is
# asserted against what netifd itself installs rather than against a literal, so
# a future divergence in netifd's route attributes shows up here.
echo "--- route_allowed_ips installs routes, matching netifd's own spelling ---"
static_routes() { $SSH "ip route show dev $IFACE proto static 2>/dev/null | sort" || true; }
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",
	    \"allowed_ips\":[\"10.98.120.0/24\",\"10.98.121.7/32\"],\"route_allowed_ips\":true}")
[ "$(status_of "$r")" = "200" ] || fail "POST routed peer: $(body_of "$r")"
routed=$(id_of "$r")
[ -n "$(static_routes)" ] || fail "route_allowed_ips installed no routes"
ours=$(static_routes)
$SSH "ifup $IFACE" >/dev/null 2>&1; sleep 5
[ "$ours" = "$(static_routes)" ] \
	|| fail "our routes differ from netifd's: ours [$ours] netifd [$(static_routes)]"

# Two peers can carry the same prefix, so a delete must not strand the other one.
echo "--- a prefix another peer still wants survives a delete ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER4\",
	    \"allowed_ips\":[\"10.98.120.0/24\"],\"route_allowed_ips\":true}")
[ "$(status_of "$r")" = "200" ] || fail "POST sharing peer: $(body_of "$r")"
shared=$(id_of "$r")
call -X DELETE "$URL/network/wireguard_peers/$routed" >/dev/null
static_routes | grep -q '10.98.120.0/24' \
	|| fail "shared prefix withdrawn while another peer still wants it"
static_routes | grep -q '10.98.121.7' \
	&& fail "prefix only the deleted peer wanted was not withdrawn"
call -X DELETE "$URL/network/wireguard_peers/$shared" >/dev/null
[ -z "$(static_routes)" ] || fail "routes left behind: $(static_routes)"
$SSH "ip route show dev $IFACE" | grep -q '10.98.98.0/30' \
	|| fail "the interface's own kernel route was removed"

# wireguard.sh reads allowed_ips with config_get, so an option holds one prefix per word, and ifup
# installs a route for each word. The DELETE has to withdraw every one.
echo "--- the DELETE of a hand-written peer withdraws the route of each word of its allowed_ips ---"
WORDS_PEER=$($SSH 'wg genkey | wg pubkey')
$SSH "uci set network.uapi45words=wireguard_$IFACE; uci set network.uapi45words.public_key='$WORDS_PEER'
	uci set network.uapi45words.allowed_ips='10.98.140.0/24 10.98.141.7'; uci set network.uapi45words.route_allowed_ips=1
	uci commit network; ifup $IFACE"
sleep 5
static_routes | grep -q '^10.98.140.0/24 ' || fail "ifup installed no route for the first word: $(static_routes)"
static_routes | grep -q '^10.98.141.7 ' || fail "ifup installed no route for the second word: $(static_routes)"
r=$(call -X DELETE "$URL/network/wireguard_peers/uapi45words")
[ "$(status_of "$r")" = "204" ] || fail "DELETE of the hand-written peer: $(body_of "$r")"
has_peer "$WORDS_PEER" && fail "the hand-written peer is still in the kernel after its DELETE"
[ -z "$(static_routes)" ] || fail "routes left behind by the DELETE: $(static_routes)"

# wireguard.sh hands its config to wg through printf %b, so ifup gives wg a public_key that ends in
# `\075` with an `=` there. A write refuses such a key, and one written by hand keeps it. On an up
# interface, the write that disabled such a peer and its DELETE answered 500, and so did the
# restore of any failed write of the interface.
echo "--- a hand-written key with an escape: ifup sets the key that wg reads, and a write restores around, disables and deletes the peer ---"
ESC_PEER=$($SSH 'wg genkey | wg pubkey')
$SSH "uci set network.uapi45esc=wireguard_$IFACE; uci set network.uapi45esc.public_key='${ESC_PEER%=}\\075'
	uci add_list network.uapi45esc.allowed_ips=10.98.99.70/32; uci commit network; ifup $IFACE"
sleep 5
has_peer "$ESC_PEER" || fail "ifup did not set the key that wireguard.sh expands: $(kernel_peers)"
[ "$(read_peer uapi45esc '[.runtime.in_kernel, .runtime.allowed_ips]')" = '[true,["10.98.99.70/32"]]' ] \
	|| fail "the read does not match the key with an escape to the peer of the kernel: $(read_peer uapi45esc .runtime)"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",
	    \"allowed_ips\":[\"10.98.99.30/32\"],\"endpoint_host\":\"nx.invalid\",\"endpoint_port\":51820}")
[ "$(status_of "$r")" = "500" ] || fail "bad endpoint expected 500 again, got $(status_of "$r"): $(body_of "$r")"
body_of "$r" | grep -q '"code": "reload_failed_restored"' || fail "the restore failed on the peer with an escape: $(body_of "$r")"
has_peer "$ESC_PEER" || fail "the restore removed the peer with an escape from the kernel"
r=$(call -X PATCH -H 'Content-Type: application/json-patch+json' "$URL/network/wireguard_peers/uapi45esc" \
	-d '[{"op":"replace","path":"/description","value":"esc"}]')
# v4 (#308): the stored public_key with an escape is an error the section holds, so any write is refused.
[ "$(status_of "$r")" = "422" ] || fail "JSON Patch of another field of a peer with a stored bad key expected 422 on v4: $(body_of "$r")"
has_peer "$ESC_PEER" || fail "the refused JSON Patch removed the peer with an escape from the kernel"
r=$(call -X PATCH -H 'Content-Type: application/json-patch+json' "$URL/network/wireguard_peers/uapi45esc" \
	-d '[{"op":"replace","path":"/public_key","value":"'"${PEER3%=}"'\\075"}]')
[ "$(status_of "$r")" = "422" ] || fail "a JSON Patch that sets a key with an escape expected 422, got $(status_of "$r"): $(body_of "$r")"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/uapi45esc" -d '{"disabled":true}')
# v4 (#308): the stored bad key blocks every write of the section, disabling included; fix it first.
[ "$(status_of "$r")" = "422" ] || fail "PATCH disabled of the peer with an escape expected 422 on v4: $(body_of "$r")"
has_peer "$ESC_PEER" || fail "the refused PATCH removed the peer with an escape from the kernel"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/uapi45esc" -d '{"disabled":false}')
[ "$(status_of "$r")" = "422" ] || fail "enabling the peer with an escape expected 422, got $(status_of "$r"): $(body_of "$r")"
$SSH "uci set network.uapi45esc.disabled=0; uci commit network; ifup $IFACE"
sleep 5
has_peer "$ESC_PEER" || fail "ifup did not set the re-enabled peer with an escape: $(kernel_peers)"
r=$(call -X DELETE "$URL/network/wireguard_peers/uapi45esc")
[ "$(status_of "$r")" = "204" ] || fail "DELETE of the peer with an escape: $(body_of "$r")"
has_peer "$ESC_PEER" && fail "the deleted peer with an escape is still in the kernel"

# LuCI leaves the allowed IPs of a peer optional, and wg sets such a peer with none. A write
# required them, so a peer without any took no write, not even the one that disables it.
echo "--- a peer without allowed IPs is created, disabled and deleted, and the kernel holds it with none ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\"}")
[ "$(status_of "$r")" = "200" ] || fail "POST of a peer without allowed IPs: $(body_of "$r")"
noips=$(id_of "$r")
aips=$($SSH "wg show $IFACE allowed-ips" | awk -v k="$PEER3" '$1 == k { print $2 }')
[ "$aips" = "(none)" ] || fail "the peer without allowed IPs holds '$aips' in the kernel, not (none)"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/$noips" -d '{"disabled":true}')
[ "$(status_of "$r")" = "200" ] || fail "PATCH disabled of a peer without allowed IPs: $(body_of "$r")"
has_peer "$PEER3" && fail "the disabled peer without allowed IPs is still in the kernel"
r=$(call -X DELETE "$URL/network/wireguard_peers/$noips")
[ "$(status_of "$r")" = "204" ] || fail "DELETE of a peer without allowed IPs: $(body_of "$r")"

# A list entry is joined like an option, so it reads as its two prefixes, which wg holds and which
# have a route each. Read whole, it answered 422, and a write that turned the routes off kept both.
echo "--- a list entry of two prefixes reads as both, and turning its routes off withdraws both ---"
$SSH "uci set network.uapi45list=wireguard_$IFACE; uci set network.uapi45list.public_key='$WORDS_PEER'
	uci add_list network.uapi45list.allowed_ips='10.98.142.0/24 10.98.143.7'; uci set network.uapi45list.route_allowed_ips=1
	uci commit network; ifup $IFACE"
sleep 5
static_routes | grep -q '^10.98.142.0/24 ' || fail "ifup installed no route for the first prefix: $(static_routes)"
static_routes | grep -q '^10.98.143.7 ' || fail "ifup installed no route for the second prefix: $(static_routes)"
view=$(body_of "$(call "$URL/network/wireguard_peers/uapi45list")")
[ "$(printf '%s' "$view" | jq -c '.allowed_ips')" = '["10.98.142.0/24","10.98.143.7"]' ] || fail "the list entry read wrong: $view"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/uapi45list" -d '{"route_allowed_ips":false}')
[ "$(status_of "$r")" = "200" ] || fail "turning the routes off expected 200, got $(status_of "$r"): $(body_of "$r")"
[ -z "$(static_routes)" ] || fail "routes left behind by turning them off: $(static_routes)"
aips=$($SSH "wg show $IFACE allowed-ips" | awk -v k="$WORDS_PEER" '$1 == k { $1 = ""; print }')
for pfx in 10.98.142.0/24 10.98.143.7/32; do
	case " $aips " in *" $pfx "*) ;; *) fail "wg does not hold $pfx: $aips" ;; esac
done
call -X DELETE "$URL/network/wireguard_peers/uapi45list" >/dev/null

# wireguard.sh gives wg the line `AllowedIPs=` through printf %b, so `\054` separates two prefixes
# there, and routes each word of the option as uci holds it, with the address before the first `/`
# and the length after the last. The read gave the word as one entry, so a write of the peer
# answered 422, the restore gave wg the word and failed, and the DELETE withdrew no route.
echo "--- an escape in allowed_ips reads as the prefixes that wg holds, and a write, the restore and the DELETE follow the route of netifd ---"
ESC_IPS=$($SSH 'wg genkey | wg pubkey')
$SSH "uci set network.uapi45escips=wireguard_$IFACE; uci set network.uapi45escips.public_key='$ESC_IPS'
	uci set network.uapi45escips.allowed_ips='10.98.150.0/24\\05410.98.151.0/25'; uci set network.uapi45escips.route_allowed_ips=1
	uci commit network; ifup $IFACE"
sleep 5
escips_held() {
	aips=$($SSH "wg show $IFACE allowed-ips" | awk -v k="$ESC_IPS" '$1 == k { $1 = ""; print }')
	for pfx in 10.98.150.0/24 10.98.151.0/25; do
		case " $aips " in *" $pfx "*) ;; *) fail "$1: wg does not hold $pfx: $aips" ;; esac
	done
	[ "$(static_routes | awk '{ print $1 }')" = "10.98.150.0/25" ] || fail "$1: the routes are $(static_routes)"
}
escips_held "after ifup"
view=$(body_of "$(call "$URL/network/wireguard_peers/uapi45escips")")
[ "$(printf '%s\n' "$view" | jq -c '.allowed_ips')" = '["10.98.150.0/24","10.98.151.0/25"]' ] || fail "the escape read wrong: $view"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/uapi45escips" -d '{"description":"esc"}')
[ "$(status_of "$r")" = "200" ] || fail "PATCH of a peer with an escape in allowed_ips: $(body_of "$r")"
escips_held "after a PATCH"
[ "$($SSH "uci get network.uapi45escips.allowed_ips")" = '10.98.150.0/24\05410.98.151.0/25' ] || fail "the PATCH rewrote allowed_ips"
r=$(bad_write)
[ "$(status_of "$r")" = "500" ] || fail "bad endpoint expected 500 again, got $(status_of "$r"): $(body_of "$r")"
body_of "$r" | grep -q '"code": "reload_failed_restored"' || fail "the restore failed on the escape in allowed_ips: $(body_of "$r")"
escips_held "after the restore"
r=$(call -X DELETE "$URL/network/wireguard_peers/uapi45escips")
[ "$(status_of "$r")" = "204" ] || fail "DELETE of the peer with an escape in allowed_ips: $(body_of "$r")"
has_peer "$ESC_IPS" && fail "the deleted peer with an escape in allowed_ips is still in the kernel"
[ -z "$(static_routes)" ] || fail "routes left behind by the DELETE: $(static_routes)"

# wg cuts the line at `#`, and the route of the word takes the length after its last `/`, which
# netifd reads with strtoul in base 0, so 0x10 is 16.
echo "--- the route of a word follows the length as netifd reads it, through a write, the restore and the DELETE ---"
LEN_PEER=$($SSH 'wg genkey | wg pubkey')
$SSH "uci set network.uapi45len=wireguard_$IFACE; uci set network.uapi45len.public_key='$LEN_PEER'
	uci set network.uapi45len.allowed_ips='10.98.152.0/24#/0x10'; uci set network.uapi45len.route_allowed_ips=1
	uci commit network; ifup $IFACE"
sleep 5
[ "$(static_routes | awk '{ print $1 }')" = "10.98.0.0/16" ] || fail "ifup installed other routes: $(static_routes)"
view=$(body_of "$(call "$URL/network/wireguard_peers/uapi45len")")
[ "$(printf '%s\n' "$view" | jq -c '.allowed_ips')" = '["10.98.152.0/24"]' ] || fail "the allowed IPs read wrong: $view"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/uapi45len" -d '{"description":"len"}')
[ "$(status_of "$r")" = "200" ] || fail "PATCH of the peer: $(body_of "$r")"
[ "$(static_routes | awk '{ print $1 }')" = "10.98.0.0/16" ] || fail "the PATCH changed the routes: $(static_routes)"
r=$(bad_write)
body_of "$r" | grep -q '"code": "reload_failed_restored"' || fail "the restore did not recover: $(body_of "$r")"
[ "$(static_routes | awk '{ print $1 }')" = "10.98.0.0/16" ] || fail "the restore changed the routes: $(static_routes)"
r=$(call -X DELETE "$URL/network/wireguard_peers/uapi45len")
[ "$(status_of "$r")" = "204" ] || fail "DELETE of the peer: $(body_of "$r")"
[ -z "$(static_routes)" ] || fail "routes left behind by the DELETE: $(static_routes)"

# Routes were compared as written, so a PUT that respelled a prefix deleted the route that it had
# just installed, and the restore after a failed write deleted a route that the kernel prints in
# another spelling than uci holds.
echo "--- a respelled prefix keeps its route, through a PUT and through a restore ---"
static6() { $SSH "ip -6 route show dev $IFACE proto static 2>/dev/null" || true; }
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",\"allowed_ips\":[\"fd00:98:cc::/64\"],\"route_allowed_ips\":true}")
[ "$(status_of "$r")" = "200" ] || fail "POST routed v6 peer: $(body_of "$r")"
respelled=$(id_of "$r")
static6 | grep -q '^fd00:98:cc::/64 ' || fail "no route for the v6 prefix: $(static6)"
r=$(call -X PUT -H 'Content-Type: application/json' "$URL/network/wireguard_peers/$respelled" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",\"allowed_ips\":[\"FD00:98:CC:0::/64\"],\"route_allowed_ips\":true}")
[ "$(status_of "$r")" = "200" ] || fail "PUT respelled prefix: $(body_of "$r")"
static6 | grep -q '^fd00:98:cc::/64 ' || fail "the PUT that respelled the prefix withdrew its route: $(static6)"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER4\",
	    \"allowed_ips\":[\"10.98.99.34/32\"],\"endpoint_host\":\"nx.invalid\",\"endpoint_port\":51820}")
[ "$(status_of "$r")" = "500" ] || fail "bad endpoint expected 500 for the restore, got $(status_of "$r"): $(body_of "$r")"
static6 | grep -q '^fd00:98:cc::/64 ' || fail "the restore withdrew the route of the respelled prefix: $(static6)"
has_peer "$PEER3" || fail "the restore dropped the peer of the respelled prefix"
r=$(call -X DELETE "$URL/network/wireguard_peers/$respelled")
[ "$(status_of "$r")" = "204" ] || fail "DELETE respelled peer: $(body_of "$r")"
[ -z "$(static6)" ] || fail "v6 routes left behind: $(static6)"

# wg takes an IPv4 or IPv6 prefix or a bare address of either family. Requiring
# an IPv4 CIDR meant no IPv6 peer could be created through the API at all, so a
# dual-stack tunnel was unconfigurable.
echo "--- a dual-stack peer with bare addresses is accepted and applied ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",
	    \"allowed_ips\":[\"10.98.130.0/24\",\"10.98.131.9\",\"fd00:98:aa::/64\",\"fd00:98:bb::5\"]}")
[ "$(status_of "$r")" = "200" ] || fail "dual-stack peer rejected: $(body_of "$r")"
ds=$(id_of "$r")
kernel_aips=$($SSH "wg show $IFACE allowed-ips | cut -f2")
for want in '10.98.130.0/24' '10.98.131.9/32' 'fd00:98:aa::/64' 'fd00:98:bb::5/128'; do
	echo "$kernel_aips" | grep -q "$want" || fail "allowed-ip $want not in kernel: $kernel_aips"
done
call -X DELETE "$URL/network/wireguard_peers/$ds" >/dev/null

# A write refuses to change a port to 0 or a keepalive to -1, and LuCI's form takes port 0. A
# write that leaves them as uci holds them passes, sets the rest of the peer, and leaves the kernel
# its endpoint and keepalive. Enabling such a peer is refused, because wireguard.sh would then give
# the value to wg.
echo "--- v4 (#308): a stored port of 0 and an unreadable keepalive block every write of the peer ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",\"allowed_ips\":[\"10.98.99.35/32\"],
	    \"endpoint_host\":\"198.51.100.7\",\"endpoint_port\":51820,\"persistent_keepalive\":25}")
[ "$(status_of "$r")" = "200" ] || fail "POST peer for the stored port: $(body_of "$r")"
kept=$(id_of "$r")
$SSH "uci set network.$kept.endpoint_port=0; uci set network.$kept.persistent_keepalive=25x; uci commit network"
for body in '{"description":"x"}' '{"allowed_ips":["10.98.99.36/32"]}' '{"disabled":true}' '{"disabled":false}'; do
	r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/$kept" -d "$body")
	[ "$(status_of "$r")" = "422" ] || fail "PATCH $body of a peer with stored errors expected 422 on v4: $(body_of "$r")"
done
endpoint=$($SSH "wg show $IFACE endpoints" | awk -v k="$PEER3" '$1 == k { print $2 }')
[ "$endpoint" = "198.51.100.7:51820" ] || fail "the kernel endpoint became '$endpoint'"
keepalive=$($SSH "wg show $IFACE persistent-keepalive" | awk -v k="$PEER3" '$1 == k { print $2 }')
[ "$keepalive" = "25" ] || fail "the kernel keepalive became '$keepalive'"
[ "$($SSH "uci get network.$kept.endpoint_port; uci get network.$kept.persistent_keepalive" | tr '\n' ' ')" = "0 25x " ] \
	|| fail "a refused PATCH rewrote the stored port or keepalive"
has_peer "$PEER3" || fail "a refused PATCH removed the peer from the kernel"
call -X DELETE "$URL/network/wireguard_peers/$kept" >/dev/null

# wireguard.sh gives every enabled peer to one `wg syncconf`, so one stored peer that wg refuses
# keeps the whole interface down. A peer write needs its parent on proto wireguard, so the way out
# is a switch that lands disabled, then a fix of the peer, then enabling the interface.
echo "--- a switch to wireguard and enabling refuse a stored peer that wg refuses, which keeps the interface down ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" -d "{\"proto\":\"none\",\"id\":\"$IFACE2\"}")
[ "$(status_of "$r")" = "200" ] || fail "POST $IFACE2: $(body_of "$r")"
KA_PEER=$($SSH 'wg genkey | wg pubkey')
PRIV2=$($SSH 'wg genkey')
$SSH "uci set network.uapi45ka=wireguard_$IFACE2; uci set network.uapi45ka.public_key='$KA_PEER'
	uci add_list network.uapi45ka.allowed_ips=10.98.97.2/32; uci set network.uapi45ka.persistent_keepalive=25x; uci commit network"
TO_WG="{\"proto\":\"wireguard\",\"private_key\":\"$PRIV2\",\"addresses\":[\"10.98.97.1/30\"]"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/interfaces/$IFACE2" -d "$TO_WG}")
[ "$(status_of "$r")" = "422" ] || fail "switch with a peer that wg refuses expected 422, got $(status_of "$r"): $(body_of "$r")"
body_of "$r" | grep -q '"field": "proto"' || fail "the 422 is not on proto: $(body_of "$r")"
body_of "$r" | grep -q 'uapi45ka (persistent_keepalive)' || fail "the 422 does not name the peer: $(body_of "$r")"
body_of "$r" | grep -q '25x' && fail "the 422 quotes the stored value: $(body_of "$r")"
[ "$($SSH "uci get network.$IFACE2.proto")" = "none" ] || fail "the refused switch changed the proto"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/interfaces/$IFACE2" -d "$TO_WG,\"disabled\":true}")
[ "$(status_of "$r")" = "200" ] || fail "switch with disabled true: $(body_of "$r")"
$SSH "uci set network.$IFACE2.disabled=0; uci commit network; /etc/init.d/network reload"
sleep 10
$SSH "ubus call network.interface.$IFACE2 status" | grep -q '"up": true' \
	&& fail "$IFACE2 came up with a peer that wg refuses, so the refusal guards nothing"
$SSH "uci set network.$IFACE2.disabled=1; uci commit network; /etc/init.d/network reload"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/interfaces/$IFACE2" -d '{"disabled":false}')
[ "$(status_of "$r")" = "422" ] || fail "enabling with a peer that wg refuses expected 422, got $(status_of "$r"): $(body_of "$r")"
body_of "$r" | grep -q '"field": "disabled"' || fail "the 422 is not on disabled: $(body_of "$r")"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/uapi45ka" -d '{"persistent_keepalive":25}')
[ "$(status_of "$r")" = "200" ] || fail "fixing the peer once its parent is on wireguard: $(body_of "$r")"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/interfaces/$IFACE2" -d '{"disabled":false}')
[ "$(status_of "$r")" = "200" ] || fail "enabling with the fixed peer: $(body_of "$r")"
n=0
until $SSH "ubus call network.interface.$IFACE2 status" 2>/dev/null | grep -q '"up": true'; do
	n=$((n + 1)); [ $n -lt 20 ] || fail "$IFACE2 did not come up with its fixed peer"; sleep 1
done

# wireguard.sh writes `AllowedIPs=${peer_a_ips// /, }`, so a tab between two prefixes reaches wg as
# one entry, which it refuses. The read gave two entries, and a PUT of it stored a list that wg takes.
echo "--- a tab between two allowed IPs reads as one entry, wg refuses it, a PUT of the read is refused and disabling passes ---"
TAB_PEER=$($SSH 'wg genkey | wg pubkey')
$SSH "uci set network.uapi45tab=wireguard_$IFACE2; uci set network.uapi45tab.public_key='$TAB_PEER'
	uci set network.uapi45tab.allowed_ips=\"\$(printf '10.98.95.2/32\t10.98.95.3/32')\"; uci commit network"
view=$(body_of "$(call "$URL/network/wireguard_peers/uapi45tab")")
[ "$(printf '%s' "$view" | jq -c '.allowed_ips')" = '["10.98.95.2/32\t10.98.95.3/32"]' ] || fail "the allowed IPs read wrong: $view"
r=$(call -X PUT -H 'Content-Type: application/json' "$URL/network/wireguard_peers/uapi45tab" -d "$(printf '%s' "$view" | jq -c 'del(.runtime)')")
[ "$(status_of "$r")" = "422" ] || fail "PUT of the read expected 422, got $(status_of "$r"): $(body_of "$r")"
[ "$($SSH "uci -q get network.uapi45tab.allowed_ips" | tr '\t' '|')" = "10.98.95.2/32|10.98.95.3/32" ] \
	|| fail "the refused PUT changed the stored allowed IPs"
$SSH "ifup $IFACE2"
sleep 10
$SSH "ubus call network.interface.$IFACE2 status" | grep -q '"up": true' \
	&& fail "$IFACE2 came up with the tab, so wg took what the read gives as one entry"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/uapi45tab" -d '{"disabled":true}')
[ "$(status_of "$r")" = "200" ] || fail "disabling the peer expected 200, got $(status_of "$r"): $(body_of "$r")"
$SSH "ifup $IFACE2"
n=0
until $SSH "ubus call network.interface.$IFACE2 status" 2>/dev/null | grep -q '"up": true'; do
	n=$((n + 1)); [ $n -lt 20 ] || fail "$IFACE2 did not come up with the tab peer disabled"; sleep 1
done
call -X DELETE "$URL/network/wireguard_peers/uapi45tab" >/dev/null

# wireguard.sh writes `AllowedIPs=` for a value that is not empty, and wg refuses the line when the cut
# at `#` leaves nothing. The read gave no allowed IPs, so a write that left the peer enabled passed.
echo "--- an allowed_ips that wg reads as an empty line reads as one empty entry, which a write refuses and wg refuses at ifup ---"
HASH_PEER=$($SSH 'wg genkey | wg pubkey')
$SSH "uci set network.uapi45hash=wireguard_$IFACE2; uci set network.uapi45hash.public_key='$HASH_PEER'
	uci set network.uapi45hash.allowed_ips='#c'; uci commit network"
view=$(body_of "$(call "$URL/network/wireguard_peers/uapi45hash")")
[ "$(printf '%s\n' "$view" | jq -c '.allowed_ips')" = '[""]' ] || fail "the empty line read wrong: $view"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/uapi45hash" -d '{"description":"x"}')
[ "$(status_of "$r")" = "422" ] || fail "a write that leaves the peer enabled expected 422, got $(status_of "$r"): $(body_of "$r")"
$SSH "ifup $IFACE2"
sleep 10
$SSH "ubus call network.interface.$IFACE2 status" | grep -q '"up": true' \
	&& fail "$IFACE2 came up with the empty line, so wg took what the read gives as an empty entry"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/uapi45hash" -d '{"disabled":true}')
[ "$(status_of "$r")" = "200" ] || fail "disabling the peer expected 200, got $(status_of "$r"): $(body_of "$r")"
$SSH "ifup $IFACE2"
n=0
until $SSH "ubus call network.interface.$IFACE2 status" 2>/dev/null | grep -q '"up": true'; do
	n=$((n + 1)); [ $n -lt 20 ] || fail "$IFACE2 did not come up with the peer disabled"; sleep 1
done
call -X DELETE "$URL/network/wireguard_peers/uapi45hash" >/dev/null

# wg reads a + or - before any prefix of a list as the marker of an incremental update, and takes
# the whole list as one, so no apply can bring the kernel of such a peer to what uci holds. A write
# refuses the entry, because it is not a CIDR, so only another writer stores one. The restore
# merged the stored list into the kernel and answered reload_failed_restored, and a DELETE of a key
# that such a peer also stores set it again as a merge and answered 200.
echo "--- the apply and the restore refuse a peer whose stored allowed_ips holds a + or - entry ---"
MARK=$($SSH 'wg genkey | wg pubkey')
$SSH "uci set network.uapi45mark=wireguard_$IFACE2; uci set network.uapi45mark.public_key='$MARK'
	uci set network.uapi45mark.allowed_ips='+10.98.94.2/32'; uci set network.uapi45mark.disabled=1; uci commit network"
view=$(body_of "$(call "$URL/network/wireguard_peers/uapi45mark")")
[ "$(printf '%s' "$view" | jq -c '.allowed_ips')" = '["+10.98.94.2/32"]' ] || fail "the marker entry read wrong: $view"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/uapi45mark" -d '{"description":"x"}')
[ "$(status_of "$r")" = "200" ] || fail "a write that leaves the peer disabled expected 200, got $(status_of "$r"): $(body_of "$r")"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/uapi45mark" -d '{"disabled":false}')
[ "$(status_of "$r")" = "422" ] || fail "a write that enables the peer expected 422, got $(status_of "$r"): $(body_of "$r")"
body_of "$r" | grep -qF '"field": "allowed_ips[0]"' || fail "the 422 is not on allowed_ips[0]: $(body_of "$r")"
[ "$($SSH "uci -q get network.uapi45mark.allowed_ips")" = "+10.98.94.2/32" ] \
	|| fail "the refused write changed the stored entry"
# The kernel holds an extra IP for the peer that no entry names, as a failed apply leaves it: the
# restore would add the marker entry to it and answer restored.
$SSH "uci set network.uapi45mark.disabled=0; uci commit network
	wg set $IFACE2 peer '$MARK' allowed-ips 10.98.94.2/32,10.98.94.99/32"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE2\",\"public_key\":\"$PEER3\",\"allowed_ips\":[\"10.98.94.30/32\"],
	    \"endpoint_host\":\"nx.invalid\",\"endpoint_port\":51820}")
[ "$(status_of "$r")" = "500" ] || fail "the write with the bad endpoint expected 500, got $(status_of "$r"): $(body_of "$r")"
body_of "$r" | grep -q '"code": "reload_failed_unrecovered"' || fail "the restore claimed to recover: $(body_of "$r")"
body_of "$r" | grep -q 'marked + or -' || fail "the error names no marker entry: $(body_of "$r")"
ips=$($SSH "wg show $IFACE2 allowed-ips" | grep -F "$MARK" | cut -f2)
[ "$ips" = "10.98.94.2/32 10.98.94.99/32" ] || fail "the refused restore changed the kernel of the peer: '$ips'"
$SSH "uci delete network.uapi45mark; uci commit network; wg set $IFACE2 peer '$MARK' remove"

# The read of proto static hides listen_port, and a PATCH keeps what it leaves out, so the switch
# gave wireguard.sh a hand-written port name that wg cannot resolve, and answered 200. Either way out
# that the message gives works: a null in the switch removes the option, and so does a JSON Patch
# that removes it after a switch with disabled true.
echo "--- a switch to wireguard refuses a hand-written listen_port that does not resolve, which keeps the interface down ---"
up3() { $SSH "ubus call network.interface.$IFACE3 status" 2>/dev/null | grep -q '"up": true'; }
wait_up3() {
	n=0
	until up3; do n=$((n + 1)); [ $n -lt 20 ] || fail "$IFACE3 did not come up $1"; sleep 1; done
}
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d "{\"proto\":\"static\",\"id\":\"$IFACE3\",\"ipaddrs\":[\"10.98.96.1/30\"]}")
[ "$(status_of "$r")" = "200" ] || fail "POST $IFACE3: $(body_of "$r")"
$SSH "uci set network.$IFACE3.listen_port=nosuchservice; uci commit network"
PRIV3=$($SSH 'wg genkey')
TO_WG3="{\"proto\":\"wireguard\",\"private_key\":\"$PRIV3\",\"addresses\":[\"10.98.96.1/30\"]"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/interfaces/$IFACE3" -d "$TO_WG3}")
[ "$(status_of "$r")" = "422" ] || fail "switch with a listen_port that does not resolve expected 422, got $(status_of "$r"): $(body_of "$r")"
body_of "$r" | grep -q '"field": "listen_port"' || fail "the 422 is not on listen_port: $(body_of "$r")"
body_of "$r" | grep -q '"code": "conflict"' || fail "the 422 is not a conflict: $(body_of "$r")"
body_of "$r" | grep -q 'nosuchservice' && fail "the 422 quotes the stored value: $(body_of "$r")"
[ "$($SSH "uci get network.$IFACE3.proto")" = "static" ] || fail "the refused switch changed the proto"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/interfaces/$IFACE3" -d "$TO_WG3,\"disabled\":true}")
[ "$(status_of "$r")" = "200" ] || fail "switch with disabled true: $(body_of "$r")"
$SSH "uci set network.$IFACE3.disabled=0; uci commit network; /etc/init.d/network reload"
sleep 10
up3 && fail "$IFACE3 came up with a listen_port that wg cannot resolve, so the refusal guards nothing"
$SSH "uci set network.$IFACE3.disabled=1; uci commit network; /etc/init.d/network reload"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/interfaces/$IFACE3" -d '{"disabled":false}')
[ "$(status_of "$r")" = "422" ] || fail "enabling with the stored listen_port expected 422, got $(status_of "$r"): $(body_of "$r")"
r=$(call -X PATCH -H 'Content-Type: application/json-patch+json' "$URL/network/interfaces/$IFACE3" \
	-d '[{"op":"replace","path":"/disabled","value":false},{"op":"remove","path":"/listen_port"}]')
[ "$(status_of "$r")" = "200" ] || fail "enabling with a JSON Patch that removes /listen_port: $(body_of "$r")"
$SSH "uci -q get network.$IFACE3.listen_port" && fail "the JSON Patch remove of /listen_port kept the option"
wait_up3 "once the JSON Patch removed listen_port"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/interfaces/$IFACE3" -d '{"proto":"static","ipaddrs":["10.98.96.1/30"]}')
[ "$(status_of "$r")" = "200" ] || fail "switch $IFACE3 back to static: $(body_of "$r")"
$SSH "uci set network.$IFACE3.listen_port=nosuchservice; uci commit network"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/interfaces/$IFACE3" -d "$TO_WG3,\"listen_port\":null}")
[ "$(status_of "$r")" = "200" ] || fail "switch with listen_port null: $(body_of "$r")"
$SSH "uci -q get network.$IFACE3.listen_port" && fail "listen_port null in the switch kept the option"
wait_up3 "after the switch with listen_port null"

echo "--- a peer written to a down tunnel is accepted, and applies on ifup ---"
$SSH "ifdown $IFACE"; sleep 2
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER4\",
	    \"allowed_ips\":[\"10.98.99.6/32\"]}")
[ "$(status_of "$r")" = "200" ] || fail "POST to down tunnel expected 200: $(body_of "$r")"
[ "$(read_peer "$(id_of "$r")" .runtime)" = '{}' ] || fail "the read of a peer on a down tunnel reports $(read_peer "$(id_of "$r")" .runtime)"

# Nothing cascades a peer delete off an interface delete, so leftover peers are a
# normal state to clean up, and a Terraform destroy can order the interface first.
# The renew step must treat an interface netifd no longer knows as nothing to do:
# reporting it turned this DELETE into a 500 claiming an unknown config state and
# left the section in place, with no way to remove it through the API.
echo "--- a peer orphaned by deleting its interface can still be deleted ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER2\",\"allowed_ips\":[\"10.98.99.7/32\"]}")
[ "$(status_of "$r")" = "200" ] || fail "POST peer to orphan: $(body_of "$r")"
orphan=$(id_of "$r")
r=$(call -X DELETE "$URL/network/interfaces/$IFACE")
[ "$(status_of "$r")" = "204" ] || fail "DELETE interface: $(body_of "$r")"
$SSH "ubus call network.interface.$IFACE status" >/dev/null 2>&1 \
	&& fail "netifd still knows $IFACE; the orphan case is not being exercised"
r=$(call -X DELETE "$URL/network/wireguard_peers/$orphan")
[ "$(status_of "$r")" = "204" ] || fail "DELETE orphaned peer expected 204, got $(status_of "$r"): $(body_of "$r")"

echo "OK: 45_wireguard_peer_apply"
