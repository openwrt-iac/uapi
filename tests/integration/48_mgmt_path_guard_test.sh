#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# The advisory management-path warning. Everything here has to derive the inbound
# interface from the running box rather than assume one, because which interface carries
# the test's own connection depends on how the VM is reached.

echo "--- /diagnostics reports which interface this request arrived through ---"
diag=$(curl -sS -H "$ADMIN" "$URL/diagnostics")
echo "$diag" | jq -e '.management_path' >/dev/null \
	|| fail "diagnostics carries no management_path"
addr=$(echo "$diag" | jq -r '.management_path.address // empty')
dev=$(echo "$diag" | jq -r '.management_path.device // empty')
iface=$(echo "$diag" | jq -r '.management_path.interface // empty')
echo "  address=$addr device=$dev interface=${iface:-<unmatched>}"
[ -n "$addr" ] || fail "management_path names no address"
[ -n "$dev" ] || fail "management_path names no device, so the route lookup failed"

# The device has to be a real one, since the whole point is that this comes from the
# kernel's own route table rather than from prefix arithmetic.
$SSH "ip link show $dev" >/dev/null 2>&1 || fail "management_path named a device that does not exist: $dev"

if [ -z "$iface" ]; then
	echo "  [48_mgmt] FAIL: the request arrives on $dev, which no uci interface claims,"
	echo "  [48_mgmt] so the warning half of this test cannot run."
	echo "  [48_mgmt] interfaces: $($SSH 'ubus call network.interface dump 2>/dev/null | jq -c "[.interface[] | {interface, l3_device, device}]"')"
	fail "no uci interface owns $dev"
fi

echo "--- a watched field on the inbound interface warns ---"
# `disabled: false` on an already-enabled interface is the smallest change that still
# moves a watched field: netifd sees no material difference, so the connection carrying
# this request survives long enough to read the response. Any of the four field names
# would warn; this one cannot strand the test.
code=$(curl -sS -D /tmp/uapi_mgmt_h -o /dev/null -w '%{http_code}' -H "$ADMIN" \
	-H 'Content-Type: application/json' \
	-X PATCH "$URL/network/interfaces/$iface" -d '{"disabled":false}')
[ "$code" = "200" ] || { cat /tmp/uapi_mgmt_h; fail "PATCH $iface returned $code"; }
warn=$(tr -d '\r' < /tmp/uapi_mgmt_h | grep -i '^X-Mgmt-Path-Warning:' | cut -d' ' -f2- || true)
[ -n "$warn" ] || { tr -d '\r' < /tmp/uapi_mgmt_h; fail "no X-Mgmt-Path-Warning on the inbound interface"; }
echo "  $warn"
echo "$warn" | grep -q "interface=$iface" || fail "warning names the wrong interface: $warn"
echo "$warn" | grep -q "changed=disabled" || fail "warning names the wrong field: $warn"

echo "--- an unwatched field on the same interface does not warn ---"
curl -sS -D /tmp/uapi_mgmt_h2 -o /dev/null -H "$ADMIN" -H 'Content-Type: application/json' \
	-X PATCH "$URL/network/interfaces/$iface" -d '{"metric":7}'
tr -d '\r' < /tmp/uapi_mgmt_h2 | grep -qi '^X-Mgmt-Path-Warning:' \
	&& fail "warned on a field outside the watched set"
echo "  ok"

echo "--- a watched field on some other interface does not warn ---"
$SSH 'uci -q delete network.mgmtprobe; uci commit network' >/dev/null 2>&1 || true
curl -sS -o /dev/null -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/network/interfaces" \
	-d '{"id":"mgmtprobe","proto":"static","ipaddr":"192.168.221.1/24"}'
curl -sS -D /tmp/uapi_mgmt_h3 -o /dev/null -H "$ADMIN" -H 'Content-Type: application/json' \
	-X PATCH "$URL/network/interfaces/mgmtprobe" -d '{"proto":"dhcp"}'
tr -d '\r' < /tmp/uapi_mgmt_h3 | grep -qi '^X-Mgmt-Path-Warning:' \
	&& fail "warned about an interface the request did not arrive through"
echo "  ok"

echo "--- deleting the inbound interface would warn, deleting another does not ---"
curl -sS -D /tmp/uapi_mgmt_h4 -o /dev/null -H "$ADMIN" -X DELETE "$URL/network/interfaces/mgmtprobe"
tr -d '\r' < /tmp/uapi_mgmt_h4 | grep -qi '^X-Mgmt-Path-Warning:' \
	&& fail "warned on deleting an unrelated interface"
echo "  ok (the inbound-interface delete is not exercised here: it would strand the test)"

$SSH "uci -q delete network.$iface.disabled
      uci -q delete network.$iface.metric
      uci -q delete network.mgmtprobe
      uci commit network" >/dev/null 2>&1 || true

echo "PASS 48_mgmt_path_guard_test"
