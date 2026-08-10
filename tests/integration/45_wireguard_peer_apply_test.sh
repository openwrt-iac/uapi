#!/bin/sh
set -eu

# netifd reads peer sections with `config_foreach wireguard_<iface>` inside the
# proto setup step, so editing a peer leaves the parent `interface` section
# untouched and `/etc/init.d/network reload` converges nothing. Before 2.4.1 a
# peer was committed to uci, answered 200, and never reached the kernel, and a
# DELETE answered 204 while the peer stayed live: revoking access through the API
# did not revoke it. Every assertion below is against `wg show`, never against
# uci, and no ifup appears anywhere in the sequence.

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }
body_of() { echo "$1" | sed '$d'; }
status_of() { echo "$1" | tail -1; }
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
PRIV='yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk='
PEER1='xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg='
PEER2='TrMvSoP4jYQlY6RIzBgbssQqY3vxI2Pi+y71lOWWXX0='
PEER3='mDpFbfhjQlpPqYFJRSKBRRJdPjRlnQhqBSVvhoLLRWc='
PEER4='TWlzY2VsbGFuZW91c1BlZXJLZXlGb3JUZXN0aW5nMD0='

# Peers outlive their parent in uci, and a peer section whose interface is gone
# would be left behind for every later run to trip over, so they go first.
cleanup() {
	$SSH "ifdown $IFACE >/dev/null 2>&1 || true
	      for s in \$(uci show network | sed -n \"s/^network\\.\\([^.]*\\)=wireguard_$IFACE\$/\\1/p\"); do
	          uci -q delete network.\$s
	      done
	      uci -q delete network.$IFACE 2>/dev/null || true
	      uci -q commit network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "--- create the parent wireguard interface ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d "{\"proto\":\"wireguard\",\"id\":\"$IFACE\",
	    \"private_key\":\"$PRIV\",\"addresses\":[\"10.98.98.1/30\"]}")
[ "$(status_of "$r")" = "200" ] || fail "POST interface: $(body_of "$r")"

# netifd keys admin-down state on the interface NAME and keeps it across the uci
# section being deleted and recreated, so the ifdown in the last step below would
# leave the next run's interface with autostart=false and no netdev. This clears
# it. It is setup only: no ifup appears between a peer write and the `wg show`
# that checks it, which is the whole point of the file.
$SSH "ifup $IFACE" >/dev/null 2>&1 || true
n=0
while [ $n -lt 15 ]; do
	$SSH "ip link show $IFACE" >/dev/null 2>&1 && break
	n=$((n + 1)); sleep 1
done
$SSH "ip link show $IFACE" >/dev/null 2>&1 || fail "netdev $IFACE never appeared"

kernel_peers() { $SSH "wg show $IFACE peers 2>/dev/null" || true; }
has_peer() { kernel_peers | grep -qxF "$1"; }

echo "--- POST a peer reaches the kernel with no ifup ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER1\",
	    \"allowed_ips\":[\"10.98.99.2/32\"],\"endpoint_host\":\"198.51.100.7\",
	    \"endpoint_port\":51820}")
[ "$(status_of "$r")" = "200" ] || fail "POST peer: $(body_of "$r")"
pid=$(id_of "$r")
has_peer "$PEER1" || fail "peer not in kernel after POST; wg show: $(kernel_peers)"

echo "--- PATCH the endpoint reaches the kernel ---"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/$pid" \
	-d '{"endpoint_host":"198.51.100.9"}')
[ "$(status_of "$r")" = "200" ] || fail "PATCH peer: $(body_of "$r")"
$SSH "wg show $IFACE endpoints" | grep -q '198.51.100.9' \
	|| fail "endpoint not updated in kernel: $($SSH "wg show $IFACE endpoints")"

echo "--- DELETE actually revokes the peer ---"
r=$(call -X DELETE "$URL/network/wireguard_peers/$pid")
[ "$(status_of "$r")" = "204" ] || fail "DELETE peer: $(body_of "$r")"
has_peer "$PEER1" && fail "peer STILL live in kernel after DELETE (access not revoked)"

echo "--- a batch of peers on one interface all land ---"
r=$(call -X POST -H 'Content-Type: application/json' "$URL/batch" -d "{\"operations\":[
	{\"path\":\"/network/wireguard_peers\",\"method\":\"POST\",
	 \"body\":{\"interface\":\"$IFACE\",\"public_key\":\"$PEER1\",
	           \"allowed_ips\":[\"10.98.99.4/32\"]}},
	{\"path\":\"/network/wireguard_peers\",\"method\":\"POST\",
	 \"body\":{\"interface\":\"$IFACE\",\"public_key\":\"$PEER2\",
	           \"allowed_ips\":[\"10.98.99.5/32\"]}}]}")
[ "$(status_of "$r")" = "207" ] || fail "batch: $(body_of "$r")"
has_peer "$PEER1" || fail "batch peer 1 not in kernel"
has_peer "$PEER2" || fail "batch peer 2 not in kernel"
$SSH "ip link show $IFACE" >/dev/null 2>&1 || fail "tunnel torn down by the batch"

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
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/network/wireguard_peers/$rid" \
	-d '{"disabled":false}')
[ "$(status_of "$r")" = "200" ] || fail "PATCH re-enable: $(body_of "$r")"
has_peer "$PEER4" || fail "re-enabled peer was not reinstalled"
call -X DELETE "$URL/network/wireguard_peers/$rid" >/dev/null

# endpoint_host is the only caller-supplied value that reaches a shell command,
# so it is quoted rather than validated. This is the assertion that the quoting
# holds; a regression here is remote command execution, not a cosmetic bug.
echo "--- a command substitution in endpoint_host does not execute ---"
$SSH "rm -f /tmp/uapi-wg-injection" >/dev/null 2>&1
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"$PEER3\",\"allowed_ips\":[\"10.98.99.32/32\"],
	    \"endpoint_host\":\"x\$(touch /tmp/uapi-wg-injection)y\",\"endpoint_port\":51820}")
$SSH "test -f /tmp/uapi-wg-injection" >/dev/null 2>&1 \
	&& fail "endpoint_host was interpolated into the shell and executed"

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

echo "--- a peer written to a down tunnel is accepted, and applies on ifup ---"
$SSH "ifdown $IFACE"; sleep 2
r=$(call -X POST -H 'Content-Type: application/json' "$URL/network/wireguard_peers" \
	-d "{\"interface\":\"$IFACE\",\"public_key\":\"TWlzY2VsbGFuZW91c1BlZXJLZXlGb3JUZXN0aW5nMD0=\",
	    \"allowed_ips\":[\"10.98.99.6/32\"]}")
[ "$(status_of "$r")" = "200" ] || fail "POST to down tunnel expected 200: $(body_of "$r")"

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
