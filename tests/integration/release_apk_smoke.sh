#!/bin/sh
set -eu

APK_PATH=${1:-}
[ -n "$APK_PATH" ] || { echo "usage: $0 <path-to-uapi.apk>"; exit 1; }
[ -f "$APK_PATH" ] || { echo "no such file: $APK_PATH"; exit 1; }

SSH="tests/vm/ssh.sh"
SCP_KEY="-i tests/vm/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
URL=http://127.0.0.1:8080/api/v3

fail() { echo "FAIL: $*"; exit 1; }

push_file() { $SSH "cat > $2" < "$1"; }

echo "--- push apk into the VM ---"
push_file "$APK_PATH" /tmp/uapi.apk

echo "--- mark the VM insecure for non-localhost testing ---"
$SSH 'touch /etc/uapi.insecure'

echo "--- apk add the uapi package ---"
$SSH 'apk add --allow-untrusted /tmp/uapi.apk 2>&1 | tail -10'

echo "--- post-install: uci-defaults should have wired the prefix and removed itself ---"
$SSH 'uci show uhttpd.main.ucode_prefix' | grep -q '/api/v3=/usr/share/uapi/main.uc' \
	|| fail "ucode_prefix not wired by uci-defaults"
$SSH 'test ! -e /etc/uci-defaults/99-uapi' || fail "uci-defaults script was not removed after running"

echo "--- /api/v3/healthz reachable ---"
healthz=$(curl -sS -w "\n%{http_code}" "$URL/healthz")
echo "$healthz"
echo "$healthz" | tail -1 | grep -q '^200$' || fail "healthz expected 200"

echo "--- mint a token and curl a curated endpoint ---"
ADMIN_TOKEN=$($SSH 'uapi-token create --name smoke --scope "*:rw"' 2>/dev/null | head -1)
[ -n "$ADMIN_TOKEN" ] || fail "uapi-token create produced no token"
echo "  token length: ${#ADMIN_TOKEN}"

sys=$(curl -sS -H "Authorization: Bearer $ADMIN_TOKEN" -w "\n%{http_code}" "$URL/system")
echo "$sys" | tail -1 | grep -q '^200$' || fail "GET /system expected 200"
echo "$sys" | grep -q '"hostname"' || fail "GET /system missing hostname field"

echo "--- openapi.json reachable ---"
oa=$(curl -sS -o /dev/null -w "%{http_code}" "$URL/openapi.json")
[ "$oa" = "200" ] || fail "openapi.json expected 200, got $oa"

echo "--- conffile preserved across reinstall (apk add same package over itself) ---"
$SSH 'cp /etc/config/uapi /tmp/uapi.conf.before'
$SSH 'apk add --allow-untrusted --force-reinstall /tmp/uapi.apk 2>&1 | tail -5 || apk add --allow-untrusted /tmp/uapi.apk 2>&1 | tail -5'
$SSH 'test -f /etc/config/uapi' || fail "/etc/config/uapi vanished on reinstall"
$SSH 'cmp /etc/config/uapi /tmp/uapi.conf.before' \
	|| fail "/etc/config/uapi changed on reinstall (conffile mark not honored)"
reinstall_check=$(curl -sS -H "Authorization: Bearer $ADMIN_TOKEN" -w "\n%{http_code}" "$URL/system")
echo "$reinstall_check" | tail -1 | grep -q '^200$' \
	|| fail "token from before reinstall no longer works"
$SSH 'rm -f /tmp/uapi.conf.before'

echo "--- apk remove cleans up the uhttpd prefix ---"
$SSH 'apk del uapi 2>&1 | tail -5'
$SSH 'uci show uhttpd.main.ucode_prefix' 2>/dev/null | grep '/api/v3=' && fail "ucode_prefix still wired after removal" || true
echo "  prefix removed"

echo "--- /etc/config/uapi conffile preserved across remove ---"
$SSH 'test -f /etc/config/uapi' || fail "/etc/config/uapi disappeared on remove (should be conffile-preserved)"

echo "release apk smoke ok"
