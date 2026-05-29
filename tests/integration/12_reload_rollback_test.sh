#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# Replace the firewall init script with a one-shot failing handler so that:
# - first reload fails (consumes /tmp/fw-fail-once)
# - second reload (the snapshot-restore re-reload) succeeds
# This is precisely the reload_failed_restored path documented in CLAUDE.md.
echo "--- back up /etc/init.d/firewall and install a fail-once handler ---"
$SSH '
set -eu
cp /etc/init.d/firewall /etc/init.d/firewall.uapi-bak
cat > /etc/init.d/firewall <<EOF
#!/bin/sh /etc/rc.common
START=19
STOP=89
USE_PROCD=1
start_service() { :; }
reload_service() {
    if [ -f /tmp/fw-fail-once ]; then
        rm /tmp/fw-fail-once
        return 1
    fi
    return 0
}
EOF
chmod +x /etc/init.d/firewall
/etc/init.d/firewall restart
sleep 1
'

cleanup() {
	$SSH '
		mv -f /etc/init.d/firewall.uapi-bak /etc/init.d/firewall 2>/dev/null || true
		rm -f /tmp/fw-fail-once
		/etc/init.d/firewall restart 2>/dev/null || true
	' || true
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
