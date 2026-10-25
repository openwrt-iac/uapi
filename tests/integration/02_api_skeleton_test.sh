#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"

fail() { echo "FAIL: $*"; exit 1; }

echo "--- GET /healthz ---"
healthz=$(curl -sS -w "\n%{http_code}\n" "$URL/healthz")
echo "$healthz"
echo "$healthz" | tail -1 | grep -q '^200$' || fail "healthz expected 200"
echo "$healthz" | grep -q '"status": "ok"' || fail "healthz body missing status:ok"
echo "$healthz" | grep -q '"version"' || fail "healthz body missing version"

echo "--- X-Request-Id header present ---"
hdrs=$(curl -sS -D - -o /dev/null "$URL/healthz")
echo "$hdrs" | grep -qi '^X-Request-Id:' || fail "missing X-Request-Id header"

echo "--- GET /unknown (authenticated) returns 404 not_found ---"
notfound=$(curl -sS -H "$ADMIN" -w "\n%{http_code}\n" "$URL/unknown")
echo "$notfound"
echo "$notfound" | tail -1 | grep -q '^404$' || fail "unknown path expected 404"
echo "$notfound" | grep -q '"code": "not_found"' || fail "404 body missing code"

echo "--- GET /unknown without auth returns 401 ---"
no_auth=$(curl -sS -w "\n%{http_code}\n" "$URL/unknown")
echo "$no_auth" | tail -1 | grep -q '^401$' || fail "no-auth unknown path expected 401"

echo "--- POST /healthz returns 405 ---"
bad_method=$(curl -sS -w "\n%{http_code}\n" -X POST "$URL/healthz")
echo "$bad_method"
echo "$bad_method" | tail -1 | grep -q '^405$' || fail "POST healthz expected 405"

# uci drops these when it replays the commit, and a NUL also cut an anchored id check short.
echo "--- a body with a NUL or a control byte answers 400 on a curated path too ---"
for body in '{"name":"a\u0000b"}' '{"k\u0000x":"1"}' '{"name":"a\u0001b"}'; do
	r=$(curl -sS -H "$ADMIN" -w "\n%{http_code}\n" -X POST -H 'Content-Type: application/json' \
		"$URL/firewall/rules" -d "$body")
	echo "$r" | tail -1 | grep -q '^400$' || fail "POST $body expected 400: $r"
done

echo "api skeleton ok"
