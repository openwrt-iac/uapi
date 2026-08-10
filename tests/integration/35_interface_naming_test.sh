#!/bin/sh
set -eu

# network/interfaces takes a caller-supplied section name through `id`, on every proto. When
# absent, the server emits a 14-char `wg_<rand>` for proto=wireguard (fits Linux IFNAMSIZ for
# the kernel netdev) or a 28-char ULID otherwise. The wireguard subcase exists because
# v2.0.0/v2.0.1 silently created a config that could never come up; that path is exercised
# end-to-end here. `name` was the 2.1.0-era spelling of this input and was removed in 3.0.0.

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

# netifd only learns a proto handler at startup, so installing wireguard-tools
# is not enough on its own; ensure_wireguard handles the restart. If it cannot be
# made to work the netdev assertions below are meaningless, so this fails rather
# than quietly downgrading to uci-only checks, which is how they went unrun.
WG_KMOD_AVAILABLE=0
if ensure_wireguard; then
	WG_KMOD_AVAILABLE=1
else
	echo "[35_wg] FAIL: no usable wireguard support; the netdev assertions cannot run"
	echo "[35_wg] uname -r: $($SSH 'uname -r')"
	exit 1
fi

# Example WireGuard private key (44 chars, base64). Doesn't have to match a
# real peer for netifd to accept the config + create the netdev.
PRIV='yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk='

echo "--- POST a wireguard interface with caller-supplied id=wgci ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d "{\"proto\":\"wireguard\",\"id\":\"wgci\",
	    \"private_key\":\"$PRIV\",\"addresses\":[\"10.99.99.1/30\"]}")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "POST wireguard expected 200, got $status: $body"
id=$(echo "$body" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ "$id" = "wgci" ] || fail "expected id=wgci, got id=$id"

echo "--- the uci section is named wgci (not a 28-char ULID) ---"
$SSH "uci get network.wgci" >/dev/null || fail "section network.wgci not in uci"

if [ "$WG_KMOD_AVAILABLE" = "1" ]; then
	echo "--- ip link show wgci returns a real kernel netdev ---"
	# netifd is async; poll up to 15s for the netdev to appear instead of a
	# bare sleep (flaky on slow CI runners).
	for i in $(seq 1 15); do
		$SSH "ip link show wgci" >/dev/null 2>&1 && break
		sleep 1
	done
	$SSH "ip link show wgci" >/dev/null 2>&1 \
		|| fail "ip link show wgci failed (the v2.0.0 bug); netifd could not create the netdev"
else
	echo "[35_wg] skipping wgci netdev assertion (no kmod)"
fi

echo "--- DELETE wireguard interface ---"
del=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" -X DELETE "$URL/network/interfaces/wgci")
[ "$del" = "204" ] || fail "DELETE expected 204, got $del"

echo "--- POST without an id -> server emits a wg_<11-char> id (14 chars, <= IFNAMSIZ) ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d "{\"proto\":\"wireguard\",
	    \"private_key\":\"$PRIV\",\"addresses\":[\"10.99.99.5/30\"]}")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "POST wireguard (no id) expected 200, got $status: $body"
id=$(echo "$body" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
echo "$id" | grep -qE '^wg_[0-9a-hjkmnp-tv-z]{11}$' \
	|| fail "expected id=wg_<11-char>, got id=$id"
test "$(echo -n "$id" | wc -c)" -le 15 \
	|| fail "id $id exceeds IFNAMSIZ (15 chars)"
if [ "$WG_KMOD_AVAILABLE" = "1" ]; then
	for i in $(seq 1 15); do
		$SSH "ip link show $id" >/dev/null 2>&1 && break
		sleep 1
	done
	$SSH "ip link show $id" >/dev/null 2>&1 \
		|| fail "ip link show $id failed; netifd could not create the netdev"
else
	echo "[35_wg] skipping $id netdev assertion (no kmod)"
fi
curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/network/interfaces/$id"

echo "--- id on a non-wireguard create -> 200 (any proto accepts a caller-supplied section name) ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d '{"proto":"dhcp","id":"namedhcp"}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "id on dhcp expected 200, got $status: $body"
id=$(echo "$body" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ "$id" = "namedhcp" ] || fail "expected id=namedhcp, got id=$id"
$SSH "uci get network.namedhcp" >/dev/null || fail "section network.namedhcp not in uci"
curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/network/interfaces/namedhcp"

echo "--- validation: 16-char id on wireguard -> 422 ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d "{\"proto\":\"wireguard\",\"id\":\"wg_16chars_total\",
	    \"private_key\":\"$PRIV\",\"addresses\":[\"10.99.99.9/30\"]}")
status=$(echo "$resp" | tail -1)
[ "$status" = "422" ] || fail "16-char id expected 422, got $status"

echo "--- validation: hyphenated id -> 422 (uci section names are alphanumeric+underscore only) ---"
resp=$(call -X POST -H 'Content-Type: application/json' "$URL/network/interfaces" \
	-d "{\"proto\":\"wireguard\",\"id\":\"wg-prod\",
	    \"private_key\":\"$PRIV\",\"addresses\":[\"10.99.99.13/30\"]}")
status=$(echo "$resp" | tail -1)
[ "$status" = "422" ] || fail "hyphenated id expected 422, got $status"

echo "interface naming: caller-supplied id accepted on every proto; IFNAMSIZ + uci charset enforced."
