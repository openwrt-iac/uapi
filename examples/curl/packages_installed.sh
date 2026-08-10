#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v3}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with packages:installed:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# List currently installed packages (first 600 bytes)"
req "$UAPI_BASE/packages/installed" | head -c 600; echo

echo
echo "# Install sqm-scripts (apk add)"
req -H "$H_JSON" -X POST "$UAPI_BASE/packages/installed" -d '{"name": "sqm-scripts"}'; echo

echo
echo "# Confirm it shows up"
req "$UAPI_BASE/packages/installed/sqm-scripts"; echo

echo
echo "# To remove:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/packages/installed/sqm-scripts\""

echo
echo "# Note: package names must match ^[A-Za-z0-9_+][A-Za-z0-9_+.-]*\$"
echo "# Names starting with '-' or '.' are rejected with 422 invalid_format"
echo "# (apk flag-injection guard)."
