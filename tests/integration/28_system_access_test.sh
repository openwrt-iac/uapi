#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

# Snapshot /etc/dropbear/authorized_keys AND /etc/shadow for restore after the
# test. The .insecure marker keeps the API reachable for cleanup steps even if
# SSH key auth gets disrupted mid-test.
$SSH "touch /etc/dropbear/authorized_keys; cp -a /etc/dropbear/authorized_keys /tmp/uapi-test-keys.bak; cp -a /etc/shadow /tmp/uapi-test-shadow.bak"
cleanup() {
	$SSH "cat /tmp/uapi-test-keys.bak > /etc/dropbear/authorized_keys; rm -f /tmp/uapi-test-keys.bak" 2>/dev/null || true
	# Restore /etc/shadow (root password) so later tests in the same VM see
	# the original credentials. The integration tests use SSH key auth so the
	# password change wouldn't break them, but a future test exercising
	# password-based login would silently inherit the test password.
	$SSH "cat /tmp/uapi-test-shadow.bak > /etc/shadow; rm -f /tmp/uapi-test-shadow.bak" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "--- system/password: missing user/password -> 422 ---"
empty=$(call -X POST -H 'Content-Type: application/json' "$URL/system/password" -d '{}')
echo "$empty" | tail -1 | grep -q '^422$' || fail "expected 422 for empty body"

echo "--- system/password: shell-meta user -> 422 invalid_format ---"
inj=$(call -X POST -H 'Content-Type: application/json' "$URL/system/password" \
	-d '{"user": "root;rm -rf /", "password": "longenoughpw"}')
echo "$inj" | tail -1 | grep -q '^422$' || fail "expected 422 for shell-meta user"
echo "$inj" | head -1 | grep -q '"code": "invalid_format"' \
	|| fail "expected invalid_format for shell-meta user"

echo "--- system/password: short password -> 422 out_of_range ---"
short=$(call -X POST -H 'Content-Type: application/json' "$URL/system/password" \
	-d '{"user": "root", "password": "x"}')
echo "$short" | tail -1 | grep -q '^422$' || fail "expected 422 for short password"

echo "--- system/password: valid set on root -> 204 ---"
ok=$(call -X POST -H 'Content-Type: application/json' "$URL/system/password" \
	-d '{"user": "root", "password": "uapi-test-pw-1234"}')
echo "$ok" | tail -1 | grep -q '^204$' || fail "expected 204 for valid password set"

echo "--- system/password: audit line emitted to syslog (no password value) ---"
$SSH "logread | tail -200 | grep uapi-passwd-set" >/tmp/uapi_audit.txt 2>&1 || true
grep -q "uapi-passwd-set" /tmp/uapi_audit.txt || fail "no audit line for password set"
grep -q "uapi-test-pw-1234" /tmp/uapi_audit.txt && fail "password VALUE leaked to syslog"
rm -f /tmp/uapi_audit.txt

echo "--- system/authorized_keys: GET initial list (may be empty) ---"
init=$(call "$URL/system/authorized_keys")
echo "$init" | tail -1 | grep -q '^200$' || fail "list expected 200"

KEY1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE9k0xZJ0c5RT9YhqpQQfX9hyyExampleKey1AAAA= test-key-1'
KEY2='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDifferentKeyContentHereExampleKey2BB= test-key-2'

echo "--- system/authorized_keys: POST adds a key ---"
added=$(call -X POST -H 'Content-Type: application/json' "$URL/system/authorized_keys" \
	-d "{\"key\": \"$KEY1\"}")
echo "$added" | tail -1 | grep -q '^200$' || fail "add expected 200"
kid=$(echo "$added" | head -1 | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
[ -n "$kid" ] || fail "no id in add response"

echo "--- system/authorized_keys: GET single by id ---"
got=$(call "$URL/system/authorized_keys/$kid")
echo "$got" | tail -1 | grep -q '^200$' || fail "get by id expected 200"
echo "$got" | head -1 | grep -q '"id": "'"$kid"'"' || fail "id mismatch in single get"

echo "--- system/authorized_keys: POST same key again -> 409 conflict ---"
dup=$(call -X POST -H 'Content-Type: application/json' "$URL/system/authorized_keys" \
	-d "{\"key\": \"$KEY1\"}")
echo "$dup" | tail -1 | grep -q '^409$' || fail "expected 409 on duplicate add"

echo "--- system/authorized_keys: POST malformed key -> 422 ---"
bad=$(call -X POST -H 'Content-Type: application/json' "$URL/system/authorized_keys" \
	-d '{"key": "not a real key"}')
echo "$bad" | tail -1 | grep -q '^422$' || fail "expected 422 on malformed key"

echo "--- system/authorized_keys: DELETE removes the added key ---"
del=$(call -X DELETE "$URL/system/authorized_keys/$kid")
echo "$del" | tail -1 | grep -q '^204$' || fail "delete expected 204"

list2=$(call "$URL/system/authorized_keys")
echo "$list2" | head -1 | grep -q "\"id\": \"$kid\"" \
	&& fail "key $kid still listed after delete"

# Note: PUT (replace-all) is covered by unit tests; we deliberately don't
# exercise it here because the integration test's own SSH session relies on
# the injected SSH key in authorized_keys, and a wholesale replace would
# overwrite it and break the cleanup trap.

echo "--- system/authorized_keys: DELETE same id again -> 404 ---"
del2=$(call -X DELETE "$URL/system/authorized_keys/$kid")
echo "$del2" | tail -1 | grep -q '^404$' || fail "delete-after-delete expected 404"

echo "--- system/access: unknown subresource under /system/ falls through to existing routes ---"
# /system/timeservers is a curated resource; ensure it still works.
ts=$(call "$URL/system/timeservers")
echo "$ts" | tail -1 | grep -q '^200$' || fail "/system/timeservers regression"

echo "--- system/password: 5+ path segments under system/password -> 404 not_found ---"
oops=$(call "$URL/system/password/extra/path")
echo "$oops" | tail -1 | grep -q '^404$' || fail "expected 404 on extra path"

echo "system/password + system/authorized_keys ok."
