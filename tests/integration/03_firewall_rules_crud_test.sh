#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN='Authorization: Bearer rwall'
RO='Authorization: Bearer roall'

fail() { echo "FAIL: $*"; exit 1; }

call() {
	curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"
}

echo "--- POST /firewall/rules (admin token) ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/rules" -d '{
	"target": "ACCEPT",
	"match": { "src_zone": "lan", "dest_port": ["22"], "proto": ["tcp"] }
}')
echo "$created"
status=$(echo "$created" | tail -1)
body=$(echo "$created" | sed '$d')
[ "$status" = "200" ] || fail "POST expected 200, got $status"
echo "$body" | grep -q '"managed": true' || fail "created rule missing managed:true"
echo "$body" | grep -q '"target": "ACCEPT"' || fail "created rule missing target"
id=$(echo "$body" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$id" ] || fail "created rule missing id"
echo "  new id: $id"

echo "--- GET /firewall/rules/$id ---"
got=$(call "$URL/firewall/rules/$id")
echo "$got"
echo "$got" | tail -1 | grep -q '^200$' || fail "GET expected 200"
echo "$got" | grep -q "\"id\": \"$id\"" || fail "GET returned wrong id"

echo "--- GET /firewall/rules (list) shows the new rule ---"
listed=$(call "$URL/firewall/rules")
echo "$listed" | tail -1 | grep -q '^200$' || fail "LIST expected 200"
echo "$listed" | grep -q "\"id\": \"$id\"" || fail "LIST missing new rule"

echo "--- PATCH /firewall/rules/$id (change target) ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/firewall/rules/$id" -d '{"target": "DROP"}')
echo "$patched"
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200"
echo "$patched" | grep -q '"target": "DROP"' || fail "PATCH did not update target"

echo "--- PUT /firewall/rules/$id (full replace) ---"
replaced=$(call -X PUT -H 'Content-Type: application/json' "$URL/firewall/rules/$id" -d '{
	"target": "REJECT",
	"match": { "src_zone": "lan" }
}')
echo "$replaced"
echo "$replaced" | tail -1 | grep -q '^200$' || fail "PUT expected 200"
echo "$replaced" | grep -q '"target": "REJECT"' || fail "PUT did not update target"

echo "--- POST with invalid body returns 422 with multiple errors ---"
invalid=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/rules" -d '{}')
echo "$invalid"
echo "$invalid" | tail -1 | grep -q '^422$' || fail "invalid POST expected 422"
echo "$invalid" | grep -q '"code": "validation_failed"' || fail "422 missing code"
echo "$invalid" | grep -q '"errors":' || fail "422 missing errors array"

echo "--- POST without auth returns 401 ---"
no_auth=$(curl -sS -w "\n%{http_code}" -X POST -H 'Content-Type: application/json' "$URL/firewall/rules" -d '{"target":"ACCEPT","match":{"src_zone":"lan"}}')
echo "$no_auth" | tail -1 | grep -q '^401$' || fail "no-auth expected 401"

echo "--- POST with read-only token returns 403 ---"
ro_post=$(curl -sS -H "$RO" -w "\n%{http_code}" -X POST -H 'Content-Type: application/json' "$URL/firewall/rules" -d '{"target":"ACCEPT","match":{"src_zone":"lan"}}')
echo "$ro_post" | tail -1 | grep -q '^403$' || fail "ro POST expected 403"
echo "$ro_post" | grep -q '"code": "insufficient_scope"' || fail "403 missing insufficient_scope"

echo "--- GET with read-only token returns 200 ---"
ro_get=$(curl -sS -H "$RO" -w "\n%{http_code}" "$URL/firewall/rules")
echo "$ro_get" | tail -1 | grep -q '^200$' || fail "ro GET expected 200"

echo "--- DELETE /firewall/rules/$id ---"
deleted=$(call -X DELETE "$URL/firewall/rules/$id")
echo "$deleted"
echo "$deleted" | tail -1 | grep -q '^204$' || fail "DELETE expected 204"

echo "--- GET /firewall/rules/$id after delete returns 404 ---"
gone=$(call "$URL/firewall/rules/$id")
echo "$gone" | tail -1 | grep -q '^404$' || fail "after delete expected 404"

echo "firewall rules CRUD ok"
