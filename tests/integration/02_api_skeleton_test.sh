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
# handler drops the rest of the body. At 512 KB per second, most of 1 MiB arrives after the 413
# is decided. curl stops sending and opens a new connection when the answer comes before the end
# of the body, so the second request must reuse the first connection. The body is not spaces,
# which uhttpd skips in front of a request line.
head -c 1048576 /dev/zero | tr '\0' a > "$body"
s=$(curl -sS -o /dev/null -w '%{http_code} ' --limit-rate 512k -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" --data-binary @"$body" \
	--next -o /dev/null -w '%{http_code} %{num_connects}' "$URL/healthz")
[ "$s" = "413 200 0" ] || fail "a body of 1 MiB at 512 KB/s, then GET /healthz on the same connection, expected 413 200 0, got $s"

echo "--- a body sent to /healthz is dropped, and the connection stays in step ---"
s=$(curl -sS -o /dev/null -w '%{http_code} ' --limit-rate 512k -X POST "$URL/healthz" --data-binary @"$body" \
	--next -o /dev/null -w '%{http_code} %{num_connects}' "$URL/healthz")
[ "$s" = "405 200 0" ] || fail "a POST of 1 MiB at 512 KB/s to /healthz, then GET /healthz on the same connection, expected 405 200 0, got $s"

echo "--- a chunked body is read, and one over 256 KiB answers 413 with the connection in step ---"
# uhttpd passes a chunked body with no Content-Length, and the handler read none of it. A POST
# with no body answers 422 too, so the check names the error on target.
r=$(curl -sS -w '\n%{http_code}' -H "$ADMIN" -H 'Content-Type: application/json' -H 'Transfer-Encoding: chunked' \
	-X POST "$URL/firewall/rules" --data-binary '{"name": "uapi-chunked", "target": "uapi-no-such-target"}')
[ "$(printf '%s\n' "$r" | tail -1)" = 422 ] \
	&& printf '%s\n' "$r" | sed '$d' | jq -e 'any(.errors[]; .field == "target" and .code == "not_in_enum")' >/dev/null \
	|| fail "a chunked POST with an unknown target expected 422 not_in_enum on target: $r"
s=$(curl -sS -o /dev/null -w '%{http_code} ' --limit-rate 512k -H 'Content-Type: application/json' \
	-H 'Transfer-Encoding: chunked' -X POST "$URL/firewall/rules" --data-binary @"$body" \
	--next -o /dev/null -w '%{http_code} %{num_connects}' "$URL/healthz")
[ "$s" = "413 200 0" ] || fail "a chunked body of 1 MiB at 512 KB/s, then GET /healthz on the same connection, expected 413 200 0, got $s"

echo "--- a POST with no body answers while uhttpd queues it ---"
# uhttpd runs at most max_requests handlers and queues the rest, and it never closes the pipe of
# a queued request without a body. A handler that read such a body to its end waited for the
# script timeout and answered 502.
slots=$($SSH 'uci -q get uhttpd.main.max_requests' || echo 3)
printf '{"name": "%s", "target": "uapi-no-such-target"}' "$(head -c 4000 /dev/zero | tr '\0' a)" > "$body"
for i in $(seq "$slots"); do
	curl -sS -o /dev/null --limit-rate 1k -X POST "$URL/firewall/rules" --data-binary @"$body" &
done
sleep 1
s=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -H "$ADMIN" -X POST "$URL/firewall/rules" || true)
wait
[ "$s" = 422 ] || fail "a POST with no body behind $slots slow requests expected 422, got $s"

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
