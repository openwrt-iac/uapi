#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }
wait_for() {
	local what="$1" check="$2"
	for _ in $(seq 20); do
		eval "$check" && return 0
		sleep 1
	done
	fail "$what"
}

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

cleanup() {
	for i in $id ${sid:-} ${nid:-}; do
		curl -sS -H "$ADMIN" -X DELETE "$URL/wireless/interfaces/$i" >/dev/null 2>&1 || true
	done
}
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

echo "--- a PUT of the read keeps a forced cipher and the 802.11r group, key holders included (#238) ---"
kh=00112233445566778899aabbccddeeff
$SSH "uci set wireless.$sid.encryption=psk2+ccmp
      uci set wireless.$sid.ieee80211r=1
      uci set wireless.$sid.ft_over_ds=0
      uci set wireless.$sid.ft_psk_generate_local=0
      uci set wireless.$sid.mobility_domain=4f57
      uci set wireless.$sid.nasid=ap1
      uci set wireless.$sid.r1_key_holder=02aabbccddee
      uci set wireless.$sid.pmk_r1_push=1
      uci add_list wireless.$sid.r0kh=ff:ff:ff:ff:ff:ff,*,$kh
      uci add_list wireless.$sid.r1kh=00:00:00:00:00:00,00:00:00:00:00:00,$kh
      uci commit wireless"
read_body=$(curl -sS -H "$ADMIN" "$URL/wireless/interfaces/$sid")
echo "$read_body" | jq -e '.encryption == "psk2+ccmp" and .ieee80211r == true and .ft_over_ds == false
	and .ft_psk_generate_local == false and .mobility_domain == "4f57" and .nasid == "ap1"
	and .r1_key_holder == "02aabbccddee" and .pmk_r1_push == true and .has_r0kh and .has_r1kh
	and (has("r0kh") or has("r1kh") | not)' >/dev/null \
	|| fail "GET did not read the options, or showed a key holder list: $read_body"
put=$(call -X PUT -H 'Content-Type: application/json' "$URL/wireless/interfaces/$sid" \
	-d "$(echo "$read_body" | jq -c 'del(.id, .managed, .runtime, .has_key, .has_r0kh, .has_r1kh) | .ssid = "uapi-test-ft"')")
echo "$put" | tail -1 | grep -q '^200$' || fail "PUT of the read: $put"
got=$($SSH "for o in encryption ieee80211r ft_over_ds ft_psk_generate_local mobility_domain nasid r1_key_holder pmk_r1_push r0kh r1kh key; do uci get wireless.$sid.\$o; done" | tr '\n' ' ')
[ "$got" = "psk2+ccmp 1 0 0 4f57 ap1 02aabbccddee 1 ff:ff:ff:ff:ff:ff,*,$kh 00:00:00:00:00:00,00:00:00:00:00:00,$kh supersecret " ] \
	|| fail "PUT of the read changed the options: $got"

# wifi-scripts writes these into hostapd's config without escaping, so a newline added a
# directive, and hostapd refuses its whole config for one key holder entry it cannot parse.
echo "--- a key, nasid or key holder entry that hostapd cannot take answers 422 and changes nothing ---"
for body in '{"key":"abcdefgh\nssid2=\"x\""}' '{"nasid":"ap1\nssid2=\"x\""}' \
	"{\"r0kh\":[\"02:00:00:00:00:01,ap1,$kh$kh\\nssid2=x\"]}" \
	'{"r0kh":["02:00:00:00:00:01,ap1,secret"]}' "{\"r1kh\":[\"02:00:00:00:00:01,ap1,$kh\"]}"; do
	r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/wireless/interfaces/$sid" -d "$body")
	echo "$r" | tail -1 | grep -q '^422$' || fail "PATCH $body expected 422: $r"
done
got=$($SSH "for o in key nasid r0kh r1kh; do uci get wireless.$sid.\$o; done" | tr '\n' ' ')
[ "$got" = "supersecret ap1 ff:ff:ff:ff:ff:ff,*,$kh 00:00:00:00:00:00,00:00:00:00:00:00,$kh " ] \
	|| fail "a refused PATCH changed uci: $got"
r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/wireless/interfaces/$sid" \
	-d "{\"r0kh\":[\"02:00:00:00:00:01,ap-1.example.com,$kh$kh\"]}")
echo "$r" | tail -1 | grep -q '^200$' || fail "PATCH of a 64-hex-digit r0kh entry: $r"
$SSH "uci get wireless.$sid.r0kh" | grep -qx "02:00:00:00:00:01,ap-1.example.com,$kh$kh" \
	|| fail "the r0kh entry was not stored"

