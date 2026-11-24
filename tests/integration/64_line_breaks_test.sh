#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v4
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

trap "$SSH 'uapi-token revoke line_breaks_ro' >/dev/null 2>&1 || true" EXIT INT TERM

# curl refuses a line break in a URL or a header, so this sends the request as it is. Each `\n` in
# the arguments is a line feed.
raw_get() {
	python3 - "$1" "$2" <<'PY'
import socket, sys
path, header = (a.replace("\\n", "\n") for a in sys.argv[1:3])
s = socket.create_connection(("127.0.0.1", 8080), timeout=30)
s.sendall(("GET /api/v4" + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n" + header
           + "\r\nConnection: close\r\n\r\n").encode())
out = b""
while True:
    b = s.recv(65536)
    if not b:
        break
    out += b
print(out.decode(errors="replace"))
PY
}

echo "--- a GET whose path holds a line feed answers 400 bad_request ---"
ro=$($SSH "uapi-token create --name line_breaks_ro --scope 'packages:installed:ro' 2>/dev/null" | head -1)
[ -n "$ro" ] || fail "no bearer for the read-only token"
r=$(raw_get '/packages/installed/ucode\nx' "Authorization: Bearer $ro")
echo "$r" | head -1 | grep -q '^HTTP/1.1 400' || fail "expected 400, got: $(echo "$r" | head -1)"
echo "$r" | grep -q '"code": "bad_request"' || fail "expected bad_request: $r"
echo "$r" | grep -q 'newline or a carriage return in the path' || fail "expected the path to be named: $r"

echo "--- the same GET without the line feed still answers ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ro" "$URL/packages/installed/ucode")
[ "$status" = "200" ] || fail "GET packages/installed/ucode expected 200, got $status"

echo "--- ?request_id= with %0A answers 400 under a request id of the server ---"
curl -sS -D /tmp/uapi_lb_headers -o /tmp/uapi_lb_body "$URL/healthz?request_id=abcdefgh%0Aijklmnop" || true
head -1 /tmp/uapi_lb_headers | grep -q ' 400' || fail "expected 400, got: $(head -1 /tmp/uapi_lb_headers)"
grep -q '"code": "bad_request"' /tmp/uapi_lb_body || fail "expected bad_request: $(cat /tmp/uapi_lb_body)"
tr -d '\r' < /tmp/uapi_lb_headers | grep -qi '^X-Request-Id: [0-9a-z]\{26\}$' \
	|| fail "expected a generated request id: $(cat /tmp/uapi_lb_headers)"
! grep -q 'abcdefgh\|ijklmnop' /tmp/uapi_lb_headers /tmp/uapi_lb_body || fail "the request id was echoed"

echo "--- a valid ?request_id= is still echoed ---"
curl -sS -D /tmp/uapi_lb_headers -o /dev/null "$URL/healthz?request_id=abcdefgh12" || true
grep -qi '^X-Request-Id: abcdefgh12' /tmp/uapi_lb_headers || fail "expected the request id echoed: $(cat /tmp/uapi_lb_headers)"

# uhttpd itself refuses some of these header lines with its own 400, before uapi sees them.
echo "--- an X-Request-Id header that holds a line feed answers 400 and is not echoed ---"
r=$(raw_get '/healthz' 'X-Request-Id: abcdefgh\nX-Line-Two: ijklmnop')
echo "$r" | head -1 | grep -q '^HTTP/1.1 400' || fail "expected 400, got: $(echo "$r" | head -1)"
! echo "$r" | grep -q 'ijklmnop' || fail "the request id was echoed: $r"

echo "--- a body of more than 2000 lines is not counted as containers ---"
{ printf '{"target": "BOGUS"'; i=0; while [ $i -lt 2100 ]; do printf '\n'; i=$((i + 1)); done; printf '}'; } > /tmp/uapi_lb_lines.json
status=$(curl -sS -o /tmp/uapi_lb_body -w '%{http_code}' -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" --data-binary @/tmp/uapi_lb_lines.json)
[ "$status" = "422" ] || fail "expected 422 for a body of many lines, got $status: $(cat /tmp/uapi_lb_body)"

echo "PASS"
