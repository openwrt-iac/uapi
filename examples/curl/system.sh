#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE}"
: "${UAPI_TOKEN:?set UAPI_TOKEN with system:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'
req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# Current system config"
req "$UAPI_BASE/system"; echo

echo
echo "# Update hostname"
req -H "$H_JSON" -X PATCH "$UAPI_BASE/system" -d '{"hostname":"router-1"}'; echo

echo
echo "# Verify"
req "$UAPI_BASE/system" | sed -n 's/.*"hostname": *"\([^"]*\)".*/  hostname: \1/p'
