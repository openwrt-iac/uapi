#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
FW_RO="Authorization: Bearer $FW_RO_TOKEN"

fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- GET /raw/firewall (admin) lists raw sections ---"
listed=$(call "$URL/raw/firewall")
echo "$listed" | tail -1 | grep -q '^200$' || fail "list expected 200"
echo "$listed" | grep -q '"\.type":' || fail "missing .type field"
echo "$listed" | grep -q '"id":'     || fail "missing id field"

echo "--- POST /raw/firewall creates a rule with .type ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/firewall" -d '{
	".type": "rule",
	"target": "ACCEPT",
	"src": "lan",
	"dest_port": "8080",
	"proto": "tcp"
}')
echo "$created"
echo "$created" | tail -1 | grep -q '^200$' || fail "POST expected 200"
id=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$id" ] || fail "POST missing id"
echo "$created" | grep -q '"reloaded": true' || fail "expected reloaded:true"
echo "  new id: $id"

echo "--- GET /raw/firewall/$id ---"
got=$(call "$URL/raw/firewall/$id")
echo "$got" | tail -1 | grep -q '^200$' || fail "GET expected 200"
echo "$got" | grep -q '"\.type": "rule"' || fail "GET missing .type"

echo "--- PATCH /raw/firewall/$id updates target ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/raw/firewall/$id" -d '{"target":"DROP"}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200"
echo "$patched" | grep -q '"target": "DROP"' || fail "PATCH did not update target"

echo "--- POST without .type returns 422 ---"
no_type=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/firewall" -d '{"target":"ACCEPT"}')
echo "$no_type" | tail -1 | grep -q '^422$' || fail "missing .type expected 422"

echo "--- raw POST with only firewall:ro denies (composition check) ---"
denied=$(curl -sS -H "$FW_RO" -w "\n%{http_code}" -X POST -H 'Content-Type: application/json' "$URL/raw/firewall" -d '{
	".type": "rule", "target": "ACCEPT", "src": "lan"
}')
echo "$denied" | tail -1 | grep -q '^403$' || fail "ro POST via /raw/ expected 403"

# Clearing a list through raw. uci cannot store an empty list, so `[]` means "no option";
# the binding silently discarded it and the option survived a 200. raw.uc hard-codes the
# transaction lock path, so this cannot be exercised from the unit suite. Driven entirely
# over HTTP like the rest of this file: the first version shelled into the VM and hung the
# job to its 15 minute timeout.
echo "--- raw: an empty list clears the option instead of being silently dropped ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/firewall" -d '{
	".type": "rule", "name": "uapi_list_probe", "target": "ACCEPT", "src": "lan",
	"proto": ["tcp", "udp"]
}')
echo "$created" | tail -1 | grep -q '^200$' || fail "list-probe create expected 200"
probe_id=$(echo "$created" | sed -n 's/.*"id":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$probe_id" ] || fail "no id returned for the list probe"
echo "$created" | grep -q '"tcp"' || fail "seed did not store the list"

cleared=$(call -X PATCH -H 'Content-Type: application/json' \
	"$URL/raw/firewall/$probe_id" -d '{"proto":[]}')
echo "$cleared" | tail -1 | grep -q '^200$' || fail "raw PATCH clearing a list expected 200"

after=$(call "$URL/raw/firewall/$probe_id")
echo "$after" | tail -1 | grep -q '^200$' || fail "re-read after clearing expected 200"
echo "$after" | grep -q '"proto"' \
	&& fail "raw PATCH answered 200 but proto survived: $(echo "$after" | head -1)"
echo "  proto cleared and stays cleared on re-read"
curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/raw/firewall/$probe_id"

echo "--- POST to an unknown package writes the file but reports reloaded:false ---"
unknown=$(call -X POST -H 'Content-Type: application/json' "$URL/raw/uapi_test_unknown" -d '{
	".type": "thing", "color": "red"
}')
echo "$unknown"
echo "$unknown" | tail -1 | grep -q '^200$' || fail "unknown pkg POST expected 200"
echo "$unknown" | grep -q '"reloaded": false' || fail "expected reloaded:false for unknown package"
echo "$unknown" | grep -q '"reload_note"' || fail "expected reload_note for unknown package"

echo "--- DELETE the rule ---"
deleted=$(call -X DELETE "$URL/raw/firewall/$id")
echo "$deleted" | tail -1 | grep -q '^204$' || fail "DELETE expected 204"

echo "raw passthrough ok"
