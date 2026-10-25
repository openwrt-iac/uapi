#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

ensure_wireless_radio || fail "could not bring up a simulated radio via mac80211_hwsim"

echo "--- POST /wireless/devices creates a radio entry ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/wireless/devices" -d '{
	"type": "mac80211",
	"band": "2g",
	"channel": 1,
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
	"channel": 6
}')
echo "$patched" | tail -1 | grep -q '^200$' || fail "PATCH expected 200"
echo "$patched" | grep -q '"channel": 6' || fail "PATCH did not update channel"

echo "--- DELETE /wireless/devices/$id ---"
call -X DELETE "$URL/wireless/devices/$id" | tail -1 | grep -q '^204$' || fail "DELETE expected 204"

echo "--- a PUT of the stock radio's read keeps path, macaddr, cell_density and legacy_rates (#238) ---"
# `wifi config` binds the radio to its phy with path; without it, wifi-scripts finds no phy.
# The PUT rewrites the stock radio, so its file goes back whatever the outcome.
$SSH 'cp /etc/config/wireless /tmp/uapi19-radio0.bak'
restore_radio0() { $SSH 'test -e /tmp/uapi19-radio0.bak && mv /tmp/uapi19-radio0.bak /etc/config/wireless' || true; }
trap 'restore_radio0; cleanup' EXIT INT TERM
stock_path=$($SSH 'uci get wireless.radio0.path')
[ -n "$stock_path" ] || fail "wifi config wrote no path for radio0"
$SSH 'uci set wireless.radio0.macaddr=02:00:00:00:00:99; uci set wireless.radio0.cell_density=2
      uci set wireless.radio0.legacy_rates=1; uci commit wireless'
read_body=$(curl -sS -H "$ADMIN" "$URL/wireless/devices/radio0")
echo "$read_body" | jq -e --arg p "$stock_path" '.path == $p and .macaddr == "02:00:00:00:00:99"
	and .cell_density == 2 and .legacy_rates == true' >/dev/null \
	|| fail "GET radio0 did not read the options: $read_body"
put=$(call -X PUT -H 'Content-Type: application/json' "$URL/wireless/devices/radio0" \
	-d "$(echo "$read_body" | jq -c 'del(.id, .managed, .runtime)')")
echo "$put" | tail -1 | grep -q '^200$' || fail "PUT of the read: $put"
[ "$($SSH 'uci get wireless.radio0.path')" = "$stock_path" ] || fail "PUT of the read lost path"
got=$($SSH 'for o in macaddr cell_density legacy_rates; do uci get wireless.radio0.$o; done' | tr '\n' ' ')
[ "$got" = "02:00:00:00:00:99 2 1 " ] || fail "PUT of the read changed the options: $got"
restore_radio0
trap cleanup EXIT INT TERM

echo "--- without /etc/config/wireless, a write answers 503 config_missing and stores nothing ---"
# A router without a radio has no such file, because `wifi config` writes it only for hardware it finds.
$SSH 'mv /etc/config/wireless /tmp/uapi19-wireless'
restore_wireless() { $SSH 'test -e /tmp/uapi19-wireless && mv /tmp/uapi19-wireless /etc/config/wireless' || true; }
trap 'restore_wireless; cleanup' EXIT INT TERM
for ep in devices interfaces; do
	case $ep in
	devices) body='{"type": "mac80211"}' ;;
	interfaces) body='{"device": "radio0", "mode": "ap", "ssid": "uapi19", "network": "lan"}' ;;
	esac
	r=$(call -X POST -H 'Content-Type: application/json' "$URL/wireless/$ep" -d "$body")
	echo "$r" | tail -1 | grep -q '^503$' && echo "$r" | grep -q '"code": "config_missing"' \
		&& echo "$r" | grep -q '/etc/config/wireless' || fail "POST /wireless/$ep without the config: $r"
	call "$URL/wireless/$ep" | sed '$d' | jq -e 'length == 0' >/dev/null || fail "GET /wireless/$ep is not empty"
done
$SSH 'test ! -e /etc/config/wireless' || fail "a refused write created /etc/config/wireless"
restore_wireless

echo "--- the installed bus raises on a uci write that stores nothing, and not on a delete of nothing ---"
$SSH 'cat > /tmp/uapi19-bus.uc' <<'UC'
let b = require("bus").connect();
let out = [];
for (let op in [ "set", "commit", "delete" ]) {
	let r = "ok";
	try {
		if (op == "set") b.uci_set("uapi_nosuchpkg", "s", "o", "1");
		else if (op == "commit") b.uci_commit("uapi_nosuchpkg");
		else b.uci_delete("network", "loopback", "uapi_no_such_option");
	} catch (e) { r = "died"; }
	push(out, op + "=" + r);
}
print(join(" ", out), "\n");
UC
out=$($SSH 'ucode -L /usr/share/uapi/lib /tmp/uapi19-bus.uc; rm -f /tmp/uapi19-bus.uc')
[ "$out" = "set=died commit=died delete=ok" ] || fail "bus checks: $out"

echo "wireless.devices CRUD ok."
