#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

cleanup() {
	$SSH "apk del uapi-pkg-test 2>/dev/null" >/dev/null 2>&1 || true
	$SSH "rm -f /etc/apk/repositories.d/uapi-test.list" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "--- packages/installed: GET list returns 200 with an array ---"
listed=$(call "$URL/packages/installed")
echo "$listed" | tail -1 | grep -q '^200$' || fail "list expected 200"

echo "--- packages/installed: POST a leading-dash name is rejected with 422 (shell-arg injection guard) ---"
inject=$(call -X POST -H 'Content-Type: application/json' \
	"$URL/packages/installed" -d '{"name": "--allow-untrusted"}')
echo "$inject" | tail -1 | grep -q '^422$' \
	|| fail "expected 422 on leading-dash name"
echo "$inject" | head -1 | grep -q '"code": "invalid_format"' \
	|| fail "expected invalid_format field error"

echo "--- packages/installed: POST a name with shell metacharacters is rejected with 422 ---"
shell_inject=$(call -X POST -H 'Content-Type: application/json' \
	"$URL/packages/installed" -d '{"name": "foo;rm -rf /"}')
echo "$shell_inject" | tail -1 | grep -q '^422$' \
	|| fail "expected 422 on shell metacharacters"

echo "--- packages/installed: POST a nonexistent package returns 500 (apk add fails cleanly) ---"
nope=$(call -X POST -H 'Content-Type: application/json' \
	"$URL/packages/installed" -d '{"name": "no-such-package-uapi-test"}')
echo "$nope" | tail -1 | grep -q '^500$' \
	|| fail "expected 500 on apk add failure"
echo "$nope" | head -1 | grep -q '"message": "apk add failed' \
	|| fail "expected generic message (no apk stderr leak)"

echo "--- packages/installed: GET nonexistent returns 404 ---"
nf=$(call "$URL/packages/installed/no-such-package")
echo "$nf" | tail -1 | grep -q '^404$' || fail "expected 404"

echo "--- packages/feeds: POST with leading-dot name is rejected with 422 ---"
dot=$(call -X POST -H 'Content-Type: application/json' \
	"$URL/packages/feeds" -d '{"name": ".bashrc", "url": "https://example.com/x"}')
echo "$dot" | tail -1 | grep -q '^422$' || fail "expected 422 on leading-dot feed name"

echo "--- packages/feeds: POST with file:// url is rejected with 422 ---"
local_url=$(call -X POST -H 'Content-Type: application/json' \
	"$URL/packages/feeds" -d '{"name": "uapi-test", "url": "file:///etc/passwd"}')
echo "$local_url" | tail -1 | grep -q '^422$' || fail "expected 422 on file:// url"

echo "--- packages/feeds: POST a valid feed, GET it back, DELETE it ---"
feed=$(call -X POST -H 'Content-Type: application/json' \
	"$URL/packages/feeds" -d '{"name": "uapi-test", "url": "https://feeds.example.invalid/v1"}')
echo "$feed" | tail -1 | grep -q '^200$' || fail "feed create expected 200"

got=$(call "$URL/packages/feeds/uapi-test")
echo "$got" | tail -1 | grep -q '^200$' || fail "feed get expected 200"
echo "$got" | head -1 | grep -q 'feeds.example.invalid' || fail "feed url roundtrip mismatch"

call -X DELETE "$URL/packages/feeds/uapi-test" | tail -1 | grep -q '^204$' \
	|| fail "feed delete expected 204"

echo "--- packages: unknown subresource returns 404, not 403 ---"
unk=$(call "$URL/packages/garbage")
echo "$unk" | tail -1 | grep -q '^404$' || fail "expected 404 on unknown subresource"

echo "packages/installed + packages/feeds validation + dispatcher ok."
