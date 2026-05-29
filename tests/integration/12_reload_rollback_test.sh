#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# Inject a one-shot failure into the firewall reload path by wrapping fw4. The
# /etc/init.d/firewall script invokes fw4 reload; failing once via a marker file
# triggers exactly the path documented in CLAUDE.md "Atomic transaction recipe"
# step 6: first reload fails, snapshot-restore reloads succeeds, response is
# 500 reload_failed_restored, uci is back to the pre-write snapshot.
echo "--- locate the fw4 binary ---"
FW4=$($SSH 'command -v fw4 2>/dev/null || ls /usr/sbin/fw4 /sbin/fw4 /usr/libexec/fw4 2>/dev/null | head -1')
[ -n "$FW4" ] || { $SSH 'apk add firewall4 2>&1 | tail -5'; FW4=$($SSH 'command -v fw4'); }
[ -n "$FW4" ] || fail "fw4 not installed and apk add firewall4 failed"
echo "  fw4 at: $FW4"

echo "--- wrap fw4 with a fail-once handler ---"
$SSH "
set -eu
[ -f ${FW4}.uapi-bak ] || cp $FW4 ${FW4}.uapi-bak
cat > $FW4 <<'EOF'
#!/bin/sh
if [ \"\$1\" = \"reload\" ] && [ -f /tmp/fw-fail-once ]; then
    rm /tmp/fw-fail-once
    echo \"fw4: simulated reload failure\" >&2
    exit 1
fi
exec ${FW4}.uapi-bak \"\$@\"
EOF
chmod +x $FW4
"

cleanup() {
	$SSH "mv -f ${FW4}.uapi-bak $FW4 2>/dev/null || true; rm -f /tmp/fw-fail-once" || true
}
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
