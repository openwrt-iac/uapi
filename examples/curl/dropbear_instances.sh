#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v2}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with dropbear:instances:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# List existing dropbear instances"
req "$UAPI_BASE/dropbear/instances" | head -c 600; echo

echo
echo "# Add a key-only dropbear on a non-default port, lan only"
created=$(req -H "$H_JSON" -X POST "$UAPI_BASE/dropbear/instances" -d '{
	"port": 2222,
	"password_auth": false,
	"root_password_auth": false,
	"root_login": true,
	"interface": "lan"
}')
echo "$created"
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')

echo
echo "# Read it back"
req "$UAPI_BASE/dropbear/instances/$id"; echo

echo
echo "# To delete:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/dropbear/instances/$id\""
