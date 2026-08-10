#!/bin/sh
set -eu

# 2.2.1: pre-create uniqueness check covers the resource's unique_field
# value (firewall.zone.name, network.device.name, sqm.queue.interface),
# not just the section id. Exercises POST, PUT, and PATCH on real uci.

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

cleanup() {
	curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/firewall/zones/zt42_ok" || true
	curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/network/devices/d42_ok" || true
	$SSH "uci -q delete network.dev42; uci -q commit network" || true
	$SSH "uci -q delete firewall.zt42_seed; uci -q commit firewall" || true
}
trap cleanup EXIT INT TERM

# Seed a manual zone first so the duplicate test doesn't depend on the box's
# default lan zone (which integration boxes may not have, depending on image).
$SSH "uci set firewall.zt42_seed=zone; uci set firewall.zt42_seed.name=zt42seed; uci set firewall.zt42_seed.input=ACCEPT; uci set firewall.zt42_seed.output=ACCEPT; uci set firewall.zt42_seed.forward=REJECT; uci commit firewall"

echo "--- POST: duplicate firewall.zone.name rejected with 422/conflict naming offender ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/zones" \
	-d '{"id":"zt42_dup","name":"zt42seed","input":"ACCEPT","output_policy":"ACCEPT","forward":"REJECT"}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "422" ] || fail "expected 422 for duplicate zone name, got $status: $body"
echo "$body" | grep -q '"field": "name"' || fail "error envelope should name field=name"
echo "$body" | grep -q '"code": "conflict"' || fail "error envelope should have code=conflict"
echo "$body" | grep -q 'zt42_seed' || fail "error message should reference the existing section"

echo "--- POST: non-colliding firewall.zone.name accepted ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/zones" \
	-d '{"id":"zt42_ok","name":"zt42ok","input":"ACCEPT","output_policy":"ACCEPT","forward":"REJECT"}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "expected 200 for fresh zone name, got $status: $body"

echo "--- PATCH: changing name to a colliding value is rejected ---"
resp=$(call -X PATCH -H 'Content-Type: application/json' "$URL/firewall/zones/zt42_ok" \
	-d '{"name":"zt42seed"}')
status=$(echo "$resp" | tail -1)
[ "$status" = "422" ] || fail "expected 422 for PATCH to colliding name, got $status"

echo "--- PATCH: leaving name at current value passes (ignore_section_id excludes self) ---"
resp=$(call -X PATCH -H 'Content-Type: application/json' "$URL/firewall/zones/zt42_ok" \
	-d '{"name":"zt42ok"}')
status=$(echo "$resp" | tail -1)
[ "$status" = "200" ] || fail "expected 200 for PATCH keeping same name, got $status"

echo "--- PUT: full replace to a colliding name is rejected ---"
resp=$(call -X PUT -H 'Content-Type: application/json' "$URL/firewall/zones/zt42_ok" \
	-d '{"name":"zt42seed","input":"ACCEPT","output_policy":"ACCEPT","forward":"REJECT"}')
status=$(echo "$resp" | tail -1)
[ "$status" = "422" ] || fail "expected 422 for PUT to colliding name, got $status"

echo "--- POST: duplicate network.device.name rejected ---"
$SSH "uci set network.dev42=device; uci set network.dev42.name=dev42; uci set network.dev42.type=bridge; uci commit network"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/devices" \
	-d '{"id":"d42_dup","name":"dev42","type":"bridge"}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "422" ] || fail "expected 422 for duplicate device name, got $status: $body"
echo "$body" | grep -q '"field": "name"' || fail "error envelope should name field=name"

echo "--- POST: non-colliding network.device.name accepted ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/devices" \
	-d '{"id":"d42_ok","name":"dev42_ok","type":"bridge"}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "expected 200 for fresh device name, got $status: $body"

echo "OK"
