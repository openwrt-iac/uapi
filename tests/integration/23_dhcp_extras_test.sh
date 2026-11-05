#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- dhcp/servers: POST against an interface that exists ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/servers" -d '{
	"interface": "lan", "start": 100, "limit": 150, "leasetime": "12h"
}')
echo "$created"
status=$(echo "$created" | tail -1)
[ "$status" = "200" ] || fail "servers POST expected 200, got $status"
sid=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')

echo "--- dhcp/servers: PATCH leasetime ---"
call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/servers/$sid" -d '{"leasetime":"24h"}' | tail -1 | grep -q '^200$' \
	|| fail "PATCH servers expected 200"
# No assert_dnsmasq_emits for the range itself: the CI image runs lan as a dhcp
# client with no ipaddr, so dnsmasq has no subnet to build a dhcp-range from and
# emits nothing for this section however correct the write is. The equivalent
# assertion lives in the dhcp/hosts test, where the compiled line does not
# depend on the interface having an address.
assert_dnsmasq_loads

echo "--- dhcp/servers: a dhcp_option option reads as the words that dnsmasq.init splits it into ---"
$SSH "uci set dhcp.$sid.dhcp_option='3,192.0.2.1 6,192.0.2.1'; uci commit dhcp"
view=$(call "$URL/dhcp/servers/$sid" | sed '$d')
[ "$(printf '%s' "$view" | jq -c '.dhcp_option')" = '["3,192.0.2.1","6,192.0.2.1"]' ] \
	|| fail "the dhcp_option option read wrong: $view"
r=$(call -X PUT -H 'Content-Type: application/json' "$URL/dhcp/servers/$sid" -d "$(printf '%s' "$view" | jq -c 'del(.runtime)')")
echo "$r" | tail -1 | grep -q '^200$' || fail "PUT of the read expected 200: $r"
stored=$($SSH "uci -q show dhcp.$sid.dhcp_option" || true)
[ "$stored" = "dhcp.$sid.dhcp_option='3,192.0.2.1' '6,192.0.2.1'" ] || fail "PUT of the read stored $stored"
assert_dnsmasq_loads

echo "--- dhcp/servers: a PUT of the read keeps the options that odhcpd.defaults writes into lan ---"
$SSH "uci set dhcp.$sid.dhcpv4=server; uci set dhcp.$sid.ra_slaac=1
      uci add_list dhcp.$sid.ra_flags=managed-config; uci add_list dhcp.$sid.ra_flags=other-config
      uci commit dhcp"
view=$(call "$URL/dhcp/servers/$sid" | sed '$d')
[ "$(printf '%s' "$view" | jq -c '[.dhcpv4, .ra_flags, .ra_slaac]')" = '["server",["managed-config","other-config"],true]' ] \
	|| fail "the odhcpd options read wrong: $view"
r=$(call -X PUT -H 'Content-Type: application/json' "$URL/dhcp/servers/$sid" -d "$(printf '%s' "$view" | jq -c 'del(.runtime)')")
echo "$r" | tail -1 | grep -q '^200$' || fail "PUT of the read expected 200: $r"
stored=$($SSH "uci -q get dhcp.$sid.dhcpv4; uci -q get dhcp.$sid.ra_flags; uci -q get dhcp.$sid.ra_slaac" | tr '\n' '|')
[ "$stored" = "server|managed-config other-config|1|" ] || fail "PUT of the read stored $stored"
assert_dnsmasq_loads

echo "--- dhcp/servers: an ra_flags option of spaces, which gives odhcpd no flag, reads as none and a PUT of the read keeps none ---"
$SSH "uci -q delete dhcp.$sid.ra_flags; uci set dhcp.$sid.ra_flags='  '; uci commit dhcp"
view=$(call "$URL/dhcp/servers/$sid" | sed '$d')
[ "$(printf '%s' "$view" | jq -c '.ra_flags')" = '["none"]' ] || fail "the ra_flags of spaces read wrong: $view"
r=$(call -X PUT -H 'Content-Type: application/json' "$URL/dhcp/servers/$sid" -d "$(printf '%s' "$view" | jq -c 'del(.runtime)')")
echo "$r" | tail -1 | grep -q '^200$' || fail "PUT of the read expected 200: $r"
[ "$($SSH "uci -q get dhcp.$sid.ra_flags")" = "none" ] || fail "PUT of the read stored ra_flags $($SSH "uci -q get dhcp.$sid.ra_flags" || true)"

echo "--- dhcp/servers: DELETE ---"
call -X DELETE "$URL/dhcp/servers/$sid" | tail -1 | grep -q '^204$' || fail "DELETE servers expected 204"
assert_dnsmasq_loads

echo "--- dhcp/dnsmasq singleton: GET returns the existing config ---"
got=$(call "$URL/dhcp/dnsmasq")
echo "$got" | tail -1 | grep -q '^200$' || fail "dnsmasq GET expected 200"

echo "--- dhcp/dnsmasq: PATCH adds a forwarder ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/dnsmasq" -d '{
	"noresolv": true, "server": ["127.0.0.1#5353"]
}')
echo "$patched"
echo "$patched" | tail -1 | grep -q '^200$' || fail "dnsmasq PATCH expected 200"
echo "$patched" | grep -q '"noresolv": true' || fail "PATCH did not update noresolv"
# dnsmasq reads a # as a comment only after whitespace, so the port stays part of the value.
assert_dnsmasq_emits "server=127.0.0.1#5353"
assert_dnsmasq_loads

