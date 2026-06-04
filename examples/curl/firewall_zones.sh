#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE}"
: "${UAPI_TOKEN:?set UAPI_TOKEN with firewall:zones:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'
req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# Existing zones"
req "$UAPI_BASE/firewall/zones" | head -c 400; echo

echo
echo "# Create a zone"
created=$(req -H "$H_JSON" -X POST "$UAPI_BASE/firewall/zones" -d '{
	"name": "iot",
	"input": "REJECT",
	"output_policy": "ACCEPT",
	"forward": "REJECT",
	"network": ["iot"]
}')
echo "$created"
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
echo
echo "# New id: $id"

echo
echo "# To delete:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/firewall/zones/$id\""
