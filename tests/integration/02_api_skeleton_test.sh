#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1

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

echo "--- GET /unknown returns 404 not_found ---"
notfound=$(curl -sS -w "\n%{http_code}\n" "$URL/unknown")
echo "$notfound"
echo "$notfound" | tail -1 | grep -q '^404$' || fail "unknown path expected 404"
echo "$notfound" | grep -q '"code": "not_found"' || fail "404 body missing code"

echo "--- POST /healthz returns 405 ---"
bad_method=$(curl -sS -w "\n%{http_code}\n" -X POST "$URL/healthz")
echo "$bad_method"
echo "$bad_method" | tail -1 | grep -q '^405$' || fail "POST healthz expected 405"

echo "api skeleton ok"
