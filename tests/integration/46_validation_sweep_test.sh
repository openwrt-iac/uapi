#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
SSH="tests/vm/ssh.sh"

echo "--- /diagnostics without ?validate=1 carries none of the sweep keys ---"
curl -sS -o /tmp/uapi_sweep_off.json -H "$ADMIN" "$URL/diagnostics" >/dev/null
grep -q '"version"' /tmp/uapi_sweep_off.json || fail "plain diagnostics broken"
for k in invalid_sections swept_resources skipped_for_scope; do
	grep -q "\"$k\"" /tmp/uapi_sweep_off.json && fail "plain diagnostics leaked $k"
done

echo "--- ?validate=1 sweeps and reports what it swept ---"
status=$(curl -sS -o /tmp/uapi_sweep_on.json -w '%{http_code}' -H "$ADMIN" \
	"$URL/diagnostics?validate=1")
[ "$status" = "200" ] || fail "sweep expected 200, got $status"
for k in invalid_sections swept_resources skipped_for_scope; do
	grep -q "\"$k\"" /tmp/uapi_sweep_on.json || fail "sweep missing $k"
done
grep -q '"firewall:rules"' /tmp/uapi_sweep_on.json || fail "sweep did not cover firewall:rules"
# Singletons live in their own registry and were once omitted entirely.
grep -q '"firewall:defaults"' /tmp/uapi_sweep_on.json || fail "sweep did not cover singletons"

echo "--- a section a write would reject is reported, with its reason ---"
# A port match on proto all: fw4 already widens this to the whole protocol, so
# the section is broken on the box today and the sweep is the first thing to say so.
$SSH 'uci set firewall.sweepprobe=rule
uci set firewall.sweepprobe.name=sweepprobe
uci set firewall.sweepprobe.src=wan
uci set firewall.sweepprobe.target=ACCEPT
uci add_list firewall.sweepprobe.proto=all
uci add_list firewall.sweepprobe.dest_port=22
uci commit firewall' >/dev/null
curl -sS -o /tmp/uapi_sweep_bad.json -H "$ADMIN" "$URL/diagnostics?validate=1" >/dev/null
grep -q 'sweepprobe' /tmp/uapi_sweep_bad.json || fail "sweep did not report the planted section"
grep -q 'match.proto' /tmp/uapi_sweep_bad.json || fail "sweep did not name the offending field"
$SSH 'uci delete firewall.sweepprobe; uci commit firewall' >/dev/null

echo "--- clean again once the section is gone ---"
curl -sS -o /tmp/uapi_sweep_clean.json -H "$ADMIN" "$URL/diagnostics?validate=1" >/dev/null
grep -q 'sweepprobe' /tmp/uapi_sweep_clean.json && fail "sweep still reports a removed section"

echo "--- the sweep is scoped per resource, and says what it skipped ---"
# uapi:diagnostics:ro opens the endpoint; each resource still needs its own :ro,
# because findings name sections and quote configured values. An empty result must
# be distinguishable from "not allowed to look". Asserted on the arrays rather than
# by grepping the body: every resource key also appears in resources_loaded, so a
# substring match here would pass even with both arrays empty.
DIAG_ONLY=$($SSH 'uapi-token create --name test_sweep_diag_only --scope "uapi:diagnostics:ro"' 2>/dev/null | head -1)
curl -sS -o /tmp/uapi_sweep_diag.json -H "Authorization: Bearer $DIAG_ONLY" \
	"$URL/diagnostics?validate=1" >/dev/null
python3 - /tmp/uapi_sweep_diag.json <<'PY' || fail "diagnostics-only token: wrong sweep scope"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["swept_resources"] == [], f"swept {d['swept_resources']} without resource scope"
assert "firewall:rules" in d["skipped_for_scope"], "skipped_for_scope did not name what was left out"
assert d["invalid_sections"] == [], "reported findings for resources it never swept"
PY

FW_DIAG=$($SSH 'uapi-token create --name test_sweep_fw_diag --scope "firewall:ro" --scope "uapi:diagnostics:ro"' 2>/dev/null | head -1)
curl -sS -o /tmp/uapi_sweep_fw.json -H "Authorization: Bearer $FW_DIAG" \
	"$URL/diagnostics?validate=1" >/dev/null
python3 - /tmp/uapi_sweep_fw.json <<'PY' || fail "firewall-reader token: wrong sweep scope"
import json, sys
d = json.load(open(sys.argv[1]))
swept, skipped = d["swept_resources"], d["skipped_for_scope"]
assert "firewall:rules" in swept, f"firewall reader swept {swept}"
assert all(k.startswith("firewall:") for k in swept), f"swept beyond its scope: {swept}"
assert "network:interfaces" in skipped, "network:interfaces should have been skipped"
PY

echo "PASS 46_validation_sweep_test"
