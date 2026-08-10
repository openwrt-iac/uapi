#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
fail() { echo "FAIL: $*"; exit 1; }

# install_uapi creates /etc/uapi.insecure so the rest of the suite can use plain
# HTTP. Drop it for this test only, then put it back on exit so subsequent tests
# keep working regardless of run order.
$SSH 'rm -f /etc/uapi.insecure'
trap '$SSH "touch /etc/uapi.insecure"' EXIT INT TERM

echo "--- plain HTTP from non-loopback (REMOTE_ADDR=10.0.2.2 via qemu user-net) ---"
resp=$(curl -sS -w "\n%{http_code}" -H "Authorization: Bearer $ADMIN_TOKEN" "$URL/system")
echo "$resp"
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "403" ] || fail "expected 403, got $status"
echo "$body" | grep -q '"code": "tls_required"' || fail "missing tls_required code"

echo "--- TLS check fires BEFORE auth: no header still gives 403, not 401 ---"
no_auth=$(curl -sS -w "\n%{http_code}" "$URL/system")
echo "$no_auth"
status=$(echo "$no_auth" | tail -1)
[ "$status" = "403" ] || fail "expected 403 (TLS gate before auth), got $status"
echo "$no_auth" | grep -q '"code": "tls_required"' || fail "missing tls_required code"

echo "--- TLS gate fires before auth even for bad token (still 403, not 401) ---"
bad=$(curl -sS -w "\n%{http_code}" -H "Authorization: Bearer not-a-real-token" "$URL/system")
status=$(echo "$bad" | tail -1)
[ "$status" = "403" ] || fail "expected 403 with bad token (TLS first), got $status"

echo "--- loopback bypass still works inside the VM (REMOTE_ADDR=127.0.0.1) ---"
# busybox wget on OpenWrt does plain HTTP fine; healthz needs no token.
healthz=$($SSH "wget -qO- http://127.0.0.1/api/v3/healthz")
echo "$healthz"
echo "$healthz" | grep -q '"status": "ok"' || fail "loopback healthz did not respond ok"

echo "tls_required gate works."
