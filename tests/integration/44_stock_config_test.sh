#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# Round-trip every section in every curated CRUD resource and singleton against
# the stock /etc/config/* files shipped by OpenWrt and its packages: GET the
# resource, adopt the section if unmanaged, PUT-self (or PATCH-self for
# singletons) with the body we just read, then GET-self again and assert the
# persistable body did not drift. A 422 or a diff surfaces a regression where
# uapi rejects (or silently mutates) what the platform itself ships. The
# 2.2.0-rc2 dhcp-host, 2.2.1 snmpd.groups, and 2.2.2 clear-on-omit bugs are the
# original forcing cases.
#
# Sections come from the stock configs of the installed packages, so we install
# a handful of common packages here to broaden coverage beyond the bare image.
# Each package brings its own /etc/config/<name> with sections we then exercise.
#
# IMPORTANT: keep this test LAST-numbered in tests/integration/. PUT-self
# cumulatively rewrites the VM's /etc/config/* via toUci, which drops uci
# options not in any resource's schema_properties (e.g. firewall.rules'
# `option limit` / `list icmp_type`). Any subsequent test that depends on
# pristine stock state would see drift.
#
# Note on package naming: the package is 'vnstat2' (the v2 fork shipping in the
# 25.12 feed) but the uci config and the resource paths are 'vnstat'.

# Coverage scope: every curated resource whose package ships in the bare
# OpenWrt 25.12.4 image. Resources for packages outside the bare image
# (snmpd, lldpd, vnstat, mwan3, unbound, sqm, usteer, prometheus_node_
# exporter_lua, openvpn) are deferred to a follow-up that wires the apk
# install at VM-setup time instead of inside an integration test. Earlier
# attempts to install them in install_uapi.sh's bootstrap or inline from
# this test surfaced a QEMU SLIRP "wget EPERM after state churn"
# pathology that ate hours of CI; not worth blocking 2.3.0 over.
#
# Excluded:
#   - uhttpd/* : PUT-self restarts the daemon serving us
#   - wireless/* : needs hwsim radio bring-up; covered by dedicated tests
#   - dhcp/leases, dhcp/leases6 : read-only collections, no PUT route
#   - packages/* : non-uci semantics (apk shell-out)
#   - system/password, system/authorized_keys : non-uci write-only
RESOURCES="
firewall/zones
firewall/rules
firewall/redirects
firewall/forwardings
network/interfaces
network/devices
network/routes
network/rules
network/bridge_vlans
network/wireguard_peers
dhcp/hosts
dhcp/servers
dropbear/instances
system/timeservers
"

SINGLETONS="
system
firewall/defaults
dhcp/dnsmasq
dhcp/odhcpd
"

# Persistable shape: drop ephemeral / response-only fields. `id` and `managed`
# are derived; `runtime` reflects live state (interface up/down, last seen) and
# can legitimately change across a reload. `last_used_at` / `last_used_ip` on
# the token surface are similarly ephemeral; not in scope here but kept in the
# strip list for safety on resources that may grow such fields.
STRIP='del(.id, .managed, .runtime, .last_used_at, .last_used_ip)'

assert_no_drift() {
	# assert_no_drift <label> <before-json> <after-json>
	# jq -S sorts keys so the diff is meaningful even if the server emits
	# keys in a different order across two requests. Use temp files (not
	# process substitution) so the script stays POSIX-compatible with
	# /bin/sh on the Alpine host.
	label="$1"; before="$2"; after="$3"
	echo "$before" | jq -S "$STRIP" > /tmp/uapi_drift_before.json
	echo "$after"  | jq -S "$STRIP" > /tmp/uapi_drift_after.json
	if ! cmp -s /tmp/uapi_drift_before.json /tmp/uapi_drift_after.json; then
		echo "DRIFT on $label:"
		diff /tmp/uapi_drift_before.json /tmp/uapi_drift_after.json || true
		fail "round-trip mutated $label (PUT-self changed the persisted shape)"
	fi
}

