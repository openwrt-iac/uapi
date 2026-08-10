#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
fail() { echo "FAIL: $*"; exit 1; }

echo "--- uapi-token create mints a bearer + records the token under its name ---"
bearer=$($SSH "uapi-token create --name lifecycle_test --scope 'system:ro' 2>/dev/null" | head -1)
[ -n "$bearer" ] || fail "create produced no bearer"
echo "  bearer length: ${#bearer}"

echo "--- uapi-token list shows the new token with its scopes ---"
listing=$($SSH "uapi-token list" 2>&1)
echo "$listing"
echo "$listing" | grep -q '^lifecycle_test	scopes=system:ro$' \
	|| fail "list missing the lifecycle_test row"

echo "--- uapi-token show prints scopes for the named token ---"
shown=$($SSH "uapi-token show lifecycle_test" 2>&1)
echo "$shown"
echo "$shown" | grep -q '^name: lifecycle_test$' || fail "show missing name"
echo "$shown" | grep -q '^  - system:ro$' || fail "show missing scope"

echo "--- the bearer authenticates GET /system (within its scope) ---"
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $bearer" "$URL/system")
[ "$status" = "200" ] || fail "GET /system with new bearer expected 200, got $status"

echo "--- the bearer is denied a write (scope is read-only) ---"
status=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH -H "Authorization: Bearer $bearer" \
	-H 'Content-Type: application/json' "$URL/system" -d '{"hostname":"nope"}')
[ "$status" = "403" ] || fail "PATCH /system with ro bearer expected 403, got $status"

echo "--- creating a token with an existing name fails ---"
if $SSH "uapi-token create --name lifecycle_test --scope 'system:ro' 2>&1" | grep -q 'already exists'; then
	echo "  duplicate name rejected"
else
	fail "duplicate name was not rejected"
fi

echo "--- creating with an unknown scope fails without --force ---"
if $SSH "uapi-token create --name bogus_scope --scope 'bogus:rw' 2>&1" | grep -qiE 'unknown|invalid|not'; then
	echo "  unknown scope rejected"
else
	fail "unknown scope was not rejected"
fi

echo "--- --force lets an unknown scope through (forward-compat with future endpoints) ---"
$SSH "uapi-token create --name future_scope --scope 'future_endpoint:rw' --force 2>/dev/null" \
	| head -1 | grep -q '^[a-f0-9]*$' || fail "--force did not allow unknown scope"

echo "--- revoking propagates immediately: same bearer no longer authenticates ---"
$SSH "uapi-token revoke lifecycle_test 2>&1" | grep -q 'Revoked' || fail "revoke did not report success"
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $bearer" "$URL/system")
[ "$status" = "401" ] || fail "revoked bearer expected 401, got $status"

echo "--- revoking a nonexistent token fails ---"
if $SSH "uapi-token revoke not_a_real_token 2>&1" | grep -q 'not found'; then
	echo "  nonexistent revoke rejected"
else
	fail "revoke of nonexistent token was not rejected"
fi

echo "--- list no longer shows the revoked token ---"
$SSH "uapi-token list" 2>&1 | grep -q '^lifecycle_test' \
	&& fail "revoked token still in list" || echo "  list updated"

# Cleanup the test-leftover token
$SSH "uapi-token revoke future_scope 2>/dev/null" || true

echo "token lifecycle CLI + revocation propagation ok."