echo "--- dhcp/dnsmasq: a server option, which dnsmasq.init skips, reads as null and a PATCH of the read keeps it ---"
dns_sec=$($SSH "uci show dhcp" | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p' | head -1)
[ -n "$dns_sec" ] || fail "the test box has no config dnsmasq section"
$SSH "uci -q delete 'dhcp.$dns_sec.server'; uci set 'dhcp.$dns_sec.server=127.0.0.1#5354'; uci commit dhcp; /etc/init.d/dnsmasq reload"
assert_dnsmasq_omits "server=127.0.0.1#5354"
view=$(call "$URL/dhcp/dnsmasq" | sed '$d')
[ "$(printf '%s' "$view" | jq -c '.server')" = 'null' ] || fail "a server option should read as null: $view"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/dnsmasq" -d "$(printf '%s' "$view" | jq -c 'del(.runtime)')")
echo "$r" | tail -1 | grep -q '^200$' || fail "PATCH of the read expected 200: $r"
[ "$($SSH "uci -q get 'dhcp.$dns_sec.server'")" = "127.0.0.1#5354" ] || fail "the PATCH of the read changed the server option"
assert_dnsmasq_omits "server=127.0.0.1#5354"
$SSH "uci -q delete 'dhcp.$dns_sec.server'; uci commit dhcp; /etc/init.d/dnsmasq reload"

echo "--- dhcp/dnsmasq: a double quote or a # after whitespace answers 422 ---"
for body in '{"domain":"lan\"x"}' '{"server":["1.2.3.4 #x"]}' '{"leasefile":"/tmp/dhcp\"leases"}'; do
	r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/dnsmasq" -d "$body")
	echo "$r" | tail -1 | grep -q '^422$' || fail "expected 422 for $body: $r"
done
assert_dnsmasq_loads

echo "--- dhcp/servers: dnsmasq parses the dhcp_option strings that the pattern takes ---"
# This image gives lan no static address, so dnsmasq compiles no dhcp section, and the check runs
# dnsmasq on the line that the init script writes for a dhcp_option.
$SSH 'cat > /tmp/uapi_dhcp_option.conf' <<'EOF'
dhcp-option=lan,66,"1.2.3.4"
dhcp-option=lan,252,"\n"
dhcp-option=lan,67,"a b, #c"
dhcp-option=lan,12,"a\"b"
dhcp-option=lan,114,http://x/#y
EOF
err=$($SSH 'dnsmasq --test -C /tmp/uapi_dhcp_option.conf 2>&1' | grep -v 'syntax check OK' || true)
[ -z "$err" ] || fail "dnsmasq refused a dhcp_option that the pattern takes: $err"
$SSH 'printf "dhcp-option=lan,66,\"1.2.3.4\n" > /tmp/uapi_dhcp_option.conf; dnsmasq --test -C /tmp/uapi_dhcp_option.conf 2>&1' \
	| grep -q 'missing "' || fail "dnsmasq took an unclosed dhcp_option string, which the pattern refuses"
$SSH 'rm -f /tmp/uapi_dhcp_option.conf'

echo "--- dhcp/dnsmasq: PATCH reset (restore) ---"
call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/dnsmasq" -d '{
	"noresolv": false, "server": []
}' | tail -1 | grep -q '^200$' || fail "dnsmasq reset PATCH expected 200"

echo "--- dhcp/odhcpd singleton: GET returns the existing config ---"
got=$(call "$URL/dhcp/odhcpd")
echo "$got" | tail -1 | grep -q '^200$' || fail "odhcpd GET expected 200"

echo "--- dhcp/odhcpd: maindhcp reads true only for 1, which odhcpd and dnsmasq.init both take ---"
saved=$($SSH "uci -q get dhcp.odhcpd.maindhcp" || true)
for v in true yes 2 1; do
	$SSH "uci set dhcp.odhcpd.maindhcp=$v; uci commit dhcp"
	want=false; [ "$v" = "1" ] && want=true
	[ "$(call "$URL/dhcp/odhcpd" | sed '$d' | jq -c '.maindhcp')" = "$want" ] || fail "maindhcp=$v should read $want"
done
echo "--- dhcp/odhcpd: a PATCH of false stores 0 over true, which reads false already ---"
$SSH "uci set dhcp.odhcpd.maindhcp=true; uci commit dhcp"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/odhcpd" -d '{"maindhcp":false}')
echo "$r" | tail -1 | grep -q '^200$' || fail "PATCH of maindhcp false expected 200: $r"
[ "$($SSH "uci -q get dhcp.odhcpd.maindhcp")" = "0" ] || fail "PATCH of false kept maindhcp $($SSH "uci -q get dhcp.odhcpd.maindhcp" || true)"
if [ -n "$saved" ]; then $SSH "uci set dhcp.odhcpd.maindhcp=$saved; uci commit dhcp"; else $SSH "uci -q delete dhcp.odhcpd.maindhcp; uci commit dhcp"; fi

echo "dhcp/servers + dnsmasq + odhcpd ok."
