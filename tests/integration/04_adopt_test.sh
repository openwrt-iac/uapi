#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"

fail() { echo "FAIL: $*"; exit 1; }

call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- inject an anonymous rule via uci ---"
anon_id=$($SSH 'uci add firewall rule')
$SSH "uci set firewall.$anon_id.target=DROP
      uci set firewall.$anon_id.src=lan
      uci set firewall.$anon_id.dest_port=23
      uci commit firewall"
echo "  anon id: $anon_id"

echo "--- GET the anonymous rule shows managed:false ---"
got=$(call "$URL/firewall/rules/$anon_id")
echo "$got"
echo "$got" | tail -1 | grep -q '^200$' || fail "GET expected 200"
echo "$got" | grep -q '"managed": false' || fail "expected managed:false"

echo "--- PUT on unmanaged returns 409 unmanaged_resource ---"
denied=$(call -X PUT -H 'Content-Type: application/json' "$URL/firewall/rules/$anon_id" -d '{"target":"ACCEPT","match":{"src_zone":"lan"}}')
echo "$denied"
echo "$denied" | tail -1 | grep -q '^409$' || fail "PUT on unmanaged expected 409"
echo "$denied" | grep -q '"code": "unmanaged_resource"' || fail "missing unmanaged_resource code"

echo "--- DELETE on unmanaged returns 409 unmanaged_resource ---"
del_denied=$(call -X DELETE "$URL/firewall/rules/$anon_id")
echo "$del_denied" | tail -1 | grep -q '^409$' || fail "DELETE on unmanaged expected 409"

echo "--- POST .../adopt renames the section and flips managed:true ---"
adopted=$(call -X POST "$URL/firewall/rules/$anon_id/adopt")
echo "$adopted"
echo "$adopted" | tail -1 | grep -q '^200$' || fail "adopt expected 200"
new_id=$(echo "$adopted" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
[ -n "$new_id" ] || fail "adopt response missing new id"
echo "$adopted" | grep -q '"managed": true' || fail "adopted body missing managed:true"
[ "$new_id" != "$anon_id" ] || fail "new id should differ from anon id"
echo "  new managed id: $new_id"

echo "--- old anon id is gone ---"
gone=$(call "$URL/firewall/rules/$anon_id")
echo "$gone" | tail -1 | grep -q '^404$' || fail "old anon id should 404 after adopt"

echo "--- PUT on adopted rule succeeds ---"
put_ok=$(call -X PUT -H 'Content-Type: application/json' "$URL/firewall/rules/$new_id" -d '{
	"target": "ACCEPT",
	"match": { "src_zone": "lan", "dest_port": ["80"] }
}')
echo "$put_ok"
echo "$put_ok" | tail -1 | grep -q '^200$' || fail "PUT on adopted expected 200"
echo "$put_ok" | grep -q '"target": "ACCEPT"' || fail "PUT did not update target"

echo "--- adopting an already-managed section returns 409 conflict ---"
double_adopt=$(call -X POST "$URL/firewall/rules/$new_id/adopt")
echo "$double_adopt" | tail -1 | grep -q '^409$' || fail "double adopt expected 409"
echo "$double_adopt" | grep -q '"code": "conflict"' || fail "missing conflict code"

echo "--- managed-filter shows only adopted rule ---"
managed_list=$(call "$URL/firewall/rules?managed=true")
echo "$managed_list" | grep -q "\"id\": \"$new_id\"" || fail "managed=true list missing adopted rule"

echo "--- unmanaged-filter excludes adopted rule ---"
unmanaged_list=$(call "$URL/firewall/rules?managed=false")
echo "$unmanaged_list" | grep -q "\"id\": \"$new_id\"" && fail "managed=false should not contain adopted rule"

call -X DELETE "$URL/firewall/rules/$new_id" >/dev/null

# Adoption is identical code (handler.make().adopt) for every CRUD resource. We
# verify the contract holds for each type so a regression in one resource module
# can't pass undetected.
adopt_for() {
	label="$1"; pkg="$2"; sec_type="$3"; url_path="$4"
	anon=$($SSH "name=\$(uci add $pkg $sec_type) && uci commit $pkg && echo \$name")
	[ -n "$anon" ] || fail "$label: uci add produced no name"
	got=$(call "$URL/$url_path/$anon")
	echo "$got" | grep -q '"managed": false' \
		|| { echo "$got"; fail "$label: GET anon expected managed:false"; }
	adopted=$(call -X POST "$URL/$url_path/$anon/adopt")
	echo "$adopted" | tail -1 | grep -q '^200$' \
		|| { echo "$adopted"; fail "$label: adopt expected 200"; }
	new=$(echo "$adopted" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
	[ -n "$new" ] || fail "$label: adopted body missing new id"
	echo "$adopted" | grep -q '"managed": true' || fail "$label: adopted missing managed:true"
	[ "$new" != "$anon" ] || fail "$label: new id should differ from anon"
	call -X DELETE "$URL/$url_path/$new" >/dev/null
	echo "  $label: anon=$anon -> $new (adopted, then deleted)"
}

echo "--- adoption works for every CRUD-capable curated resource ---"
adopt_for firewall.zone     firewall zone        firewall/zones
adopt_for firewall.redirect firewall redirect    firewall/redirects
adopt_for network.interface network  interface   network/interfaces
adopt_for network.device    network  device      network/devices
adopt_for dhcp.host         dhcp     host        dhcp/hosts

# Wireless adoption needs a real radio (or mac80211_hwsim) so /etc/config/wireless
# is not wiped by the post-write network reload. See 19_wireless_devices_test.sh.
if $SSH 'ls /sys/class/ieee80211/ 2>/dev/null | grep -q .'; then
	adopt_for wireless.device wireless wifi-device wireless/devices
	adopt_for wireless.iface  wireless wifi-iface  wireless/interfaces
else
	echo "  wireless.device, wireless.iface: skipped (no radio in VM)"
fi

echo "adoption flow ok"
