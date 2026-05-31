#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v1}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with sqm:queues:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# Create an SQM queue on wan (cake, 90/10 mbit)"
created=$(req -H "$H_JSON" -X POST "$UAPI_BASE/sqm/queues" -d '{
	"interface": "wan",
	"enabled": true,
	"download": 90000,
	"upload": 10000,
	"qdisc": "cake",
	"script": "piece_of_cake.qos",
	"linklayer": "ethernet",
	"overhead": 22
}')
echo "$created"
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')

echo
echo "# Bump download rate"
req -H "$H_JSON" -X PATCH "$UAPI_BASE/sqm/queues/$id" -d '{"download": 100000}'; echo

echo
echo "# To delete:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/sqm/queues/$id\""
