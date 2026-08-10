#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# Test 1: requests that bypass TLS via /etc/uapi.insecure emit a syslog NOTICE.
echo "--- request via non-loopback passes via .insecure marker ---"
req_id=$(curl -sS -o /dev/null -D - -H "$ADMIN" "$URL/system" | tr -d '\r' \
    | sed -n 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
[ -n "$req_id" ] || fail "no X-Request-Id on insecure-bypass request"
sleep 1
$SSH "logread | tail -200" > /tmp/uapi_obs_log.txt
grep -F "uapi-insecure-bypass" /tmp/uapi_obs_log.txt | grep -F "$req_id" \
    || { cat /tmp/uapi_obs_log.txt; fail "no uapi-insecure-bypass line for $req_id"; }

# Test 1b: a WRITE request via the bypass still emits the standard AUDIT line
# in addition to the uapi-insecure-bypass NOTICE. Confirms the bypass doesn't
# silence the audit trail.
echo "--- write via .insecure bypass emits BOTH audit + bypass NOTICE ---"
write_id=$(curl -sS -o /dev/null -D - -H "$ADMIN" -H 'Content-Type: application/json' \
    -X PATCH "$URL/system" -d '{"description": "obs-bypass-audit-test"}' | tr -d '\r' \
    | sed -n 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
[ -n "$write_id" ] || fail "no X-Request-Id on bypass-write"
sleep 1
$SSH "logread | tail -200" > /tmp/uapi_obs_log.txt
grep -F "$write_id" /tmp/uapi_obs_log.txt | grep -F "uapi-insecure-bypass" \
    || { cat /tmp/uapi_obs_log.txt; fail "no uapi-insecure-bypass line for write $write_id"; }
grep -F "$write_id" /tmp/uapi_obs_log.txt | grep -E "AUDIT|NOTICE" | grep -F "PATCH" \
    || { cat /tmp/uapi_obs_log.txt; fail "no AUDIT line for bypass-write $write_id"; }

# Test 2: ACCESS knob logs every request at INFO when enabled.
# Test 3: DEBUG knob traces ubus calls when enabled.
# LOGGING is loaded at uhttpd parent boot, so we must restart uhttpd after
# editing /etc/config/uapi.
echo "--- enable access and debug logging, restart uhttpd ---"
$SSH "
    printf '\nconfig logging \"observability\"\n    option access %s\n    option debug %s\n' \"'1'\" \"'1'\" >> /etc/config/uapi
    /etc/init.d/uhttpd restart
"
sleep 2

echo "--- a /system request now produces an ACCESS line ---"
req_id=$(curl -sS -o /dev/null -D - -H "$ADMIN" "$URL/system" | tr -d '\r' \
    | sed -n 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
[ -n "$req_id" ] || fail "no X-Request-Id on access-logged request"
sleep 1
$SSH "logread | tail -200" > /tmp/uapi_obs_log.txt
grep -F "$req_id" /tmp/uapi_obs_log.txt | grep -q 'ACCESS' \
    || { cat /tmp/uapi_obs_log.txt; fail "no ACCESS line for $req_id"; }

echo "--- a /healthz request produces a DEBUG ubus-call trace (system.info probe) ---"
curl -sS -o /dev/null "$URL/healthz"
sleep 1
$SSH "logread | tail -200" > /tmp/uapi_obs_log.txt
grep -F "uapi-bus call system.info" /tmp/uapi_obs_log.txt \
	|| { cat /tmp/uapi_obs_log.txt; fail "no DEBUG ubus-call trace for system.info"; }

rm -f /tmp/uapi_obs_log.txt

echo "observability knobs (.insecure marker / ACCESS / DEBUG) all emit expected lines."
