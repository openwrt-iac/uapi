#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
RO="Authorization: Bearer $RO_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

echo "--- /healthz returns subsystem checks ---"
body=$(curl -sS "$URL/healthz")
echo "$body" | grep -q '"checks"' || fail "healthz missing checks block"
echo "$body" | grep -q '"ubus"'    || fail "healthz missing ubus check"
echo "$body" | grep -q '"uci"'     || fail "healthz missing uci check"
echo "$body" | grep -q '"lock_dir"' || fail "healthz missing lock_dir check"
echo "$body" | grep -q '"time_sync"' || fail "healthz missing time_sync check"

echo "--- /schema lists resources ---"
status=$(curl -sS -o /tmp/uapi_schema_list.json -w '%{http_code}' "$URL/schema")
[ "$status" = "200" ] || fail "GET /schema expected 200, got $status"
grep -q '"firewall:rules"' /tmp/uapi_schema_list.json || fail "/schema missing firewall:rules"
grep -q '"system"'         /tmp/uapi_schema_list.json || fail "/schema missing system"

echo "--- /schema/<pkg>/<resource> returns schema_properties ---"
status=$(curl -sS -o /tmp/uapi_schema_one.json -w '%{http_code}' "$URL/schema/firewall/rules")
[ "$status" = "200" ] || fail "GET /schema/firewall/rules expected 200, got $status"
grep -q '"schema_properties"' /tmp/uapi_schema_one.json || fail "missing schema_properties"
grep -q '"package": "firewall"' /tmp/uapi_schema_one.json || fail "missing package field"

echo "--- /schema/<pkg> returns the package subset ---"
status=$(curl -sS -o /tmp/uapi_schema_pkg.json -w '%{http_code}' "$URL/schema/firewall")
[ "$status" = "200" ] || fail "GET /schema/firewall expected 200, got $status"
grep -q '"firewall:rules"'    /tmp/uapi_schema_pkg.json || fail "/schema/firewall missing rules"
grep -q '"firewall:defaults"' /tmp/uapi_schema_pkg.json || fail "/schema/firewall missing defaults singleton"

echo "--- /schema does not require auth ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' "$URL/schema/firewall/rules")
[ "$status" = "200" ] || fail "/schema must be public, got $status"

echo "--- /schema 404s for unknown resources ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' "$URL/schema/no/such")
[ "$status" = "404" ] || fail "unknown schema expected 404, got $status"

echo "--- /auth/whoami requires auth ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' "$URL/auth/whoami")
[ "$status" = "401" ] || fail "no auth expected 401, got $status"

echo "--- /auth/whoami 401 carries WWW-Authenticate ---"
header_line=$(curl -sS -D - -o /dev/null "$URL/auth/whoami" | tr -d '\r' \
	| grep -i '^WWW-Authenticate:')
echo "$header_line" | grep -q 'Bearer realm="uapi"' \
	|| fail "401 missing WWW-Authenticate Bearer header: $header_line"

echo "--- /auth/whoami returns token metadata ---"
body=$(curl -sS -H "$ADMIN" "$URL/auth/whoami")
echo "$body" | grep -q '"token_id": "test_admin"' || fail "whoami missing token_id"
echo "$body" | grep -q '"scopes"'                || fail "whoami missing scopes"
echo "$body" | grep -q '"source_ip"'             || fail "whoami missing source_ip"
echo "$body" | grep -q '"expires_at"'            || fail "whoami missing expires_at placeholder"

echo "--- inbound request id (?request_id= fallback) is echoed back ---"
# uhttpd's CGI env allowlist drops X-Request-Id. We pass it as a query param;
# proxies that propagate the header still work via the header path.
my_id="req-01HXTEST00000000000000"
echoed=$(curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/auth/whoami?request_id=$my_id" \
	| tr -d '\r' | sed -n 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//p' | tr -d '[:space:]')
[ "$echoed" = "$my_id" ] || fail "request_id not echoed: got '$echoed' want '$my_id'"

echo "--- malformed request id is dropped (server generates a fresh one) ---"
gen=$(curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/auth/whoami?request_id=short" \
	| tr -d '\r' | sed -n 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//p' | tr -d '[:space:]')
[ -n "$gen" ] || fail "no X-Request-Id in response after malformed inbound"
[ "$gen" != "short" ] || fail "server accepted a malformed request_id"

echo "--- conditional GET: If-None-Match matching ETag returns 304 ---"
# /system singleton is the simplest GET that returns an ETag.
etag=$(curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/system" | tr -d '\r' \
	| sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
[ -n "$etag" ] || fail "no ETag on /system"
# uhttpd's CGI env drops If-None-Match like it drops If-Match; use ?if_none_match=
unq=$(printf '%s' "$etag" | tr -d '"')
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" \
	"$URL/system?if_none_match=$unq")
[ "$status" = "304" ] || fail "If-None-Match (current etag) expected 304, got $status"

echo "--- conditional GET: If-None-Match=* always returns 304 for existing GETs ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" \
	"$URL/system?if_none_match=%2A")
[ "$status" = "304" ] || fail "If-None-Match=* expected 304, got $status"

echo "--- conditional GET: non-matching If-None-Match returns 200 ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" \
	"$URL/system?if_none_match=deadbeef0000")
[ "$status" = "200" ] || fail "non-matching If-None-Match expected 200, got $status"

echo "Batch 4 endpoints ok."
