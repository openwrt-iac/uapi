#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

# OpenWrt regenerates /etc/config/wireless from detected hardware. In QEMU with
# no radio (and no mac80211_hwsim loaded), every network reload wipes the file,
# so we cannot exercise CRUD end-to-end. Unit tests at tests/unit/network_wireless_test.uc
# cover the resource module (fromUci/toUci/validate). When a real radio (or
# mac80211_hwsim) is available, this test runs the full flow.
if ! $SSH 'ls /sys/class/ieee80211/ 2>/dev/null | grep -q .'; then
	echo "wireless.devices: no radio detected in VM, skipping CRUD test (unit tests cover the module)"
	exit 0
fi

echo "--- POST /wireless/devices creates a radio entry ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/wireless/devices" -d '{
	"type": "mac80211",
	"band": "2g",
	"channel": "1",
	"htmode": "HT20"
}')
echo "$created"
echo "$created" | tail -1 | grep -q '^200$' || fail "POST expected 200"
id=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$id" ] || fail "POST missing id"

cleanup() { curl -sS -H "$ADMIN" -X DELETE "$URL/wireless/devices/$id" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

echo "--- GET /wireless/devices/$id ---"
got=$(call "$URL/wireless/devices/$id")
echo "$got" | tail -1 | grep -q '^200$' || fail "GET expected 200"
echo "$got" | grep -q '"type": "mac80211"' || fail "GET missing type"
echo "$got" | grep -q '"band": "2g"' || fail "GET missing band"

echo "--- validate: unknown type rejected ---"
bad=$(call -X POST -H 'Content-Type: application/json' "$URL/wireless/devices" -d '{
	"type": "not-a-real-driver", "band": "2g"
}')
echo "$bad" | tail -1 | grep -q '^422$' || fail "unknown type expected 422"
echo "$bad" | grep -q '"code": "not_in_enum"' || fail "expected not_in_enum"

echo "--- validate: unknown band rejected ---"
bad_band=$(call -X POST -H 'Content-Type: application/json' "$URL/wireless/devices" -d '{
	"type": "mac80211", "band": "wat"
}')
echo "$bad_band" | tail -1 | grep -q '^422$' || fail "unknown band expected 422"

echo "--- PATCH /wireless/devices/$id (change channel) ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/wireless/devices/$id" -d '{
	"channel": "6"
}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200"
echo "$patched" | grep -q '"channel": "6"' || fail "PATCH did not update channel"

echo "--- DELETE /wireless/devices/$id ---"
call -X DELETE "$URL/wireless/devices/$id" | tail -1 | grep -q '^204$' || fail "DELETE expected 204"

echo "wireless.devices CRUD ok."
