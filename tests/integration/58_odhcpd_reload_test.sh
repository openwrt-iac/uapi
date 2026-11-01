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
# does not model ndp, so a write of ra keeps such a value, and the ndp line for the section after
# the write shows that odhcpd read the file again. The section sits on tdhcp6, a static interface
# on an empty bridge, so that lan and wan stay as they are.
# The loglevel that the case raises goes back from a file on the box, so that a run killed before
# its trap does not hand loglevel 7 to the next run as the value to restore.
SAVED=/tmp/uapi_odhcpd_loglevel
cleanup() {
	$SSH "uci -q delete dhcp.tdhcp6
	      case \"\$(uci -q get system.@system[0].notes)\" in uapi-t58*) uci delete system.@system[0].notes; uci commit system;; esac
	      if [ -f $SAVED ]; then
	          v=\$(cat $SAVED)
	          if [ -n \"\$v\" ]; then uci set dhcp.odhcpd.loglevel=\"\$v\"; else uci -q delete dhcp.odhcpd.loglevel; fi
	          rm -f $SAVED
	      fi
	      uci commit dhcp
	      uci -q delete network.tdhcp6; uci -q delete network.br_tdhcp6; uci commit network
	      ubus call network reload; /etc/init.d/dnsmasq start; /etc/init.d/odhcpd reload" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

$SSH "test -x /etc/init.d/odhcpd && ubus call service list '{\"name\":\"odhcpd\"}' | grep -q '\"running\": true'" \
	|| fail "odhcpd does not run on the test box, so this case proves nothing"
$SSH 'uci -q get dhcp.odhcpd >/dev/null' || fail "the test box has no config odhcpd section"
cleanup
# A dhcp or system write reloads unbound too while procd runs it, which a box with the openwrt-iac
# feed may have from test 40.
UNB="" UNBJ=""
if $SSH "ubus call service list '{\"name\":\"unbound\"}'" | grep -q '"unbound"'; then UNB=",unbound" UNBJ=',"unbound"'; fi

# A reload makes odhcpd log for a while, and a line of the last reload after a new mark would be
# read as one of the next write.
settle() {
	before="" tries=0
	after=$($SSH 'logread | grep odhcpd | tail -1' || true)
	while [ "$before" != "$after" ]; do
		tries=$((tries + 1))
		[ $tries -lt 10 ] || fail "odhcpd kept logging for 10 s, so its lines after a mark cannot be told apart"
		before=$after
		sleep 1
		after=$($SSH 'logread | grep odhcpd | tail -1' || true)
	done
}
mark() {
	settle
	MARK="uapi-t58-$$-$1"
	$SSH "logger -t uapi_test $MARK"
}
ndp_lines() {
	$SSH "logread | sed -n '/$MARK/,\$p' | grep odhcpd | grep -F tdhcp6 | grep -F ndp" || true
}
await_ndp() {
	tries=0
	until [ -n "$(ndp_lines)" ]; do
		tries=$((tries + 1))
		[ $tries -lt 5 ] || fail "odhcpd logged no ndp line for tdhcp6 after $1, so it did not read /etc/config/dhcp again ($2). Its last lines:
$($SSH "logread | grep odhcpd | tail -15" || true)"
		sleep 1
	done
	echo "odhcpd after $1: $(ndp_lines | head -1)"
}

echo "--- a static interface tdhcp6 on the empty bridge br-tdhcp6, and odhcpd at loglevel 7 ---"
$SSH "uci set network.br_tdhcp6=device
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
      uci -q get dhcp.odhcpd.loglevel > $SAVED
      uci set dhcp.odhcpd.loglevel=7
      uci commit dhcp
      /etc/init.d/odhcpd reload"
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
mark shell
$SSH 'uci set dhcp.tdhcp6.ndp=uapi-no-such-mode; uci commit dhcp'
sleep 2
[ -z "$(ndp_lines)" ] \
	|| fail "odhcpd read the section without the write, so a line after it proves nothing: $(ndp_lines)"

echo "--- a PATCH that changes only ra makes odhcpd read the section again ---"
hdrs=$(mktemp)
r=$(curl -sS -D "$hdrs" -H "$ADMIN" -w "\n%{http_code}" -X PATCH -H 'Content-Type: application/json' \
	"$URL/dhcp/servers/tdhcp6" -d '{"ra":"server"}')
services=$(grep -i '^X-Reload-Services:' "$hdrs" | tr -d '\r' || true)
rm -f "$hdrs"
[ "$(echo "$r" | tail -1)" = "200" ] || fail "PATCH of ra expected 200: $r"
await_ndp "the PATCH" "$services"
[ "$services" = "X-Reload-Services: dnsmasq,odhcpd$UNB" ] || fail "expected the PATCH to name dnsmasq and odhcpd: $services"
[ "$($SSH 'uci -q get dhcp.tdhcp6.ra')" = "server" ] || fail "uci does not hold ra=server"

echo "--- a raw PATCH of ra reloads odhcpd, and its body names it ---"
mark raw
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/raw/dhcp/tdhcp6" -d '{"ra":"disabled"}')
body=$(echo "$r" | sed '$d')
[ "$(echo "$r" | tail -1)" = "200" ] || fail "raw PATCH of ra expected 200: $r"
await_ndp "the raw PATCH" "$(echo "$body" | jq -c '.reload_services')"
[ "$(echo "$body" | jq -c '.reload_services')" = "[\"dnsmasq\",\"odhcpd\"$UNBJ]" ] \
	|| fail "expected the raw PATCH to name dnsmasq and odhcpd: $body"
[ "$($SSH 'uci -q get dhcp.tdhcp6.ra')" = "disabled" ] || fail "uci does not hold ra=disabled"

echo "--- a /batch PATCH of ra reloads odhcpd, and its 207 names it ---"
mark batch
hdrs=$(mktemp)
status=$(curl -sS -o /dev/null -D "$hdrs" -w '%{http_code}' -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/batch" -d '{"operations":[{"path":"/dhcp/servers/tdhcp6","method":"PATCH","body":{"ra":"server"}}]}')
services=$(grep -i '^X-Reload-Services:' "$hdrs" | tr -d '\r' || true)
rm -f "$hdrs"
[ "$status" = "207" ] || fail "batch expected 207, got $status"
await_ndp "the batch" "$services"
[ "$services" = "X-Reload-Services: dnsmasq,odhcpd$UNB" ] || fail "expected the batch to name dnsmasq and odhcpd: $services"
[ "$($SSH 'uci -q get dhcp.tdhcp6.ra')" = "server" ] || fail "uci does not hold ra=server"
[ "$($SSH 'uci -q get dhcp.tdhcp6.ndp')" = "uapi-no-such-mode" ] || fail "a write of ra changed ndp"

# odhcpd reads the timezone of the system section, and its procd trigger on system does not fire
# for a commit through libuci either.
patch_system() {
	hdrs=$(mktemp)
	r=$(curl -sS -D "$hdrs" -H "$ADMIN" -w "\n%{http_code}" -X PATCH -H 'Content-Type: application/json' \
		"$URL/system" -d "{\"notes\":\"$1\"}")
	services=$(grep -i '^X-Reload-Services:' "$hdrs" | tr -d '\r' || true)
	rm -f "$hdrs"
	[ "$(echo "$r" | tail -1)" = "200" ] || fail "PATCH of system expected 200: $r"
}
dnsmasq_listed() {
	$SSH "ubus call service list '{\"name\":\"dnsmasq\"}'" | grep -q '"dnsmasq"'
}

echo "--- a PATCH of system reloads dnsmasq and odhcpd ---"
mark system
patch_system uapi-t58
await_ndp "the system PATCH" "$services"
[ "$services" = "X-Reload-Services: system,log,dnsmasq,odhcpd$UNB" ] || fail "expected the system PATCH to name dnsmasq and odhcpd: $services"

echo "--- with dnsmasq stopped, a dhcp or system write reloads odhcpd and leaves dnsmasq stopped ---"
$SSH '/etc/init.d/dnsmasq stop'
dnsmasq_listed && fail "procd still lists dnsmasq after its stop, so the case below proves nothing"
mark stopped
hdrs=$(mktemp)
r=$(curl -sS -D "$hdrs" -H "$ADMIN" -w "\n%{http_code}" -X PATCH -H 'Content-Type: application/json' \
	"$URL/dhcp/servers/tdhcp6" -d '{"ra":"disabled"}')
services=$(grep -i '^X-Reload-Services:' "$hdrs" | tr -d '\r' || true)
rm -f "$hdrs"
[ "$(echo "$r" | tail -1)" = "200" ] || fail "PATCH of ra with dnsmasq stopped expected 200: $r"
await_ndp "the PATCH with dnsmasq stopped" "$services"
[ "$services" = "X-Reload-Services: odhcpd$UNB" ] || fail "expected the PATCH to name odhcpd alone: $services"
dnsmasq_listed && fail "the dhcp write started the dnsmasq that was stopped"
patch_system uapi-t58-2
[ "$services" = "X-Reload-Services: system,log,odhcpd$UNB" ] || fail "expected the system PATCH to leave out dnsmasq: $services"
dnsmasq_listed && fail "the system write started the dnsmasq that was stopped"
$SSH '/etc/init.d/dnsmasq start'

echo "dhcp/servers, raw dhcp, /batch and system writes reload odhcpd, and leave a stopped dnsmasq stopped, ok."
