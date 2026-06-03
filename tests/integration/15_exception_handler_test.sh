#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# Replace the system resource module with one whose fromUci throws. The
# exception propagates up through dispatch and must be caught by the top-level
# handler in global.handle_request, which returns a 500 internal_error envelope
# with X-Request-Id and emits an ERROR audit + uapi-internal trace.
echo "--- inject a broken system.uc that throws on fromUci ---"
$SSH 'cp /usr/share/uapi/resources/system.uc /usr/share/uapi/resources/system.uc.bak'
$SSH "cat > /usr/share/uapi/resources/system.uc <<'UCEND'
function fromUci(section) {
    die(\"intentional test crash from system.fromUci\");
}
function toUci(json) { return {}; }
function validate(json, conn) { return []; }
return {
    package: \"system\",
    type: \"system\",
    reload: [],
    fromUci, toUci, validate,
};
UCEND
"
$SSH '/etc/init.d/uhttpd restart'
sleep 2

cleanup() {
	$SSH 'mv /usr/share/uapi/resources/system.uc.bak /usr/share/uapi/resources/system.uc; /etc/init.d/uhttpd restart' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "--- GET /system → expect 500 internal_error envelope with X-Request-Id ---"
resp=$(curl -sS -i -w "\n%{http_code}" -H "$ADMIN" "$URL/system")
echo "$resp" | head -20
status=$(echo "$resp" | tail -1)
[ "$status" = "500" ] || fail "expected 500, got $status"
req_id=$(echo "$resp" | tr -d '\r' | sed -n 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
[ -n "$req_id" ] || fail "no X-Request-Id on 500 response"
echo "$resp" | grep -q '"code": "internal_error"' || fail "missing internal_error code in body"

echo "--- syslog has ERROR audit + uapi-internal trace for $req_id ---"
sleep 1
$SSH "logread | tail -200" > /tmp/uapi_excn_log.txt
grep -F "$req_id" /tmp/uapi_excn_log.txt | grep -q 'ERROR' \
	|| { cat /tmp/uapi_excn_log.txt; fail "no ERROR audit for $req_id"; }
grep -F "uapi-internal $req_id" /tmp/uapi_excn_log.txt \
	|| { cat /tmp/uapi_excn_log.txt; fail "no uapi-internal $req_id trace"; }
rm -f /tmp/uapi_excn_log.txt

echo "top-level exception handler returns envelope + emits ERROR audit + uapi-internal trace."
