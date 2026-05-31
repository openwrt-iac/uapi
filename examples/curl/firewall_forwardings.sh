#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v1}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with firewall:forwardings:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# Allow lan -> wan forwarding (the default policy on most routers)"
created=$(req -H "$H_JSON" -X POST "$UAPI_BASE/firewall/forwardings" -d '{
	"src": "lan",
	"dest": "wan",
	"family": "any",
	"enabled": true
}')
echo "$created"
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')

echo
echo "# Read it back"
req "$UAPI_BASE/firewall/forwardings/$id"; echo

echo
echo "# To delete:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/firewall/forwardings/$id\""
