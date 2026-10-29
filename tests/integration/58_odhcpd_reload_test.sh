#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

# odhcpd reloads on its procd trigger, which a commit through libuci does not fire. When odhcpd
# reads /etc/config/dhcp, it logs each `config dhcp` section whose ndp mode it cannot parse. uapi
# does not model ndp, so a PATCH of ra keeps such a value, and a line for the section after the
# PATCH shows that odhcpd read the file again. The section sits on tdhcp6, a static interface on
# an empty bridge, so that lan and wan stay as they are.
LOGLEVEL=$($SSH 'uci -q get dhcp.odhcpd.loglevel' || true)
cleanup() {
	$SSH "uci -q delete dhcp.tdhcp6
	      if [ -n '$LOGLEVEL' ]; then uci set dhcp.odhcpd.loglevel='$LOGLEVEL'; else uci -q delete dhcp.odhcpd.loglevel; fi
	      uci commit dhcp
	      uci -q delete network.tdhcp6; uci -q delete network.br_tdhcp6; uci commit network
	      ubus call network reload; /etc/init.d/dnsmasq reload; /etc/init.d/odhcpd reload" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

$SSH "test -x /etc/init.d/odhcpd && ubus call service list '{\"name\":\"odhcpd\"}' | grep -q '\"running\": true'" \
	|| fail "odhcpd does not run on the test box, so this case proves nothing"
$SSH 'uci -q get dhcp.odhcpd >/dev/null' || fail "the test box has no config odhcpd section"
cleanup

echo "--- a static interface tdhcp6 on the empty bridge br-tdhcp6, and odhcpd at loglevel 7 ---"
$SSH 'uci set network.br_tdhcp6=device
      uci set network.br_tdhcp6.type=bridge
      uci set network.br_tdhcp6.name=br-tdhcp6
      uci set network.br_tdhcp6.bridge_empty=1
      uci set network.tdhcp6=interface
      uci set network.tdhcp6.proto=static
      uci set network.tdhcp6.device=br-tdhcp6
      uci set network.tdhcp6.ipaddr=10.98.0.1
      uci set network.tdhcp6.netmask=255.255.255.0
      uci commit network
      ubus call network reload
      uci set dhcp.odhcpd.loglevel=7
      uci commit dhcp
      /etc/init.d/odhcpd reload'
n=0
until $SSH 'ubus call network.interface.tdhcp6 status' 2>/dev/null | grep -q '"up": true'; do
	n=$((n + 1))
	[ $n -lt 15 ] || fail "tdhcp6 did not come up"
	sleep 1
done

r=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/servers" \
	-d '{"id":"tdhcp6","interface":"tdhcp6","ra":"disabled"}')
[ "$(echo "$r" | tail -1)" = "200" ] || fail "POST expected 200: $r"

echo "--- an ndp mode that odhcpd refuses, committed from the shell, which reloads nothing ---"
MARK="uapi-odhcpd-reload-$$-$(date +%s)"
$SSH "logger -t uapi_test $MARK"
odhcpd_lines() {
	$SSH "logread | sed -n '/$MARK/,\$p' | grep odhcpd | grep -F tdhcp6" || true
}
$SSH 'uci set dhcp.tdhcp6.ndp=uapi-no-such-mode; uci commit dhcp'
sleep 2
[ -z "$(odhcpd_lines)" ] \
	|| fail "odhcpd read the section without the write, so a line after it proves nothing: $(odhcpd_lines)"

echo "--- a PATCH that changes only ra makes odhcpd read the section again ---"
hdrs=$(mktemp)
r=$(curl -sS -D "$hdrs" -H "$ADMIN" -w "\n%{http_code}" -X PATCH -H 'Content-Type: application/json' \
	"$URL/dhcp/servers/tdhcp6" -d '{"ra":"server"}')
services=$(grep -i '^X-Reload-Services:' "$hdrs" | tr -d '\r' || true)
rm -f "$hdrs"
[ "$(echo "$r" | tail -1)" = "200" ] || fail "PATCH of ra expected 200: $r"
n=0
until [ -n "$(odhcpd_lines)" ]; do
	n=$((n + 1))
	[ $n -lt 5 ] || fail "odhcpd logged nothing for tdhcp6 after the write, so it did not read /etc/config/dhcp again ($services). Its last lines:
$($SSH "logread | grep odhcpd | tail -15" || true)"
	sleep 1
done
echo "odhcpd after the write: $(odhcpd_lines | head -3)"
[ "$services" = "X-Reload-Services: dnsmasq,odhcpd" ] || fail "expected the write to name dnsmasq and odhcpd: $services"
[ "$($SSH 'uci -q get dhcp.tdhcp6.ra')" = "server" ] || fail "uci does not hold ra=server"
[ "$($SSH 'uci -q get dhcp.tdhcp6.ndp')" = "uapi-no-such-mode" ] || fail "the PATCH of ra changed ndp"

echo "a dhcp/servers write reloads odhcpd ok."
