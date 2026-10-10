#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"

fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- POST /dhcp/hosts creates a static lease ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/hosts" -d '{
	"name": "printer",
	"macs": ["aa:bb:cc:dd:ee:ff"],
	"ip": "192.168.1.50",
	"leasetime": "12h"
}')
echo "$created"
echo "$created" | tail -1 | grep -q '^200$' || fail "POST expected 200"
id=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$id" ] || fail "POST missing id"
echo "  new id: $id"

echo "--- GET shows the lease ---"
got=$(call "$URL/dhcp/hosts/$id")
echo "$got" | tail -1 | grep -q '^200$' || fail "GET expected 200"
echo "$got" | grep -q '"aa:bb:cc:dd:ee:ff"' || fail "mac missing"

echo "--- and dnsmasq compiled it, which a 200 and a read-back do not prove ---"
assert_dnsmasq_emits "dhcp-host=aa:bb:cc:dd:ee:ff,192.168.1.50,printer,12h"
assert_dnsmasq_loads

echo "--- POST with invalid MAC returns 422 ---"
invalid=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/hosts" -d '{
	"macs": ["garbage"], "ip": "10.0.0.1"
}')
echo "$invalid" | tail -1 | grep -q '^422$' || fail "invalid mac expected 422"

echo "--- PATCH updates IP ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/hosts/$id" -d '{"ip": "192.168.1.51"}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200"
echo "$patched" | grep -q '"ip": "192.168.1.51"' || fail "PATCH did not update ip"
assert_dnsmasq_emits "dhcp-host=aa:bb:cc:dd:ee:ff,192.168.1.51,printer,12h"
assert_dnsmasq_omits "192.168.1.50"

echo "--- DELETE returns 204 ---"
deleted=$(call -X DELETE "$URL/dhcp/hosts/$id")
echo "$deleted" | tail -1 | grep -q '^204$' || fail "DELETE expected 204"

echo "--- and dnsmasq no longer compiles it ---"
assert_dnsmasq_omits "dhcp-host=aa:bb:cc:dd:ee:ff"
assert_dnsmasq_loads

echo "--- DNS-only entry: mac + name, no ip ---"
dns_only=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/hosts" -d '{
	"name": "noiphost", "macs": ["aa:bb:cc:dd:ee:01"]
}')
echo "$dns_only" | tail -1 | grep -q '^200$' || fail "DNS-only host expected 200"
dns_id=$(echo "$dns_only" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/dhcp/hosts/$dns_id"

echo "--- match_tag: dnsmasq compiles each value as a tag: prefix, and still loads ---"
mt=$(call -X POST -H 'Content-Type: application/json' "$URL/dhcp/hosts" -d '{
	"name": "mtagged", "macs": ["aa:bb:cc:dd:ee:02"], "ip": "192.168.1.52",
	"match_tag": ["ipxe", "!guest"]
}')
echo "$mt" | tail -1 | grep -q '^200$' || fail "POST with match_tag expected 200: $mt"
echo "$mt" | head -1 | grep -q '"match_tag": \[ "ipxe", "!guest" \]' || fail "match_tag did not read back: $mt"
mt_id=$(echo "$mt" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
assert_dnsmasq_emits "dhcp-host=tag:ipxe,tag:!guest,aa:bb:cc:dd:ee:02,192.168.1.52,mtagged"
assert_dnsmasq_loads

echo "--- match_tag: one tag is still written as a list, the only form dnsmasq applies ---"
one=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/hosts/$mt_id" -d '{"match_tag": ["ipxe"]}')
echo "$one" | tail -1 | grep -q '^200$' || fail "PATCH to one match_tag expected 200: $one"
$SSH "uci export dhcp" | grep -q "list match_tag 'ipxe'" || fail "a single match_tag was not stored as a list"
assert_dnsmasq_emits "dhcp-host=tag:ipxe,aa:bb:cc:dd:ee:02,192.168.1.52,mtagged"

echo "--- match_tag: PATCH null clears it ---"
cleared=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/hosts/$mt_id" -d '{"match_tag": null}')
echo "$cleared" | tail -1 | grep -q '^200$' || fail "PATCH match_tag null expected 200: $cleared"
assert_dnsmasq_emits "dhcp-host=aa:bb:cc:dd:ee:02,192.168.1.52,mtagged"
assert_dnsmasq_omits "tag:ipxe"

echo "--- match_tag: a scalar, which dnsmasq ignores, reads as null and survives a write-back ---"
$SSH "uci set dhcp.$mt_id.match_tag=ipxe; uci commit dhcp; /etc/init.d/dnsmasq reload"
assert_dnsmasq_omits "tag:ipxe"
read_back=$(call "$URL/dhcp/hosts/$mt_id")
echo "$read_back" | head -1 | grep -q '"match_tag": null' || fail "a scalar match_tag should read as null: $read_back"
put=$(call -X PUT -H 'Content-Type: application/json' "$URL/dhcp/hosts/$mt_id" -d "$(echo "$read_back" | head -1)")
echo "$put" | tail -1 | grep -q '^200$' || fail "PUT of the read expected 200: $put"
assert_dnsmasq_omits "tag:ipxe"

echo "--- dnsmasq syntax in match_tag, tag or name is refused, and nothing reaches its config ---"
for body in '{"match_tag": ["a,b"]}' '{"match_tag": ["x\"y"]}' '{"tag": ["a,ignore"]}' '{"name": "h1\nlog-queries"}'; do
	r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/dhcp/hosts/$mt_id" -d "$body")
	echo "$r" | tail -1 | grep -q '^422$' || fail "expected 422 for $body: $r"
done
assert_dnsmasq_omits "log-queries"
assert_dnsmasq_omits "set:a,ignore"
assert_dnsmasq_loads
curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/dhcp/hosts/$mt_id"

echo "dhcp hosts CRUD ok"
