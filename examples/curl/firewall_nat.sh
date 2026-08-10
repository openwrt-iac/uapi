#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v3}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with firewall:nat:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# Masquerade everything leaving the wan zone"
created=$(req -H "$H_JSON" -X POST "$UAPI_BASE/firewall/nat" -d '{
	"name": "masq-wan",
	"target": "MASQUERADE",
	"enabled": true,
	"match": {
		"src_zone": "wan"
	}
}')
echo "$created"
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')

echo
echo "# Read it back"
req "$UAPI_BASE/firewall/nat/$id"; echo

echo
echo "# Static source NAT for one subnet instead, pinned to an address"
snat=$(req -H "$H_JSON" -X POST "$UAPI_BASE/firewall/nat" -d '{
	"name": "snat-guests",
	"target": "SNAT",
	"snat_ip": "203.0.113.5",
	"match": {
		"src_zone": "wan",
		"src_ip": "192.168.9.0/24"
	}
}')
echo "$snat"
snat_id=$(printf '%s' "$snat" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')

echo
echo "# match.family is unset above, which firewall4 reads as IPv4 only."
echo "# Set it explicitly for dual-stack:"
echo '  "match": { "src_zone": "wan", "family": "any" }'

echo
echo "# To delete both:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/firewall/nat/$id\""
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/firewall/nat/$snat_id\""