echo "=== curated CRUD: GET -> adopt-if-needed -> PUT-self -> GET == before ==="
for res in $RESOURCES; do
	list=$(curl -sS -H "$ADMIN" "$URL/$res")
	ids=$(echo "$list" | jq -r '.[]?.id // empty')
	if [ -z "$ids" ]; then
		echo "  $res: no stock sections, skipping"
		continue
	fi
	for id in $ids; do
		body=$(curl -sS -H "$ADMIN" "$URL/$res/$id")
		managed=$(echo "$body" | jq -r '.managed')
		if [ "$managed" = "false" ]; then
			adopted=$(curl -sS -H "$ADMIN" -X POST "$URL/$res/$id/adopt")
			id=$(echo "$adopted" | jq -r '.id')
			[ -n "$id" ] && [ "$id" != "null" ] \
				|| fail "$res adopt: missing id in response"
			body=$(curl -sS -H "$ADMIN" "$URL/$res/$id")
		fi
		# The body carries id, managed, and runtime; toUci ignores fields not
		# in schema_properties, so we PUT it verbatim.
		status=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
			-o /tmp/uapi_put_resp.json -w '%{http_code}' \
			-X PUT "$URL/$res/$id" -d "$body")
		if [ "$status" != "200" ]; then
			cat /tmp/uapi_put_resp.json
			fail "PUT-self $res/$id returned $status (regression: stock config rejected by uapi)"
		fi
		after=$(curl -sS -H "$ADMIN" "$URL/$res/$id")
		assert_no_drift "$res/$id" "$body" "$after"
		echo "  ok: $res/$id"
	done
done

echo "=== singletons: GET -> PATCH-self -> GET == before ==="
# Singletons expose GET + PATCH (no PUT; see handler.make_singleton). PATCH
# with the body GET just returned is the singleton round-trip equivalent.
for s in $SINGLETONS; do
	get_status=$(curl -sS -H "$ADMIN" -o /tmp/uapi_sg_body.json -w '%{http_code}' "$URL/$s")
	if [ "$get_status" != "200" ]; then
		echo "  $s: GET returned $get_status, skipping"
		continue
	fi
	body=$(cat /tmp/uapi_sg_body.json)
	patch_status=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
		-o /tmp/uapi_put_resp.json -w '%{http_code}' \
		-X PATCH "$URL/$s" -d "$body")
	if [ "$patch_status" != "200" ]; then
		cat /tmp/uapi_put_resp.json
		fail "PATCH-self singleton $s returned $patch_status (regression: stock config rejected by uapi)"
	fi
	after=$(curl -sS -H "$ADMIN" "$URL/$s")
	assert_no_drift "$s" "$body" "$after"
	echo "  ok: $s"
done

echo "=== PATCH preserves uci options uapi does not model (RFC-hybrid) ==="
# Regression guard for the diff_apply silent-drop class: a partial PATCH must
# not delete options the resource doesn't model. `localservice` is a real
# dnsmasq option uapi does not curate; set it, PATCH a modeled field, and
# confirm it survives. The drift check above can't catch this (fromUci never
# surfaces unmodeled keys), so it needs a direct uci read.
$SSH "uci set dhcp.@dnsmasq[0].localservice='1'; uci commit dhcp"
patch_code=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-o /dev/null -w '%{http_code}' -X PATCH "$URL/dhcp/dnsmasq" -d '{"domain":"uapitest"}')
[ "$patch_code" = "200" ] || fail "PATCH /dhcp/dnsmasq returned $patch_code"
# `uci -q get` exits non-zero when the key is absent; `|| true` keeps the
# assignment from tripping `set -e` so the explicit check below reports clearly.
preserved=$($SSH "uci -q get dhcp.@dnsmasq[0].localservice" 2>/dev/null || true)
[ "$preserved" = "1" ] || fail "PATCH wiped unmodeled uci option localservice (silent_drop regression): got '$preserved'"
echo "  ok: unmodeled option survived PATCH"

# Note: the PUT-side counterpart (full replace DOES drop unmodeled options) is
# covered by the unit test handler_test.uc "normalizes away unmodeled uci
# options" and is already exercised by the round-trip loop above; no separate
# integration assertion here.

echo "stock-config round-trip ok"
