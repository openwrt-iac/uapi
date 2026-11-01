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
	$SSH 'rm -f /tmp/fw-fail-once /tmp/fw-run-once
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

# A reload that did not end held the request and its locks until uhttpd killed it at its 60 s
# script timeout: the client got 502, and uci kept the new config with no restore. uapi now stops
# waiting after 20 s and does not kill it, since its child keeps the procd lock of the service.
echo "--- a reload that does not end answers unverified after 20 s, and keeps the commit ---"
$SSH "printf '%s\n' 'sleep 25' >/tmp/fw-run-once"
start=$(date +%s)
resp=$(curl -sS -m 70 -D - -w "\n%{http_code}" -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" -d '{
	"target": "ACCEPT",
	"match": { "src_zone": "lan", "dest_port": ["9997"], "proto": ["tcp"] }
}')
took=$(($(date +%s) - start))
status=$(printf '%s\n' "$resp" | tail -1)
printf '%s\n' "$resp" | tr -d '\r' | grep -i '^X-Reload-Status:' || true
[ "$status" = "200" ] || fail "expected 200 after a hung reload, got $status after ${took}s"
printf '%s\n' "$resp" | tr -d '\r' | grep -qi '^X-Reload-Status: unverified$' \
	|| fail "expected X-Reload-Status: unverified after a hung reload"
[ "$took" -ge 19 ] && [ "$took" -lt 30 ] || fail "the write answered after ${took}s, not after the 20 s"
id=$(printf '%s\n' "$resp" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$id" ] || fail "no id in the answer of the hung write"
$SSH 'uci show firewall' | grep -q "'9997'" || fail "the write did not keep its commit"
echo "--- the next write is not refused while that reload still runs ---"
resp=$(curl -sS -m 70 -w "\n%{http_code}" -H "$ADMIN" -X DELETE "$URL/firewall/rules/$id")
status=$(printf '%s\n' "$resp" | tail -1)
[ "$status" = "204" ] || fail "the DELETE after the hung reload answered $status"
if $SSH 'uci show firewall' | grep -q "'9997'"; then fail "the DELETE after the hung reload did not remove the rule"; fi
echo "a hung reload answers unverified after ${took}s and leaves the next write free."

# LuCI or a shell commits into the file that the request committed while the daemons reload, and the
# restore wrote back the snapshot from before both.
echo "--- a commit by another writer during the reload stays, and the write answers unrecovered ---"
$SSH "cp -p /etc/config/firewall /tmp/uapi-fw-before &&
      printf '%s\n' 'uci set firewall.uapi_other=rule; uci set firewall.uapi_other.name=other_writer; uci commit firewall' >/tmp/fw-run-once &&
      touch /tmp/fw-fail-once"
resp=$(curl -sS -m 70 -w "\n%{http_code}" -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" -d '{
	"target": "ACCEPT",
	"match": { "src_zone": "lan", "dest_port": ["9996"], "proto": ["tcp"] }
}')
status=$(printf '%s\n' "$resp" | tail -1)
body=$(printf '%s\n' "$resp" | sed '$d')
printf '%s\n' "$body" | head -20
[ "$status" = "500" ] || fail "expected 500 reload_failed_unrecovered, got $status"
printf '%s\n' "$body" | grep -q '"code": "reload_failed_unrecovered"' || fail "expected reload_failed_unrecovered code"
printf '%s\n' "$body" | grep -q 'another writer committed to the package firewall after the commit of the request' \
	|| fail "the restore_error does not name the package and the other writer"
[ "$($SSH 'uci -q get firewall.uapi_other.name')" = "other_writer" ] \
	|| fail "the restore undid the commit of the other writer"
$SSH 'uci show firewall' | grep -q "'9996'" || fail "the restore changed the file that the other writer left"
$SSH 'cp -p /tmp/uapi-fw-before /etc/config/firewall && rm -f /tmp/uapi-fw-before'
echo "a commit by another writer during the reload is kept and reported."

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
