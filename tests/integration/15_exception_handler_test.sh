#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v4
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# Replace the system resource module with one whose fromUci throws. The
# exception propagates up through dispatch and must be caught by the top-level
# handler in global.handle_request, which returns a 500 internal_error envelope
# with X-Request-Id and emits an ERROR audit + uapi-internal trace.
echo "--- inject a broken system.uc that throws on fromUci ---"
$SSH 'cp /usr/share/uapi/resources/system.uc /usr/share/uapi/resources/system.uc.bak'
# A throw before auth, while /tmp/uapi-crash-auth exists.
$SSH "cp /usr/share/uapi/lib/token_store.uc /usr/share/uapi/lib/token_store.uc.bak && sed -i 's|^function list_for_auth(conn) {|function list_for_auth(conn) { if (require(\"fs\").stat(\"/tmp/uapi-crash-auth\") != null) die(\"intentional test crash before auth\");|' /usr/share/uapi/lib/token_store.uc"
$SSH 'grep -q "intentional test crash before auth" /usr/share/uapi/lib/token_store.uc' \
	|| fail "could not inject the throw before auth"
$SSH "cat > /usr/share/uapi/resources/system.uc <<'UCEND'
let fs = require('fs');
function fromUci(section) {
    if (fs.stat('/tmp/uapi-crash-type') != null) {
        let v = 'uapi-type-error-marker';
        return [...v];
    }
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
	$SSH 'rm -f /tmp/uapi-crash-type /tmp/uapi-crash-auth; mv /usr/share/uapi/resources/system.uc.bak /usr/share/uapi/resources/system.uc; mv /usr/share/uapi/lib/token_store.uc.bak /usr/share/uapi/lib/token_store.uc; /etc/init.d/uhttpd restart' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "--- GET /system → expect 500 internal_error envelope with the X-Request-Id of the client ---"
sent_id="it15-exception-$$"
resp=$(curl -sS -i -w "\n%{http_code}" -H "$ADMIN" -H "X-Request-Id: $sent_id" "$URL/system")
echo "$resp" | head -20
status=$(echo "$resp" | tail -1)
[ "$status" = "500" ] || fail "expected 500, got $status"
req_id=$(echo "$resp" | tr -d '\r' | sed -n 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
[ "$req_id" = "$sent_id" ] || fail "the 500 answered X-Request-Id '$req_id', not the one that the client sent"
echo "$resp" | grep -q '"code": "internal_error"' || fail "missing internal_error code in body"

echo "--- syslog has ERROR audit + uapi-internal trace for $req_id ---"
sleep 1
$SSH "logread | tail -200" > /tmp/uapi_excn_log.txt
grep -qF "$req_id test_admin ERROR internal_error GET /system 500" /tmp/uapi_excn_log.txt \
	|| { cat /tmp/uapi_excn_log.txt; fail "no ERROR audit for $req_id with the name of the token"; }
grep -F "uapi-internal $req_id: intentional test crash from system.fromUci" /tmp/uapi_excn_log.txt \
	|| { cat /tmp/uapi_excn_log.txt; fail "no uapi-internal $req_id trace with the text of die()"; }

# An error of the interpreter quotes the value that it failed on, so the line keeps only its
# type and place.
echo "--- a type error logs its type and place, not the value that it quotes ---"
$SSH 'touch /tmp/uapi-crash-type'
resp=$(curl -sS -i -w "\n%{http_code}" -H "$ADMIN" "$URL/system")
[ "$(echo "$resp" | tail -1)" = "500" ] || fail "expected 500 for the type error"
req_id=$(echo "$resp" | tr -d '\r' | sed -n 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
[ -n "$req_id" ] || fail "no X-Request-Id on the 500 of the type error"
sleep 1
$SSH "logread | tail -200" > /tmp/uapi_excn_log.txt
line=$(grep -F "uapi-internal $req_id" /tmp/uapi_excn_log.txt) \
	|| { cat /tmp/uapi_excn_log.txt; fail "no uapi-internal $req_id trace for the type error"; }
echo "$line"
echo "$line" | grep -qF "uapi-internal $req_id: Type error at /usr/share/uapi/resources/system.uc:" \
	|| fail "the line does not give the type and the place"
if echo "$line" | grep -qF "uapi-type-error-marker"; then fail "the line quotes the value"; fi
$SSH 'rm -f /tmp/uapi-crash-type'

echo "--- a throw before auth keeps the id of the client, and the audit line has no token ---"
sent_id="it15-before-auth-$$"
$SSH 'touch /tmp/uapi-crash-auth'
resp=$(curl -sS -i -w "\n%{http_code}" -H "$ADMIN" -H "X-Request-Id: $sent_id" "$URL/system")
$SSH 'rm -f /tmp/uapi-crash-auth'
[ "$(echo "$resp" | tail -1)" = "500" ] || fail "expected 500 for the throw before auth"
req_id=$(echo "$resp" | tr -d '\r' | sed -n 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
[ "$req_id" = "$sent_id" ] || fail "the 500 before auth answered X-Request-Id '$req_id', not the one that the client sent"
sleep 1
$SSH "logread | tail -200" > /tmp/uapi_excn_log.txt
grep -qF "$sent_id - ERROR internal_error GET /system 500" /tmp/uapi_excn_log.txt \
	|| { cat /tmp/uapi_excn_log.txt; fail "no ERROR audit for $sent_id with the token -"; }
grep -qF "uapi-internal $sent_id: intentional test crash before auth" /tmp/uapi_excn_log.txt \
	|| { cat /tmp/uapi_excn_log.txt; fail "no uapi-internal $sent_id trace for the throw before auth"; }
rm -f /tmp/uapi_excn_log.txt

echo "top-level exception handler returns envelope + emits ERROR audit + uapi-internal trace."
