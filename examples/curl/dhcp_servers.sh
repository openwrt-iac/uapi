#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v1}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with dhcp:servers:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# List existing per-interface DHCP server sections"
req "$UAPI_BASE/dhcp/servers" | head -c 600; echo

echo
echo "# Create a server for a 'guest' interface"
created=$(req -H "$H_JSON" -X POST "$UAPI_BASE/dhcp/servers" -d '{
	"interface": "guest",
	"start": 100,
	"limit": 100,
	"leasetime": "1h",
	"ra": "server",
	"dhcpv6": "server"
}')
echo "$created"
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')

echo
echo "# Tighten the lease window via PATCH"
req -H "$H_JSON" -X PATCH "$UAPI_BASE/dhcp/servers/$id" -d '{"leasetime": "30m"}'; echo

echo
echo "# To delete:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/dhcp/servers/$id\""
