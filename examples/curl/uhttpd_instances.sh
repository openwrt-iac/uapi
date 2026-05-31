#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v1}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with uhttpd:instances:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# Read the 'main' uhttpd instance"
req "$UAPI_BASE/uhttpd/instances/main"; echo

echo
echo "# DANGER: writes to the 'main' instance that strip /api/v1=/usr/share/uapi/main.uc"
echo "# from ucode_prefix are rejected with 422 conflict (self-lockout protection)."
echo
echo "# Example: PATCH that keeps the uapi entry and adds another listen address"
req -H "$H_JSON" -X PATCH "$UAPI_BASE/uhttpd/instances/main" -d '{
	"listen_http": ["0.0.0.0:80", "[::]:80"],
	"listen_https": ["0.0.0.0:443", "[::]:443"],
	"ucode_prefix": ["/api/v1=/usr/share/uapi/main.uc"]
}'; echo
