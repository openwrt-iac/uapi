#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v3}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with network:wireguard_peers:rw and network:interfaces:rw}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"
H_JSON='Content-Type: application/json'

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# 1) Create the parent wireguard interface"
iface=$(req -H "$H_JSON" -X POST "$UAPI_BASE/network/interfaces" -d '{
	"name": "wg0",
	"proto": "wireguard",
	"private_key": "REPLACE_WITH_BASE64_44CHAR_PRIVATE_KEY",
	"listen_port": 51820,
	"addresses": ["10.99.0.1/24"]
}')
echo "$iface"
iface_id=$(printf '%s' "$iface" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')

echo
echo "# 2) Add a peer to wg0"
peer=$(req -H "$H_JSON" -X POST "$UAPI_BASE/network/wireguard_peers" -d '{
	"interface": "wg0",
	"description": "laptop",
	"public_key": "REPLACE_WITH_PEER_BASE64_PUBLIC_KEY_44_CHARS_EQ=",
	"allowed_ips": ["10.99.0.2/32"],
	"persistent_keepalive": 25
}')
echo "$peer"
peer_id=$(printf '%s' "$peer" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')

echo
echo "# 3) Read the peer back; preshared_key is masked, has_preshared_key surfaces"
req "$UAPI_BASE/network/wireguard_peers/$peer_id"; echo

echo
echo "# To delete the peer:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/network/wireguard_peers/$peer_id\""
echo "# Then to delete the interface:"
echo "  curl -ksS -H \"$H_AUTH\" -X DELETE \"$UAPI_BASE/network/interfaces/$iface_id\""
