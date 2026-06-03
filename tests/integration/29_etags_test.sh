#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

echo "--- create a rule we can If-Match against ---"
created=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" -d '{
		"name": "etag-test",
		"target": "ACCEPT",
		"enabled": true,
		"match": { "src_zone": "wan", "proto": ["tcp"], "dest_port": ["8080"] }
	}')
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
[ -n "$id" ] || fail "no id from POST"
trap "curl -sS -o /dev/null -H \"$ADMIN\" -X DELETE \"$URL/firewall/rules/$id\" || true" EXIT INT TERM

echo "--- GET returns an ETag header ---"
etag=$(curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/firewall/rules/$id" | tr -d '\r' \
	| sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
[ -n "$etag" ] || fail "no ETag on GET"
echo "  etag=$etag"

echo "--- ETag is stable across reads of the same state (runtime fields excluded) ---"
# Hit an endpoint whose fromUci populates a runtime block from ubus
# (network/interfaces calls network.interface.<name> status, which surfaces
# uptime in seconds). Two consecutive GETs must return identical ETag values:
# if they don't, ETags include drifting runtime data and any If-Match flow
# trips spurious 412s.
e1=$(curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/network/interfaces/loopback" | tr -d '\r' \
	| sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
sleep 2
e2=$(curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/network/interfaces/loopback" | tr -d '\r' \
	| sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
[ -n "$e1" ] && [ "$e1" = "$e2" ] \
	|| fail "ETag drifted across two reads of /network/interfaces/loopback (e1=$e1 e2=$e2)"

echo "--- PATCH without If-Match still works ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" -H 'Content-Type: application/json' \
	-X PATCH "$URL/firewall/rules/$id" -d '{"enabled": true}')
[ "$status" = "200" ] || fail "PATCH no-if-match expected 200, got $status"

echo "--- PATCH with current If-Match (via ?if_match query param) succeeds and returns a NEW ETag ---"
# uhttpd strips the If-Match header (its CGI env allowlist excludes it), so we
# pass the ETag through ?if_match=<value> instead. The handler accepts either.
fresh_etag_raw=$(curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/firewall/rules/$id" | tr -d '\r' \
	| sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' | head -1 | tr -d '[:space:]"')
new_etag_raw=$(curl -sS -D - -o /dev/null -H "$ADMIN" \
	-H 'Content-Type: application/json' \
	-X PATCH "$URL/firewall/rules/$id?if_match=$fresh_etag_raw" -d '{"enabled": false}' \
	| tr -d '\r' | sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' | head -1 | tr -d '[:space:]"')
[ -n "$new_etag_raw" ] || fail "no ETag on successful if_match write"
[ "$new_etag_raw" != "$fresh_etag_raw" ] || fail "ETag did not change after a real mutation"

echo "--- PATCH with stale ?if_match returns 412 precondition_failed ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" -H 'Content-Type: application/json' \
	-X PATCH "$URL/firewall/rules/$id?if_match=deadbeef0000" -d '{"enabled": true}')
[ "$status" = "412" ] || fail "stale if_match expected 412, got $status"

echo "--- ?if_match=* succeeds against any existing resource ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' \
	-H "$ADMIN" -H 'Content-Type: application/json' \
	-X PATCH "$URL/firewall/rules/$id?if_match=%2A" -d '{"enabled": true}')
[ "$status" = "200" ] || fail "if_match=* expected 200, got $status"

echo "--- PUT with stale ?if_match returns 412 and rolls back ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" -H 'Content-Type: application/json' \
	-X PUT "$URL/firewall/rules/$id?if_match=00000000abcd" -d '{
		"name": "should-not-take",
		"target": "DROP",
		"match": { "src_zone": "wan" }
	}')
[ "$status" = "412" ] || fail "PUT stale If-Match expected 412, got $status"
name_after=$(curl -sS -H "$ADMIN" "$URL/firewall/rules/$id" \
	| sed -n 's/.*"name": *"\([^"]*\)".*/\1/p')
[ "$name_after" = "etag-test" ] || fail "412 still changed state: name=$name_after"

echo "--- singleton GET also returns an ETag (system) ---"
sys_etag=$(curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/system" | tr -d '\r' \
	| sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
[ -n "$sys_etag" ] || fail "no ETag on singleton GET /system"

echo "ETag / If-Match round-trip ok."
