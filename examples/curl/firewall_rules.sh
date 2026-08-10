#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v3}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with firewall:rules:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# List existing rules"
req "$UAPI_BASE/firewall/rules" | head -c 400; echo

echo
echo "# Create a rule allowing SSH from wan"
created=$(req -H "$H_JSON" -X POST "$UAPI_BASE/firewall/rules" -d '{
	"name": "Allow-SSH-from-WAN",
	"target": "ACCEPT",
	"enabled": true,
	"match": { "src_zone": "wan", "dest_port": ["22"], "proto": ["tcp"] }
}')
echo "$created"
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
echo
echo "# New id: $id"

echo
echo "# Read it back"
req "$UAPI_BASE/firewall/rules/$id"; echo

echo
echo "# Disable it via PATCH"
req -H "$H_JSON" -X PATCH "$UAPI_BASE/firewall/rules/$id" -d '{"enabled": false}'; echo

echo
echo "# To delete:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/firewall/rules/$id\""
