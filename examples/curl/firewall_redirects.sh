#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v1}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with firewall:redirects:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# Forward wan tcp/443 -> 192.168.1.10:443"
created=$(req -H "$H_JSON" -X POST "$UAPI_BASE/firewall/redirects" -d '{
	"name": "https-to-server",
	"target": "DNAT",
	"enabled": true,
	"match": {
		"src_zone": "wan",
		"src_dport": ["443"],
		"proto": ["tcp"],
		"dest_zone": "lan",
		"dest_ip": "192.168.1.10",
		"dest_port": "443"
	}
}')
echo "$created"
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')

echo
echo "# Read it back"
req "$UAPI_BASE/firewall/redirects/$id"; echo

echo
echo "# To delete:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/firewall/redirects/$id\""
