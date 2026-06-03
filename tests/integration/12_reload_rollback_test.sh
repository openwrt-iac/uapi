#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# Inject a one-shot failure into the firewall reload path by wrapping fw4. The
# /etc/init.d/firewall script invokes fw4 reload; failing once via a marker file
# triggers exactly the path documented in CLAUDE.md "Atomic transaction recipe"
# step 6: first reload fails, snapshot-restore reloads succeeds, response is
# 500 reload_failed_restored, uci is back to the pre-write snapshot.
# The VM ships a stub /etc/init.d/firewall (from tests/vm/setup.sh) that honors
# /tmp/fw-fail-once: when present, reload_service consumes the marker and
# returns 1 on this single reload, then returns 0 on subsequent calls. That's
# exactly what the snapshot-restore recipe needs to exercise: first reload
# fails, restore re-reload succeeds, response is 500 reload_failed_restored.
cleanup() { $SSH 'rm -f /tmp/fw-fail-once' || true; }
trap cleanup EXIT INT TERM

echo "--- snapshot uci firewall state before the failing write ---"
before=$($SSH 'uci export firewall')

echo "--- arm the fail-once trigger ---"
$SSH 'touch /tmp/fw-fail-once'

echo "--- POST a valid rule; first reload fails, restore re-reload succeeds ---"
resp=$(curl -sS -w "\n%{http_code}" -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" -d '{
	"target": "ACCEPT",
	"match": { "src_zone": "lan", "dest_port": ["9999"], "proto": ["tcp"] }
}')
echo "$resp" | head -20
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "500" ] || fail "expected 500 reload_failed_restored, got $status"
echo "$body" | grep -q '"code": "reload_failed_restored"' || fail "expected reload_failed_restored code"
echo "$body" | grep -q '"reload_error"' || fail "expected reload_error in body"

echo "--- uci firewall state must match the pre-write snapshot ---"
after=$($SSH 'uci export firewall')
if [ "$before" != "$after" ]; then
	echo "BEFORE:"
	echo "$before"
	echo "AFTER:"
	echo "$after"
	fail "uci firewall state was not restored to the pre-write snapshot"
fi

echo "reload_failed_restored rollback works."
