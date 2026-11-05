#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
SSH="tests/vm/ssh.sh"

fail() { echo "FAIL: $*"; exit 1; }

call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- inject an anonymous rule via uci ---"
anon_id=$($SSH 'uci add firewall rule')
$SSH "uci set firewall.$anon_id.target=DROP
      uci set firewall.$anon_id.src=lan
      uci set firewall.$anon_id.dest_port=23
      uci commit firewall"
echo "  anon id: $anon_id"

echo "--- v4 (#321): the read carries no managed field, and the section is addressable by name ---"
got=$(call "$URL/firewall/rules/$anon_id")
echo "$got" | tail -1 | grep -q '^200$' || fail "GET expected 200"
echo "$got" | grep -q '"managed"' && fail "managed must be gone from the response"

echo "--- PUT on the anonymous section by name answers 200 ---"
put=$(call -X PUT -H 'Content-Type: application/json' "$URL/firewall/rules/$anon_id" -d '{"target":"ACCEPT","match":{"src_zone":"lan"}}')
echo "$put" | tail -1 | grep -q '^200$' || fail "PUT on anonymous section expected 200: $put"

echo "--- POST .../adopt is gone: 404 ---"
adopt=$(call -X POST "$URL/firewall/rules/$anon_id/adopt")
echo "$adopt" | tail -1 | grep -q '^404$' || fail "adopt expected 404 on v4: $adopt"

echo "--- DELETE on the anonymous section by name answers 204 ---"
del=$(call -X DELETE "$URL/firewall/rules/$anon_id")
echo "$del" | tail -1 | grep -q '^204$' || fail "DELETE on anonymous section expected 204: $del"

echo "adopt-route removal (v4 #321) ok."
