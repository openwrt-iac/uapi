#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

ensure_wireless_radio || fail "could not bring up a simulated radio via mac80211_hwsim"

echo "--- POST /wireless/interfaces (open network) ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/wireless/interfaces" -d '{
	"device": "radio0",
	"network": "lan",
	"mode": "ap",
	"ssid": "uapi-test-open",
	"encryption": "none"
}')
echo "$created"
echo "$created" | tail -1 | grep -q '^200$' || fail "POST expected 200"
id=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$id" ] || fail "POST missing id"

cleanup() { curl -sS -H "$ADMIN" -X DELETE "$URL/wireless/interfaces/$id" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

echo "--- GET /wireless/interfaces/$id ---"
got=$(call "$URL/wireless/interfaces/$id")
echo "$got" | tail -1 | grep -q '^200$' || fail "GET expected 200"
echo "$got" | grep -q '"ssid": "uapi-test-open"' || fail "GET missing ssid"
echo "$got" | grep -q '"encryption": "none"' || fail "GET missing encryption"

echo "--- validate: missing device rejected ---"
bad=$(call -X POST -H 'Content-Type: application/json' "$URL/wireless/interfaces" -d '{
	"mode": "ap", "ssid": "no-device"
}')
echo "$bad" | tail -1 | grep -q '^422$' || fail "missing device expected 422"

echo "--- validate: encryption psk2 without key rejected ---"
no_key=$(call -X POST -H 'Content-Type: application/json' "$URL/wireless/interfaces" -d '{
	"device": "radio0", "ssid": "secured", "encryption": "psk2"
}')
echo "$no_key" | tail -1 | grep -q '^422$' || fail "psk2 without key expected 422"
echo "$no_key" | grep -q '"field": "key"' || fail "expected error on key field"

echo "--- POST a psk2 interface with key, then GET masks the key but reports has_key ---"
secured=$(call -X POST -H 'Content-Type: application/json' "$URL/wireless/interfaces" -d '{
	"device": "radio0", "network": "lan", "mode": "ap",
	"ssid": "uapi-test-secured", "encryption": "psk2", "key": "supersecret"
}')
echo "$secured" | tail -1 | grep -q '^200$' || fail "secured POST expected 200"
sid=$(echo "$secured" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
echo "$secured" | grep -q '"has_key": true' || fail "expected has_key:true on creation response"
echo "$secured" | grep -q '"key":' && echo "$secured" | grep -E '"key":[[:space:]]*"' \
	&& fail "key should not appear in response body"

echo "--- PATCH ssid only; key is preserved (Track 4 wifi PATCH key-preservation fix) ---"
patched=$(call -X PATCH -H 'Content-Type: application/json' "$URL/wireless/interfaces/$sid" -d '{
	"ssid": "uapi-test-secured-renamed"
}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200 (key should be preserved)"
echo "$patched" | grep -q '"ssid": "uapi-test-secured-renamed"' || fail "PATCH did not rename SSID"
echo "$patched" | grep -q '"has_key": true' || fail "PATCH lost has_key (key was not preserved)"

# Verify the cleartext key is actually still on disk
$SSH "uci get wireless.$sid.key" | grep -q '^supersecret$' \
	|| fail "uci-level key was overwritten or lost during PATCH"

echo "--- DELETE both ---"
call -X DELETE "$URL/wireless/interfaces/$sid" | tail -1 | grep -q '^204$' || fail "secured DELETE expected 204"
call -X DELETE "$URL/wireless/interfaces/$id"  | tail -1 | grep -q '^204$' || fail "open DELETE expected 204"

echo "wireless.interfaces CRUD + key preservation ok."
