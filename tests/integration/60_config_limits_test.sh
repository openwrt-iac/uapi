#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
SSH="tests/vm/ssh.sh"
fail() { echo "FAIL: $*"; exit 1; }

echo "--- /diagnostics reports the compiled defaults without a config section ---"
curl -sS -H "$ADMIN" "$URL/diagnostics" -o /tmp/uapi_diag0.json
grep -q '"max_body_bytes": 262144' /tmp/uapi_diag0.json || fail "default max_body_bytes not reported: $(cat /tmp/uapi_diag0.json)"
grep -q '"reload_budget_s": 20' /tmp/uapi_diag0.json || fail "default reload_budget_s not reported"

echo "--- a configured limit is reported and enforced ---"
$SSH 'uci -q add uapi limits && uci -q set uapi.@limits[-1].max_body_bytes=4096 && uci -q commit uapi'
curl -sS -H "$ADMIN" "$URL/diagnostics" -o /tmp/uapi_diag1.json
grep -q '"max_body_bytes": 4096' /tmp/uapi_diag1.json || fail "configured max_body_bytes not reported: $(cat /tmp/uapi_diag1.json)"
big=$(head -c 8192 /dev/zero | tr '\0' 'a')
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" --data-binary "{\"name\":\"$big\"}")
[ "$status" = "413" ] || fail "expected 413 with max_body_bytes=4096, got $status"

echo "--- an out-of-bounds value falls back to the default ---"
$SSH 'uci -q set uapi.@limits[-1].max_body_bytes=10 && uci -q commit uapi'
curl -sS -H "$ADMIN" "$URL/diagnostics" -o /tmp/uapi_diag2.json
grep -q '"max_body_bytes": 262144' /tmp/uapi_diag2.json || fail "out-of-bounds value not ignored: $(cat /tmp/uapi_diag2.json)"

$SSH 'uci -q delete uapi.@limits[-1] && uci -q commit uapi'
curl -sS -H "$ADMIN" "$URL/diagnostics" -o /tmp/uapi_diag3.json
grep -q '"max_body_bytes": 262144' /tmp/uapi_diag3.json || fail "default not restored after delete: $(cat /tmp/uapi_diag3.json)"

echo "Config limits test ok."
