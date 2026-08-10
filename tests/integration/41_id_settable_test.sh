#!/bin/sh
set -eu

# 2.2.0: every CRUD resource accepts optional `id` at create. Adopt of
# named sections keeps the name. This test exercises both against real
# uci on the VM.

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

# Cleanup runs on any exit path so a mid-test fail() doesn't leave
# debris on the VM (and on the live router when this test gets pointed
# at one). All deletes are tolerant of "already gone" results: a 204 is
# success, a 404 means an earlier step never created the resource.
ulid_id=""
preexisting_created=0
cleanup() {
	[ -n "$ulid_id" ] && curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/firewall/rules/$ulid_id" || true
	curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/network/interfaces/itest" || true
	curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/firewall/zones/ztest" || true
	if [ "$preexisting_created" = "1" ]; then
		$SSH "uci -q delete firewall.preexisting; uci -q commit firewall" || true
	fi
}
trap cleanup EXIT INT TERM

echo "--- POST /firewall/zones with caller-supplied id=ztest creates section firewall.ztest ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/zones" \
	-d '{"id":"ztest","name":"ztest","input":"ACCEPT","output_policy":"ACCEPT","forward":"REJECT"}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "POST /firewall/zones expected 200, got $status: $body"
echo "$body" | grep -q '"id": "ztest"' || fail "expected id=ztest in response"
$SSH "uci get firewall.ztest" >/dev/null || fail "uci section firewall.ztest not found"

echo "--- POST /firewall/rules with id colliding with the zone -> 422 conflict ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/rules" \
	-d '{"id":"ztest","target":"ACCEPT","match":{"src_zone":"lan"}}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "422" ] || fail "expected 422 for cross-type id conflict, got $status: $body"
echo "$body" | grep -q '"field": "id"' || fail "expected field=id in errors"
echo "$body" | grep -q '"code": "conflict"' || fail "expected code=conflict in errors"

echo "--- POST /firewall/rules with bad-charset id -> 422 invalid_format ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/rules" \
	-d '{"id":"0starts-with-digit","target":"ACCEPT","match":{"src_zone":"lan"}}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "422" ] || fail "expected 422 for invalid charset, got $status: $body"
echo "$body" | grep -q '"code": "invalid_format"' || fail "expected invalid_format"

echo "--- POST /firewall/rules without id -> 200 + server-emitted ULID ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/rules" \
	-d '{"name":"21_id_settable","target":"ACCEPT","match":{"src_zone":"lan","dest_port":["22222"]}}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "POST without id expected 200, got $status: $body"
ulid_id=$(echo "$body" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
echo "$ulid_id" | grep -qE '^r_[0-9a-z]{26}$' || fail "expected r_<ulid>, got $ulid_id"

echo "--- adopt a uci-set out-of-band zone keeps its name (the real field scenario) ---"
# This is the case the field reporter actually hit: a zone that uapi did
# NOT create (set out-of-band via uci) gets adopted, the name must be
# preserved so cross-references (firewall.rules.src_zone = "preexisting")
# keep resolving.
$SSH "uci set firewall.preexisting=zone
      uci set firewall.preexisting.name=preexisting
      uci set firewall.preexisting.input=ACCEPT
      uci set firewall.preexisting.output=ACCEPT
      uci set firewall.preexisting.forward=REJECT
      uci commit firewall"
preexisting_created=1

resp=$(call -X POST "$URL/firewall/zones/preexisting/adopt")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "adopt preexisting expected 200, got $status: $body"
echo "$body" | grep -q '"id": "preexisting"' || fail "expected id=preexisting (not renamed to ULID)"
$SSH "uci get firewall.preexisting" >/dev/null || fail "uci section preexisting lost after adopt"

echo "--- named-section adopt doesn't fire X-Reload-Status: ok (no spurious reload) ---"
hdr=$(curl -sS -D - -o /dev/null -H "$ADMIN" -X POST "$URL/firewall/zones/preexisting/adopt")
# Should be missing or 'no_reload'; the buggy old path returned 'ok'
# because reload(services) fired on the success path. Either no header
# or 'no_reload' is acceptable here.
if echo "$hdr" | grep -i '^X-Reload-Status:' | grep -qi 'ok'; then
	echo "$hdr" | grep -i '^X-Reload-Status:' >&2
	fail "named-section adopt fired a reload (regression of S1 fix)"
fi

echo "--- ztest zone (uapi-created, named) adopt is also a no-op ---"
resp=$(call -X POST "$URL/firewall/zones/ztest/adopt")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "adopt ztest expected 200, got $status: $body"
echo "$body" | grep -q '"id": "ztest"' || fail "expected id=ztest after adopt"

echo "--- network/interfaces accepts id as alias for name (deprecated) ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d '{"id":"itest","proto":"static","ipaddrs":["192.0.2.1"],"netmask":"255.255.255.0"}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "POST /network/interfaces with id expected 200, got $status: $body"
echo "$body" | grep -q '"id": "itest"' || fail "expected id=itest"

echo "--- portless bridge create succeeds ---"
br_resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/devices" \
	-d '{"id":"br_tftest","name":"br_tftest","type":"bridge"}')
br_status=$(echo "$br_resp" | tail -1)
br_body=$(echo "$br_resp" | sed '$d')
[ "$br_status" = "200" ] || fail "POST portless bridge expected 200, got $br_status: $br_body"
echo "$br_body" | grep -q '"id": "br_tftest"' || fail "expected id=br_tftest"
$SSH "uci get network.br_tftest" >/dev/null || fail "uci section network.br_tftest not created"
$SSH "uci -q get network.br_tftest.ports" && fail "uci should have no ports on a portless bridge" || true
br_id="br_tftest"

del=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" -X DELETE "$URL/network/devices/$br_id")
[ "$del" = "204" ] || fail "DELETE portless bridge expected 204, got $del"

echo "id-settable + adopt-keep-name + portless-bridge ok."