# wifi-scripts sets up no interface for a section with no mode, which a read reports as ap.
echo "--- a POST with no mode stores mode ap, and wifi-scripts sets up the SSID ---"
nomode=$(call -X POST -H 'Content-Type: application/json' "$URL/wireless/interfaces" -d '{
	"device": "radio0", "network": "lan", "ssid": "uapi-test-nomode", "encryption": "none"
}')
echo "$nomode" | tail -1 | grep -q '^200$' || fail "POST with no mode expected 200: $nomode"
nid=$(echo "$nomode" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ "$($SSH "uci -q get wireless.$nid.mode")" = ap ] || fail "a POST with no mode did not store mode ap"
up_ifname() { $SSH 'ubus call network.wireless status' | jq -r --arg s "$1" '[.[].interfaces[]? | select(.section == $s) | .ifname // empty][0] // empty'; }
wait_for "wifi-scripts set up no interface for $nid" '[ -n "$(up_ifname "$nid")" ]'

echo "--- a mode, ssid or key that the daemons refuse answers 422 ---"
for body in '{"mode":"wds"}' '{"ssid":"'"$(printf '%033d' 0)"'"}' \
	'{"encryption":"psk2","key":"short"}' '{"encryption":"sae","key":"'"$kh$kh"'"}' \
	'{"mode":"sta","encryption":"psk2","key":"'"$kh$kh"'"}' '{"encryption":"owe","ieee80211r":true}'; do
	r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/wireless/interfaces/$nid" -d "$body")
	echo "$r" | tail -1 | grep -q '^422$' || fail "PATCH $body expected 422: $r"
done

# netifd converts a number with ucode's `+v`, and validate.uc stops the setup of the radio for a
# reassociation_deadline outside 1000 to 65535 on any enabled SSID.
echo "--- a stored reassociation_deadline reads as wifi-scripts reads it, and one out of range stops the radio ---"
refused() { $SSH logread | grep -c 'reassociation_deadline: 500 is lower than the minimum value' || true; }
before=$(refused)
$SSH "uci set wireless.$nid.reassociation_deadline=' 500'; uci commit wireless; ubus call network reload"
r=$(call "$URL/wireless/interfaces/$nid" | sed '$d')
echo "$r" | jq -e '.reassociation_deadline == 500' >/dev/null || fail "' 500' did not read 500: $r"
sweep=$(call "$URL/diagnostics?validate=1" | sed '$d')
echo "$sweep" | jq -e --arg s "$nid" '.invalid_sections | tostring | contains($s)' >/dev/null \
	|| fail "the sweep did not list reassociation_deadline ' 500': $sweep"
wait_for "validate.uc did not refuse reassociation_deadline 500" '[ "$(refused)" -gt "$before" ]'
$SSH "uci delete wireless.$nid.reassociation_deadline; uci commit wireless; ubus call network reload"
wait_for "the radio did not come back after reassociation_deadline went" '[ -n "$(up_ifname "$nid")" ]'

# netifd reads `yes` as null, and validate.uc turns that into false, so wifi-scripts writes the
# key holder lists that it derives, where the default for psk2 is to generate the keys locally.
# Only this SSID can give hostapd the derived ff:ff:ff:ff:ff:ff entry: the PATCH above replaced
# the one of $sid.
echo "--- ft_psk_generate_local 'yes' reads false, as hostapd gets it ---"
$SSH "uci set wireless.$nid.encryption=psk2; uci set wireless.$nid.key=correcthorse
      uci set wireless.$nid.ieee80211r=1; uci set wireless.$nid.ft_psk_generate_local=yes
      uci commit wireless; ubus call network reload"
r=$(call "$URL/wireless/interfaces/$nid" | sed '$d')
echo "$r" | jq -e '.ft_psk_generate_local == false' >/dev/null || fail "ft_psk_generate_local 'yes' did not read false: $r"
wait_for "hostapd did not get the key holders that wifi-scripts derives" \
	"$SSH 'cat /var/run/hostapd-*.conf' | grep -q '^r0kh=ff:ff:ff:ff:ff:ff \*'"

echo "--- DELETE all three ---"
call -X DELETE "$URL/wireless/interfaces/$nid" | tail -1 | grep -q '^204$' || fail "no-mode DELETE expected 204"
call -X DELETE "$URL/wireless/interfaces/$sid" | tail -1 | grep -q '^204$' || fail "secured DELETE expected 204"
call -X DELETE "$URL/wireless/interfaces/$id"  | tail -1 | grep -q '^204$' || fail "open DELETE expected 204"

echo "wireless.interfaces CRUD + key preservation ok."
