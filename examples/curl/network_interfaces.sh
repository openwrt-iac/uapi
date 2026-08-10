#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v3}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with network:interfaces:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# List existing interfaces"
req "$UAPI_BASE/network/interfaces" | head -c 400; echo

echo
echo "# Create a static IPv4 interface on br-guest"
created=$(req -H "$H_JSON" -X POST "$UAPI_BASE/network/interfaces" -d '{
	"device": "br-guest",
	"proto": "static",
	"ipaddrs": ["192.168.40.1"],
	"netmask": "255.255.255.0"
}')
echo "$created"
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
echo "# New id: $id"

echo
echo "# Read it back"
req "$UAPI_BASE/network/interfaces/$id"; echo

echo
echo "# Adjust gateway via PATCH"
req -H "$H_JSON" -X PATCH "$UAPI_BASE/network/interfaces/$id" -d '{"gateway": "192.168.40.254"}'; echo

echo
echo "# To delete:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/network/interfaces/$id\""
