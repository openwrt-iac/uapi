#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v3}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with uhttpd:instances:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# Read the 'main' uhttpd instance"
req "$UAPI_BASE/uhttpd/instances/main"; echo

echo
echo "# DANGER: writes to the 'main' instance that strip /api/v3=/usr/share/uapi/main.uc"
echo "# from ucode_prefix are rejected with 422 conflict (self-lockout protection)."
echo
# Writing this instance restarts the server that is answering the request, so curl usually
# reports "Empty reply from server" (exit 52) even though the write committed. That is uhttpd
# closing the connection mid-response, not a failure, which is why the exit status is tolerated
# here and the result is confirmed by reading the instance back afterwards.
echo "# Example: PATCH that keeps the uapi entry and re-states the listen addresses"
req -H "$H_JSON" -X PATCH "$UAPI_BASE/uhttpd/instances/main" -d '{
	"listen_http": ["0.0.0.0:80", "[::]:80"],
	"listen_https": ["0.0.0.0:443", "[::]:443"],
	"ucode_prefix": ["/api/v3=/usr/share/uapi/main.uc"]
}' || echo "(connection dropped: uhttpd restarted, see below)"
echo

echo "# Read it back once uhttpd is listening again"
for _ in 1 2 3 4 5 6 7 8 9 10; do
	sleep 1
	req --max-time 5 "$UAPI_BASE/uhttpd/instances/main" && break
done
echo
