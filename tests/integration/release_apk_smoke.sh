#!/bin/sh
set -eu

APK_PATH=${1:-}
OLD_APK=${2:-}
[ -n "$APK_PATH" ] || { echo "usage: $0 <path-to-uapi.apk> [<path-to-uapi-3.2.0-or-earlier.apk>]"; exit 1; }
[ -f "$APK_PATH" ] || { echo "no such file: $APK_PATH"; exit 1; }
[ -z "$OLD_APK" ] || [ -f "$OLD_APK" ] || { echo "no such file: $OLD_APK"; exit 1; }

SSH="tests/vm/ssh.sh"
URL=http://127.0.0.1:8080/api/v3

fail() { echo "FAIL: $*"; exit 1; }

# The package ships no token store, so its conffiles entry reaches sysupgrade through
# /lib/upgrade/keep.d/uapi rather than conffiles_static. base-files keeps all of /etc/config/ too.
assert_store_kept() {
	$SSH 'test -f /etc/config/uapi' || fail "/etc/config/uapi is missing $1"
	$SSH 'test "$(find /etc/config/uapi -perm 600)" = /etc/config/uapi' || fail "/etc/config/uapi is not mode 0600 $1"
	$SSH 'test ! -e /etc/config/uapi.apk-new' || fail "/etc/config/uapi.apk-new exists $1"
	$SSH 'grep -qx /etc/config/uapi /lib/upgrade/keep.d/uapi' || fail "/lib/upgrade/keep.d/uapi does not name the token store $1"
	$SSH 'sysupgrade -l | grep -qx /etc/config/uapi' || fail "sysupgrade -l does not list the token store $1"
}

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

echo "--- post-install: the hook created the token store from the template ---"
assert_store_kept "after a fresh install"
$SSH 'cmp /etc/config/uapi /usr/share/uapi/config.template' || fail "/etc/config/uapi is not the template"
$SSH 'uapi-token list' || fail "uapi-token list failed on a store without tokens"

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

echo "--- token store preserved across reinstall (apk add same package over itself) ---"
$SSH 'cp /etc/config/uapi /tmp/uapi.conf.before'
$SSH 'apk add --allow-untrusted --force-reinstall /tmp/uapi.apk 2>&1 | tail -5 || apk add --allow-untrusted /tmp/uapi.apk 2>&1 | tail -5'
$SSH 'test -f /etc/config/uapi' || fail "/etc/config/uapi vanished on reinstall"
$SSH 'test ! -e /etc/config/uapi.apk-new' || fail "/etc/config/uapi.apk-new exists after reinstall"
$SSH 'cmp /etc/config/uapi /tmp/uapi.conf.before' \
	|| fail "/etc/config/uapi changed on reinstall"
reinstall_check=$(curl -sS -H "Authorization: Bearer $ADMIN_TOKEN" -w "\n%{http_code}" "$URL/system")
echo "$reinstall_check" | tail -1 | grep -q '^200$' \
	|| fail "token from before reinstall no longer works"
$SSH 'rm -f /tmp/uapi.conf.before'

echo "--- a missing token store: no token authenticates, and a create makes it again ---"
$SSH 'mv /etc/config/uapi /tmp/uapi.store'
missing=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $ADMIN_TOKEN" "$URL/system")
[ "$missing" = "401" ] || fail "GET /system without a store expected 401, got $missing"
$SSH 'uapi-token list' || fail "uapi-token list failed without a store"
$SSH 'uapi-token create --name missing --scope "*:ro" >/dev/null 2>&1' || fail "uapi-token create failed without a store"
$SSH 'test "$(find /etc/config/uapi -perm 600)" = /etc/config/uapi' || fail "uapi-token create made a store that is not mode 0600"
$SSH 'mv /tmp/uapi.store /etc/config/uapi'

echo "--- apk remove cleans up the uhttpd prefix ---"
$SSH 'apk del uapi 2>&1 | tail -5'
$SSH 'uci show uhttpd.main.ucode_prefix' 2>/dev/null | grep '/api/v3=' && fail "ucode_prefix still wired after removal" || true
echo "  prefix removed"

echo "--- /etc/config/uapi preserved across remove ---"
$SSH 'test -f /etc/config/uapi' || fail "/etc/config/uapi disappeared on remove"

# Up to 3.2.0 the package shipped /etc/config/uapi, so the upgrade from such a release is where apk
# can delete the token store. It runs with tokens, with the store as shipped, and with --purge.
from_old() {
	$SSH 'apk del uapi >/dev/null 2>&1; rm -f /etc/config/uapi /etc/config/uapi.apk-new'
	$SSH 'apk add --allow-untrusted /tmp/uapi-old.apk 2>&1 | tail -5'
	$SSH 'apk info -W /etc/config/uapi | grep -q "owned by uapi-"' \
		|| fail "$(basename "$OLD_APK") does not ship /etc/config/uapi"
}

if [ -n "$OLD_APK" ]; then
	push_file "$OLD_APK" /tmp/uapi-old.apk

	echo "--- upgrade from $(basename "$OLD_APK") keeps the tokens and removes the .apk-new ---"
	from_old
	OLD_TOKEN=$($SSH 'uapi-token create --name upgrade --scope "*:ro"' 2>/dev/null | head -1)
	[ -n "$OLD_TOKEN" ] || fail "uapi-token create of the old release produced no token"
	$SSH 'touch /etc/config/uapi.apk-new && cp /etc/config/uapi /tmp/uapi.conf.before'
	$SSH 'apk add --allow-untrusted /tmp/uapi.apk 2>&1 | tail -5'
	$SSH 'cmp /etc/config/uapi /tmp/uapi.conf.before' || fail "the upgrade changed /etc/config/uapi"
	assert_store_kept "after the upgrade with tokens"
	upgraded=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $OLD_TOKEN" "$URL/system")
	[ "$upgraded" = "200" ] || fail "a token of the old release expected 200 after the upgrade, got $upgraded"

	echo "--- upgrade from $(basename "$OLD_APK") with the store as shipped: apk deletes it, the hook creates it ---"
	from_old
	$SSH 'apk add --allow-untrusted /tmp/uapi.apk 2>&1 | tail -5'
	assert_store_kept "after the upgrade with the store as shipped"
	$SSH 'cmp /etc/config/uapi /usr/share/uapi/config.template' || fail "/etc/config/uapi is not the template"

	echo "--- upgrade from $(basename "$OLD_APK") with --purge loses the tokens ---"
	from_old
	$SSH 'uapi-token create --name purged --scope "*:ro" >/dev/null 2>&1'
	$SSH 'apk --purge add --allow-untrusted /tmp/uapi.apk 2>&1 | tail -5'
	$SSH 'cmp /etc/config/uapi /usr/share/uapi/config.template' || fail "the store kept its tokens through --purge"

	$SSH 'rm -f /tmp/uapi.conf.before /tmp/uapi-old.apk'
fi

echo "release apk smoke ok"
