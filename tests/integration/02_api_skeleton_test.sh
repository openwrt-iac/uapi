#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"

fail() { echo "FAIL: $*"; exit 1; }

echo "--- GET /healthz ---"
healthz=$(curl -sS -w "\n%{http_code}\n" "$URL/healthz")
echo "$healthz"
echo "$healthz" | tail -1 | grep -q '^200$' || fail "healthz expected 200"
echo "$healthz" | grep -q '"status": "ok"' || fail "healthz body missing status:ok"
echo "$healthz" | grep -q '"version"' || fail "healthz body missing version"

echo "--- X-Request-Id header present ---"
hdrs=$(curl -sS -D - -o /dev/null "$URL/healthz")
echo "$hdrs" | grep -qi '^X-Request-Id:' || fail "missing X-Request-Id header"

echo "--- GET /unknown (authenticated) returns 404 not_found ---"
notfound=$(curl -sS -H "$ADMIN" -w "\n%{http_code}\n" "$URL/unknown")
echo "$notfound"
echo "$notfound" | tail -1 | grep -q '^404$' || fail "unknown path expected 404"
echo "$notfound" | grep -q '"code": "not_found"' || fail "404 body missing code"

echo "--- GET /unknown without auth returns 401 ---"
no_auth=$(curl -sS -w "\n%{http_code}\n" "$URL/unknown")
echo "$no_auth" | tail -1 | grep -q '^401$' || fail "no-auth unknown path expected 401"

echo "--- POST /healthz returns 405 ---"
bad_method=$(curl -sS -w "\n%{http_code}\n" -X POST "$URL/healthz")
echo "$bad_method"
echo "$bad_method" | tail -1 | grep -q '^405$' || fail "POST healthz expected 405"

# uci drops these when it replays the commit, and a NUL also cut an anchored id check short.
echo "--- a body with a NUL or a control byte answers 400 on a curated path too ---"
for body in '{"name":"a\u0000b"}' '{"k\u0000x":"1"}' '{"name":"a\u0001b"}'; do
	r=$(curl -sS -H "$ADMIN" -w "\n%{http_code}\n" -X POST -H 'Content-Type: application/json' \
		"$URL/firewall/rules" -d "$body")
	echo "$r" | tail -1 | grep -q '^400$' || fail "POST $body expected 400: $r"
done

# The 400 names the key before authentication, and the error ring keeps every message in tmpfs.
echo "--- an unauthenticated 400 with a long key leaves a clipped message in the error ring ---"
key=$(head -c 4000 /dev/zero | tr '\0' k)
r=$(curl -sS -w "\n%{http_code}\n" -X POST -H 'Content-Type: application/json' \
	"$URL/firewall/rules" -d "{\"$key\\u0001\":1}")
echo "$r" | tail -1 | grep -q '^400$' || fail "long-key POST expected 400: $(echo "$r" | tail -1)"
len=$(curl -sS -H "$ADMIN" "$URL/diagnostics" | jq '[.recent_errors[] | .message | length] | max')
[ "$len" -le 515 ] || fail "the error ring kept a message of $len bytes"

echo "--- a body that arrives in several parts is read whole ---"
# uhttpd.recv() stops at the first short read, so a body that curl sends at 32 KB per second always
# reached the handler cut and answered 400. A target that does not exist answers 422, which needs
# the whole body parsed.
body=/tmp/uapi_big_body.json
printf '{"name": "%s", "target": "uapi-no-such-target"}' "$(head -c 65536 /dev/zero | tr '\0' a)" > "$body"
for i in 1 2; do
	s=$(curl -sS -o /dev/null -w '%{http_code}' --limit-rate 32k -H "$ADMIN" -H 'Content-Type: application/json' \
		-X POST "$URL/firewall/rules" --data-binary @"$body")
	[ "$s" = 422 ] || fail "a 64 KB body sent in parts expected 422 at try $i, got $s"
done

echo "--- a body over 256 KiB answers 413 before the bearer check, and the connection stays in step ---"
# uhttpd parses what the handler leaves unread as the next request on the connection, so the
# handler drops the body. curl sends the second request on the same connection.
head -c 262145 /dev/zero | tr '\0' ' ' > "$body"
s=$(curl -sS -o /dev/null -w '%{http_code} ' -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" --data-binary @"$body" --next -o /dev/null -w '%{http_code}' "$URL/healthz")
[ "$s" = "413 200" ] || fail "a body of 256 KiB and 1 byte, then GET /healthz, expected 413 then 200, got $s"

echo "--- a body with more than 2000 objects and arrays answers 413 before the bearer check ---"
printf '[%s{}]' "$(yes '{},' | head -n 1998 | tr -d '\n')" > "$body"
s=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" --data-binary @"$body")
[ "$s" = 401 ] || fail "a body with 2000 objects and arrays without a token expected 401, got $s"
printf '[%s{}]' "$(yes '{},' | head -n 1999 | tr -d '\n')" > "$body"
s=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" --data-binary @"$body")
[ "$s" = 413 ] || fail "a body with 2001 objects and arrays without a token expected 413, got $s"
rm -f "$body"

echo "api skeleton ok"
