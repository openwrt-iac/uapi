#!/bin/sh
set -eu

SSH="tests/vm/ssh.sh"
. tests/integration/lib/install_uapi.sh

FIX_URL="https://raw.githubusercontent.com/raspbeguy/openwrt/wireguard-contain-refused-peer-value/package/network/utils/wireguard-tools/files/wireguard.uc"

fail() { echo "FAIL: $*"; exit 1; }

echo "--- install the patched handler ---"
curl -fsSL "$FIX_URL" -o /tmp/wireguard.uc.patched
$SSH "cat > /usr/lib/netifd/proto/wireguard.uc" < /tmp/wireguard.uc.patched
$SSH '/etc/init.d/network restart' >/dev/null 2>&1 || true
n=0
while [ $n -lt 30 ]; do
	$SSH 'true' >/dev/null 2>&1 && break
	n=$((n + 1)); sleep 2
done
$SSH 'true' >/dev/null 2>&1 || fail "the network restart did not come back"

ensure_wireguard || fail "could not install wireguard"

echo "--- the #24511 scenario: one good peer, one unresolvable endpoint ---"
PRIV=$($SSH 'wg genkey')
GOOD=$($SSH "echo '$PRIV' | wg pubkey")
BAD=$($SSH 'wg genkey | wg pubkey')
$SSH "uci set network.wgfix=interface; uci set network.wgfix.proto='wireguard'
	uci set network.wgfix.private_key='$PRIV'
	uci add_list network.wgfix.addresses='10.99.99.1/24'
	uci set network.wgfixp1=wireguard_wgfix; uci set network.wgfixp1.public_key='$GOOD'
	uci add_list network.wgfixp1.allowed_ips='10.99.99.2/32'
	uci set network.wgfixp2=wireguard_wgfix; uci set network.wgfixp2.public_key='$BAD'
	uci add_list network.wgfixp2.allowed_ips='10.99.99.3/32'
	uci set network.wgfixp2.endpoint_host='nx.invalid'; uci set network.wgfixp2.endpoint_port='51820'
	uci commit network; ifup wgfix" >/dev/null

n=0
while [ $n -lt 20 ]; do
	$SSH "ubus call network.interface.wgfix status 2>/dev/null" | grep -q '"up": *true' && break
	n=$((n + 1)); sleep 1
done
$SSH "ubus call network.interface.wgfix status" | grep -q '"up": *true' \
	|| { $SSH 'ubus call network.interface.wgfix status; logread | grep -i wireguard | tail -10'; \
	     fail "the interface stayed down for one unresolvable peer"; }
$SSH "wg show wgfix peers" | grep -q "$GOOD" || fail "the good peer did not land"
$SSH "wg show wgfix endpoints" | grep "$BAD" | grep -q '(none)' \
	|| { $SSH "wg show wgfix endpoints"; fail "the bad peer is missing or holds an endpoint"; }
$SSH "logread | grep -q 'nx.invalid'" || fail "the refusal is not logged"

echo "--- a keepalive wg refuses costs its line, not the interface ---"
$SSH "uci set network.wgfixp2.endpoint_host='198.51.100.7'
	uci set network.wgfixp2.persistent_keepalive='0;touch /tmp/wgfix_ran'
	uci commit network; ifup wgfix" >/dev/null
n=0
while [ $n -lt 20 ]; do
	$SSH "ubus call network.interface.wgfix status 2>/dev/null" | grep -q '"up": *true' \
		&& $SSH "wg show wgfix peers" | grep -q "$BAD" && break
	n=$((n + 1)); sleep 1
done
$SSH "ubus call network.interface.wgfix status" | grep -q '"up": *true' \
	|| fail "the interface went down for a refused keepalive"
$SSH "wg show wgfix peers" | grep -q "$BAD" || fail "the peer with a refused keepalive vanished"
$SSH '[ ! -e /tmp/wgfix_ran ]' || fail "the stored keepalive ran as a shell command"
$SSH "wg show wgfix persistent-keepalive" | grep "$BAD" | grep -q ' off' \
	|| fail "the refused keepalive reached the kernel"
$SSH "logread | grep -q 'PersistentKeepalive'" || fail "the keepalive refusal is not logged"

echo "--- a malformed preshared key costs its line ---"
PSK=$($SSH 'wg genpsk')
$SSH "uci set network.wgfixp2.persistent_keepalive='25'
	uci set network.wgfixp2.preshared_key='not-a-key'
	uci commit network; ifup wgfix" >/dev/null
n=0
while [ $n -lt 20 ]; do
	$SSH "ubus call network.interface.wgfix status 2>/dev/null" | grep -q '"up": *true' \
		&& $SSH "wg show wgfix preshared-keys 2>/dev/null" | grep -q "$BAD" && break
	n=$((n + 1)); sleep 1
done
$SSH "ubus call network.interface.wgfix status" | grep -q '"up": *true' \
	|| fail "the interface went down for a malformed preshared key"
$SSH "wg show wgfix preshared-keys" | grep "$BAD" | grep -q '(none)' \
	|| fail "the malformed preshared key reached the kernel"
$SSH "logread | grep -q 'PresharedKey'" || fail "the preshared key refusal is not logged"

echo "--- a good psk applies again after the refused one ---"
$SSH "uci set network.wgfixp2.preshared_key='$PSK'
	uci commit network; ifup wgfix" >/dev/null
n=0
while [ $n -lt 20 ]; do
	$SSH "wg show wgfix preshared-keys 2>/dev/null" | grep "$BAD" | grep -q "$PSK" && break
	n=$((n + 1)); sleep 1
done
$SSH "wg show wgfix preshared-keys" | grep "$BAD" | grep -q "$PSK" \
	|| fail "the good preshared key did not apply"

echo "patched handler ok"
