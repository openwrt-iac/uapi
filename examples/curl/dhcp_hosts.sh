#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE}"
: "${UAPI_TOKEN:?set UAPI_TOKEN with dhcp:hosts:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'
req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# Static lease for the printer"
created=$(req -H "$H_JSON" -X POST "$UAPI_BASE/dhcp/hosts" -d '{
	"name": "printer",
	"mac": "aa:bb:cc:dd:ee:ff",
	"ip": "192.168.1.50",
	"leasetime": "12h"
}')
echo "$created"
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')

echo
echo "# Read active leases (runtime, read-only)"
req "$UAPI_BASE/dhcp/leases" | head -c 400; echo

echo
echo "# To delete the static lease:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/dhcp/hosts/$id\""
