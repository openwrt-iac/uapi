#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v1
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

echo "--- network/routes: POST a blackhole route (no interface dep) ---"
created=$(call -X POST -H 'Content-Type: application/json' "$URL/network/routes" -d '{
	"target": "203.0.113.0/24", "type": "blackhole"
}')
echo "$created"
status=$(echo "$created" | tail -1)
[ "$status" = "200" ] || fail "routes POST expected 200, got $status"
rid=$(echo "$created" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')

echo "--- network/routes: malformed target rejected ---"
bad=$(call -X POST -H 'Content-Type: application/json' "$URL/network/routes" -d '{
	"target": "999.0.0.0/24"
}')
echo "$bad" | tail -1 | grep -q '^422$' || fail "bad target expected 422"

echo "--- network/routes: DELETE ---"
call -X DELETE "$URL/network/routes/$rid" | tail -1 | grep -q '^204$' || fail "DELETE routes expected 204"

echo "--- network/rules: POST a PBR rule ---"
rule=$(call -X POST -H 'Content-Type: application/json' "$URL/network/rules" -d '{
	"src": "192.168.10.0/24", "lookup": 42, "priority": 30000
}')
echo "$rule"
status=$(echo "$rule" | tail -1)
[ "$status" = "200" ] || fail "rules POST expected 200, got $status"
plid=$(echo "$rule" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')

echo "--- network/rules: missing selector rejected ---"
bad_rule=$(call -X POST -H 'Content-Type: application/json' "$URL/network/rules" -d '{
	"lookup": 42
}')
echo "$bad_rule" | tail -1 | grep -q '^422$' || fail "no-selector rule expected 422"

echo "--- network/rules: DELETE ---"
call -X DELETE "$URL/network/rules/$plid" | tail -1 | grep -q '^204$' || fail "DELETE rules expected 204"

echo "--- network/bridge_vlans: set up a throwaway bridge that is NOT in the management path ---"
# br-lan carries the connection back to curl. Flipping vlan_filtering on it cuts
# the response path and the POST appears to hang. Create an isolated bridge with
# a fake port so the bridge-vlan reload has no effect on traffic.
$SSH "uci set network.uapitestbr=device; uci set network.uapitestbr.type=bridge; uci set network.uapitestbr.name=br-uapitest; uci -q delete network.uapitestbr.ports; uci add_list network.uapitestbr.ports=lan99; uci commit network"

# Always clean up the throwaway bridge, even on mid-test failure, so a re-run
# doesn't see stale uci state.
cleanup() {
	$SSH "uci -q delete network.uapitestbr; uci commit network; /etc/init.d/network reload" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "--- network/bridge_vlans: POST against the isolated bridge ---"
bv=$(call -X POST -H 'Content-Type: application/json' "$URL/network/bridge_vlans" -d '{
	"device": "br-uapitest", "vlan": 99, "ports": ["lan99:t"]
}')
echo "$bv"
status=$(echo "$bv" | tail -1)
[ "$status" = "200" ] || fail "bridge_vlans POST expected 200, got $status"
vid=$(echo "$bv" | grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')

echo "--- network/bridge_vlans: vlan out of range rejected ---"
bad_bv=$(call -X POST -H 'Content-Type: application/json' "$URL/network/bridge_vlans" -d '{
	"device": "br-uapitest", "vlan": 5000
}')
echo "$bad_bv" | tail -1 | grep -q '^422$' || fail "bad vlan expected 422"

echo "--- network/bridge_vlans: missing bridge cross-ref rejected with conflict ---"
no_bridge=$(call -X POST -H 'Content-Type: application/json' "$URL/network/bridge_vlans" -d '{
	"device": "br-does-not-exist", "vlan": 7
}')
echo "$no_bridge" | tail -1 | grep -q '^422$' || fail "missing bridge expected 422"

echo "--- network/bridge_vlans: DELETE ---"
call -X DELETE "$URL/network/bridge_vlans/$vid" | tail -1 | grep -q '^204$' || fail "DELETE bridge_vlans expected 204"

# Cleanup runs from the EXIT trap above.

echo "network/routes + rules + bridge_vlans CRUD ok."
