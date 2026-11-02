#!/bin/sh
set -eu

: "${UAPI_BASE:?set UAPI_BASE to https://<router>/api/v3}"
: "${UAPI_TOKEN:?set UAPI_TOKEN to a bearer with network:wireguard_kernel_peers:ro}"

H_AUTH="Authorization: Bearer $UAPI_TOKEN"

req() { curl -ksS -H "$H_AUTH" "$@"; }

echo "# 1) List the WireGuard peers the kernel holds that no uci section claims"
req "$UAPI_BASE/network/wireguard_kernel_peers"; echo

echo
echo "# 2) Read one entry by its id (the first 12 hex of the sha256 of the"
echo "#    interface name and the public key, as the listing shows it)"
req "$UAPI_BASE/network/wireguard_kernel_peers/REPLACE_WITH_ID"; echo

echo
echo "# Every write answers 405: the collection is read-only. A peer that it"
echo "# lists is drift, so fix it on the router: give the peer a uci section, or"
echo "# remove it with: wg set <iface> peer <public_key> remove"
