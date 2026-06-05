#!/bin/sh
set -eu

# v2.0.2 C1: proto=wireguard interfaces need their uci section name to also
# be a legal Linux ifname (netifd uses the section name verbatim as the
# kernel netdev name; IFNAMSIZ caps it at 15 chars). The caller can supply
# `name`; otherwise the server emits a `wg_<11-char>` fallback. Either way
# the resulting `ip link show <id>` must show a real netdev. v2.0.0/v2.0.1
# silently created a config that could never come up.

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

# Example WireGuard private key (44 chars, base64). Doesn't have to match a
# real peer for netifd to accept the config + create the netdev.
PRIV='yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk='

echo "--- POST a wireguard interface with caller-supplied name=wgci ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d "{\"proto\":\"wireguard\",\"name\":\"wgci\",
	    \"private_key\":\"$PRIV\",\"addresses\":[\"10.99.99.1/30\"]}")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "POST wireguard expected 200, got $status: $body"
id=$(echo "$body" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ "$id" = "wgci" ] || fail "expected id=wgci, got id=$id"

echo "--- the uci section is named wgci (not a 28-char ULID) ---"
$SSH "uci get network.wgci" >/dev/null || fail "section network.wgci not in uci"

echo "--- ip link show wgci returns a real kernel netdev ---"
sleep 2  # netifd needs a moment to bring it up
$SSH "ip link show wgci" >/dev/null 2>&1 || fail "ip link show wgci failed (the v2.0.0 bug); netifd could not create the netdev"

echo "--- DELETE wireguard interface ---"
del=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" -X DELETE "$URL/network/interfaces/wgci")
[ "$del" = "204" ] || fail "DELETE expected 204, got $del"

echo "--- POST without a name -> server emits a wg_<11-char> id (14 chars, <= IFNAMSIZ) ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d "{\"proto\":\"wireguard\",
	    \"private_key\":\"$PRIV\",\"addresses\":[\"10.99.99.5/30\"]}")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "POST wireguard (no name) expected 200, got $status: $body"
id=$(echo "$body" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
echo "$id" | grep -qE '^wg_[0-9a-hjkmnp-tv-z]{11}$' \
	|| fail "expected id=wg_<11-char>, got id=$id"
test "$(echo -n "$id" | wc -c)" -le 15 \
	|| fail "id $id exceeds IFNAMSIZ (15 chars)"
sleep 2
$SSH "ip link show $id" >/dev/null 2>&1 \
	|| fail "ip link show $id failed; netifd could not create the netdev"
curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/network/interfaces/$id"

echo "--- validation: name on a non-wireguard create -> 422 ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d '{"proto":"dhcp","name":"shouldfail"}')
status=$(echo "$resp" | tail -1)
[ "$status" = "422" ] || fail "name on non-wireguard expected 422, got $status"

echo "--- validation: 16-char name on wireguard -> 422 ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d "{\"proto\":\"wireguard\",\"name\":\"wg_16chars_total\",
	    \"private_key\":\"$PRIV\",\"addresses\":[\"10.99.99.9/30\"]}")
status=$(echo "$resp" | tail -1)
[ "$status" = "422" ] || fail "16-char name expected 422, got $status"

echo "--- validation: hyphenated name -> 422 (uci section names are alphanumeric+underscore only) ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d "{\"proto\":\"wireguard\",\"name\":\"wg-prod\",
	    \"private_key\":\"$PRIV\",\"addresses\":[\"10.99.99.13/30\"]}")
status=$(echo "$resp" | tail -1)
[ "$status" = "422" ] || fail "hyphenated name expected 422, got $status"

echo "wireguard interface naming honours caller-supplied name AND IFNAMSIZ."
