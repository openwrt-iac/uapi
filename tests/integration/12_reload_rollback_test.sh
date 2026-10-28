#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# Inject a one-shot failure into the firewall reload path by wrapping fw4. The
# /etc/init.d/firewall script invokes fw4 reload; failing once via a marker file
# triggers exactly the path documented in CLAUDE.md "Atomic transaction recipe"
# step 6: first reload fails, snapshot-restore reloads succeeds, response is
# 500 reload_failed_restored, uci is back to the pre-write snapshot.
# The VM ships a stub /etc/init.d/firewall (from tests/vm/setup.sh) that honors
# /tmp/fw-fail-once: when present, reload_service consumes the marker and
# returns 1 on this single reload, then returns 0 on subsequent calls.
cleanup() {
	$SSH 'rm -f /tmp/fw-fail-once
	      rmdir /etc/config/.firewall.uapi-restore 2>/dev/null
	      if [ -f /tmp/uapi-fw-before ]; then
	          cp -p /tmp/uapi-fw-before /etc/config/firewall && rm -f /tmp/uapi-fw-before
	      fi' || true
}
trap cleanup EXIT INT TERM

echo "--- snapshot uci firewall state before the failing write ---"
before=$($SSH 'uci export firewall')
mode_before=$($SSH 'ls -l /etc/config/firewall' | cut -c1-10)

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

echo "--- the restore replaced the file by a rename and left no temp file ---"
if $SSH 'ls -a /etc/config' | grep -q 'uapi-restore'; then
	fail "the restore left its temp file in /etc/config"
fi
[ "$($SSH 'ls -l /etc/config/firewall' | cut -c1-10)" = "$mode_before" ] \
	|| fail "the restore changed the mode of /etc/config/firewall"

echo "reload_failed_restored rollback works."

# A directory in the place of the restore's temp file makes the restore fail before it touches
# the package, as a full overlay does to its write. The restore wrote over the file in place and
# checked nothing, so a full overlay left the package cut short behind reload_failed_restored.
echo "--- a restore that cannot write answers reload_failed_unrecovered and names the file ---"
$SSH 'cp -p /etc/config/firewall /tmp/uapi-fw-before &&
      mkdir /etc/config/.firewall.uapi-restore &&
      touch /tmp/fw-fail-once'
resp=$(curl -sS -w "\n%{http_code}" -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" -d '{
	"target": "ACCEPT",
	"match": { "src_zone": "lan", "dest_port": ["9998"], "proto": ["tcp"] }
}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
echo "$body" | head -20
[ "$status" = "500" ] || fail "expected 500 reload_failed_unrecovered, got $status"
echo "$body" | grep -q '"code": "reload_failed_unrecovered"' || fail "expected reload_failed_unrecovered code"
echo "$body" | grep -q 'restore of /etc/config/firewall: cannot create /etc/config/.firewall.uapi-restore' \
	|| fail "the restore_error does not name the package file"
$SSH 'uci -q show firewall >/dev/null' || fail "the package no longer parses after the failed restore"

echo "a failed restore is reported as unrecovered and leaves the package whole."
