#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE}"
: "${UAPI_TOKEN:?set UAPI_TOKEN with raw:rw + the inferred domain scope}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'
req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# List all sections in the dropbear package (long-tail example)"
req "$UAPI_BASE/raw/dropbear" | head -c 600; echo

echo
echo "# Create a raw firewall rule (passing through .type)"
created=$(req -H "$H_JSON" -X POST "$UAPI_BASE/raw/firewall" -d '{
	".type": "rule",
	"target": "ACCEPT",
	"src": "lan",
	"dest_port": "8080",
	"proto": "tcp"
}')
echo "$created"
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')

echo
echo "# The response carries reloaded:true and reload_services for known packages,"
echo "# or reloaded:false plus a reload_note when uapi does not know the right service."

echo
echo "# To delete:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/raw/firewall/$id\""
