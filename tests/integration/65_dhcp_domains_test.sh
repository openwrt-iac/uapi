#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v4
ADMIN="Authorization: Bearer $ADMIN_TOKEN"

fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }
hosts_files() { $SSH "cat /tmp/hosts/dhcp.* 2>/dev/null" || true; }
answer() { $SSH "nslookup $1 127.0.0.1 2>&1" || true; }

echo "--- POST /dhcp/domains creates a record that dnsmasq answers ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/domains" -d '{
	"name": "uapitest.lan", "ip": "192.168.1.60"
}')
echo "$created"
echo "$created" | tail -1 | grep -q '^200$' || fail "POST expected 200"
id=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$id" ] || fail "POST missing id"
[ "$($SSH "uci -q get dhcp.$id")" = domain ] || fail "the section is not a config domain"
hosts_files | grep -qx '192.168.1.60 uapitest.lan' || fail "no hosts file holds the record: $(hosts_files)"
out=$(answer uapitest.lan)
echo "$out"
echo "$out" | grep -q '192.168.1.60' || fail "dnsmasq does not answer the name"
assert_dnsmasq_loads

echo "--- GET reads it back ---"
got=$(call "$URL/dhcp/domains/$id" | sed '$d')
[ "$(printf '%s' "$got" | jq -c '[.name, .ip, .instance, .managed]')" = '["uapitest.lan","192.168.1.60",null,true]' ] \
	|| fail "the read is wrong: $got"

echo "--- PATCH to an IPv6 address moves the answer ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/domains/$id" -d '{"ip": "fd00::60"}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200: $patched"
out=$(answer uapitest.lan)
echo "$out"
echo "$out" | grep -q 'fd00::60' || fail "dnsmasq does not answer the new address"
echo "$out" | grep -q '192.168.1.60' && fail "dnsmasq still answers the old address"

echo "--- a name or an ip that dnsmasq would read differently answers 422 ---"
for body in '{"name": "two words"}' '{"name": "-uapitest"}' '{"ip": "192.168.1.60/24"}' '{"ip": "192.168.1.60 192.168.1.61"}' '{"instance": "nosuch"}'; do
	r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/domains/$id" -d "$body")
	echo "$r" | tail -1 | grep -q '^422$' || fail "expected 422 for $body: $r"
done
r=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/domains" -d '{"name": "noip"}')
echo "$r" | tail -1 | grep -q '^422$' || fail "a POST without ip expected 422: $r"

echo "--- a stored name of two words is two names to dnsmasq, and blocks a write until it is fixed ---"
$SSH "uci set dhcp.$id.name='uapitest-a uapitest-b'; uci commit dhcp; /etc/init.d/dnsmasq reload"
answer uapitest-b | grep -q 'fd00::60' || fail "dnsmasq does not answer the second word"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/domains/$id" -d '{"ip": "fd00::61"}')
echo "$r" | tail -1 | grep -q '^422$' || fail "a PATCH of ip beside a stored name of two words expected 422: $r"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/domains/$id" -d '{"name": "uapitest.lan"}')
echo "$r" | tail -1 | grep -q '^200$' || fail "a PATCH that fixes the name expected 200: $r"

echo "--- a section that LuCI adds reads as unmanaged ---"
$SSH "uci add dhcp domain >/dev/null; uci set dhcp.@domain[-1].name=luci-host; uci set dhcp.@domain[-1].ip=192.168.1.62; uci commit dhcp; /etc/init.d/dnsmasq reload"
list=$(call "$URL/dhcp/domains" | sed '$d')
[ "$(printf '%s' "$list" | jq -c '[.[] | select(.name == "luci-host") | .managed]')" = '[false]' ] \
	|| fail "the LuCI section does not read as unmanaged: $list"
answer luci-host | grep -q '192.168.1.62' || fail "dnsmasq does not answer the LuCI section"
$SSH "uci delete dhcp.@domain[-1]; uci commit dhcp; /etc/init.d/dnsmasq reload"

echo "--- DELETE returns 204, and dnsmasq stops answering ---"
deleted=$(call -X DELETE "$URL/dhcp/domains/$id")
echo "$deleted" | tail -1 | grep -q '^204$' || fail "DELETE expected 204"
hosts_files | grep -q 'uapitest' && fail "a hosts file still holds the record"
answer uapitest.lan | grep -q 'fd00::60' && fail "dnsmasq still answers the deleted name"
assert_dnsmasq_loads

echo "dhcp domains CRUD ok"
