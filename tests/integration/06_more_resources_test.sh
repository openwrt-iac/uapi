#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"

fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- POST /firewall/zones creates a zone ---"
zone=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/zones" -d '{
	"name": "uapi_test", "input": "ACCEPT", "output_policy": "ACCEPT", "forward": "REJECT"
}')
echo "$zone" | tail -1 | grep -q '^200$' || fail "zone POST expected 200"
zid=$(echo "$zone" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$zid" ] || fail "zone POST missing id"

echo "--- POST /firewall/redirects against the new zone ---"
redirect=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/redirects" -d '{
	"target": "DNAT",
	"match": { "src_zone": "uapi_test", "src_dport": "8443",
	           "dest_ip": "192.168.1.10", "dest_port": "443", "proto": ["tcp"] }
}')
echo "$redirect" | tail -1 | grep -q '^200$' || fail "redirect POST expected 200"
rid=$(echo "$redirect" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
# The arity bug lived exactly here: this POST returned 200 while firewall4
# discarded the section, because uci wrote src_dport as a list.
assert_fw4_emits "!fw4: $rid" "dport 8443"
assert_fw4_loads

echo "--- POST /firewall/rules with target MARK ---"
markrule=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/rules" -d '{
	"target": "MARK", "set_mark": "0x43",
	"match": { "src_zone": "uapi_test", "dest_zone": "*" }
}')
echo "$markrule" | tail -1 | grep -q '^200$' || fail "MARK rule POST expected 200"
mid=$(echo "$markrule" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
echo "$markrule" | grep -q '"set_mark": "0x43"' || fail "MARK rule missing set_mark on read-back"
# fw4 renders the mark as written; only the applied table pads it to 0x00000043
assert_fw4_emits "!fw4: $mid" "mark set 0x43"
assert_fw4_loads

echo "--- a MARK rule without a mark value is rejected, not silently dropped by fw4 ---"
badmark=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/rules" -d '{
	"target": "MARK", "match": { "src_zone": "uapi_test" }
}')
echo "$badmark" | tail -1 | grep -q '^422$' || fail "MARK without value expected 422"
echo "$badmark" | grep -q '"field": "set_mark"' || fail "422 should name set_mark"

echo "--- a port beside a protocol firewall4 drops it from is rejected, not silently widened ---"
badport=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/rules" -d '{
	"target": "ACCEPT", "match": { "src_zone": "uapi_test", "proto": ["gre"], "dest_port": ["80"] }
}')
echo "$badport" | tail -1 | grep -q '^422$' || fail "port on a non-tcp/udp proto expected 422"
echo "$badport" | grep -q '"field": "match.proto"' || fail "422 should name match.proto"

echo "--- POST /firewall/nat ---"
natrule=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/nat" -d '{
	"name": "uapi_test_masq", "target": "MASQUERADE",
	"match": { "src_zone": "uapi_test" }
}')
echo "$natrule" | tail -1 | grep -q '^200$' || fail "nat POST expected 200"
nid=$(echo "$natrule" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
assert_fw4_emits "!fw4: uapi_test_masq"
assert_fw4_loads

echo "--- nat SNAT without snat_ip or snat_port is rejected ---"
badnat=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/nat" -d '{
	"target": "SNAT", "match": { "src_zone": "uapi_test" }
}')
echo "$badnat" | tail -1 | grep -q '^422$' || fail "SNAT without rewrite expected 422"

echo "--- POST /network/interfaces with proto: none ---"
iface=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" -d '{
	"proto": "none"
}')
echo "$iface" | tail -1 | grep -q '^200$' || fail "interface POST expected 200"
iid=$(echo "$iface" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')

echo "--- POST /network/interfaces with proto: static and bad ipaddr returns 422 ---"
bad_if=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" -d '{
	"proto": "static", "ipaddrs": ["999.0.0.1"]
}')
echo "$bad_if" | tail -1 | grep -q '^422$' || fail "bad ipaddr expected 422"

echo "--- list each resource includes the new id ---"
call "$URL/firewall/zones"     | grep -q "\"id\": \"$zid\"" || fail "zone list missing"
call "$URL/firewall/redirects" | grep -q "\"id\": \"$rid\"" || fail "redirect list missing"
call "$URL/firewall/rules"     | grep -q "\"id\": \"$mid\"" || fail "MARK rule list missing"
call "$URL/firewall/nat"       | grep -q "\"id\": \"$nid\"" || fail "nat list missing"
call "$URL/network/interfaces" | grep -q "\"id\": \"$iid\"" || fail "interface list missing"

echo "--- DELETE each ---"
call -X DELETE "$URL/firewall/redirects/$rid" | tail -1 | grep -q '^204$' || fail "redirect DELETE failed"
call -X DELETE "$URL/firewall/nat/$nid"       | tail -1 | grep -q '^204$' || fail "nat DELETE failed"
call -X DELETE "$URL/firewall/rules/$mid"     | tail -1 | grep -q '^204$' || fail "MARK rule DELETE failed"
call -X DELETE "$URL/firewall/zones/$zid"     | tail -1 | grep -q '^204$' || fail "zone DELETE failed"
call -X DELETE "$URL/network/interfaces/$iid" | tail -1 | grep -q '^204$' || fail "interface DELETE failed"

echo "--- and firewall4 renders none of them any more ---"
assert_fw4_omits "!fw4: $rid"
assert_fw4_omits "!fw4: $mid"
assert_fw4_omits "!fw4: uapi_test_masq"
assert_fw4_loads

echo "more resources ok"
