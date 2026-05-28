#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1

fail() { echo "FAIL: $*"; exit 1; }

echo "--- GET /openapi.json (no auth) returns the spec ---"
status=$(curl -sS -o /tmp/got_openapi.json -w "%{http_code}" "$URL/openapi.json")
echo "  status: $status, body bytes: $(wc -c < /tmp/got_openapi.json)"
[ "$status" = "200" ] || fail "openapi.json expected 200"
head -c 200 /tmp/got_openapi.json | grep -q '"openapi"' || fail "missing openapi key"

echo "--- the spec is valid JSON and declares 3.1.0 ---"
python3 -c "
import sys, json
d = json.load(open('/tmp/got_openapi.json'))
assert d['openapi'] == '3.1.0', d['openapi']
assert d['info']['title'] == 'uapi'
assert len(d['paths']) > 20, len(d['paths'])
print('paths:', len(d['paths']))
print('schemas:', len(d['components']['schemas']))
" || fail "openapi.json content sanity check failed"
rm -f /tmp/got_openapi.json

echo "--- POST /openapi.json returns 405 ---"
bad=$(curl -sS -w "\n%{http_code}" -X POST "$URL/openapi.json" -d '{}')
echo "$bad" | tail -1 | grep -q '^405$' || fail "POST expected 405"

echo "openapi.json served ok"
