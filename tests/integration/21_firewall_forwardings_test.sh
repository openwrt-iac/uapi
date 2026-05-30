#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- create two zones first (cross-reference target) ---"
src_zone=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/zones" -d '{
	"name": "uapi_fwd_src", "input": "ACCEPT", "output": "ACCEPT", "forward": "ACCEPT"
}')
src_zid=$(echo "$src_zone" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
echo "  src zone: $src_zid"

dst_zone=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/zones" -d '{
	"name": "uapi_fwd_dst", "input": "REJECT", "output": "ACCEPT", "forward": "REJECT"
}')
dst_zid=$(echo "$dst_zone" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
echo "  dst zone: $dst_zid"

cleanup() {
	curl -sS -H "$ADMIN" -X DELETE "$URL/firewall/zones/$src_zid" >/dev/null 2>&1 || true
	curl -sS -H "$ADMIN" -X DELETE "$URL/firewall/zones/$dst_zid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "--- POST /firewall/forwardings with both zones present ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/forwardings" -d '{
	"src": "uapi_fwd_src", "dest": "uapi_fwd_dst"
}')
echo "$created"
status=$(echo "$created" | tail -1)
[ "$status" = "200" ] || fail "POST expected 200, got $status"
fid=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$fid" ] || fail "POST missing id"
echo "$created" | grep -q '"managed": true' || fail "created forwarding missing managed:true"
echo "$created" | grep -q '"family": "any"' || fail "default family != any"
echo "$created" | grep -q '"enabled": true' || fail "default enabled != true"

echo "--- POST referencing a missing zone returns 422 with conflict on the src field ---"
missing=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/forwardings" -d '{
	"src": "no_such_zone", "dest": "uapi_fwd_dst"
}')
echo "$missing"
status=$(echo "$missing" | tail -1)
[ "$status" = "422" ] || fail "missing-zone POST expected 422, got $status"
echo "$missing" | grep -q '"field": "src"' || fail "expected error on src field"
echo "$missing" | grep -q '"code": "conflict"' || fail "expected conflict code"

echo "--- POST missing both src and dest returns 422 with both errors ---"
empty=$(call -X POST -H 'Content-Type: application/json' "$URL/firewall/forwardings" -d '{}')
echo "$empty"
status=$(echo "$empty" | tail -1)
[ "$status" = "422" ] || fail "empty POST expected 422, got $status"
echo "$empty" | grep -q '"field": "src",[[:space:]]*"code": "required"' || fail "missing src not reported"
echo "$empty" | grep -q '"field": "dest",[[:space:]]*"code": "required"' || fail "missing dest not reported"

echo "--- PATCH /firewall/forwardings/$fid (change family) ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/firewall/forwardings/$fid" -d '{
	"family": "ipv4"
}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200"
echo "$patched" | grep -q '"family": "ipv4"' || fail "PATCH did not update family"

echo "--- GET list contains the forwarding ---"
listed=$(call "$URL/firewall/forwardings")
echo "$listed" | tail -1 | grep -q '^200$' || fail "LIST expected 200"
echo "$listed" | grep -q "\"id\": \"$fid\"" || fail "LIST missing the new forwarding"

echo "--- DELETE /firewall/forwardings/$fid ---"
call -X DELETE "$URL/firewall/forwardings/$fid" | tail -1 | grep -q '^204$' || fail "DELETE expected 204"

echo "--- GET after delete returns 404 ---"
gone=$(call "$URL/firewall/forwardings/$fid")
echo "$gone" | tail -1 | grep -q '^404$' || fail "after delete expected 404"

echo "firewall.forwardings CRUD + cross-reference validation ok."
