#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# apply-confirm is a separate package (RC-soak; not on the stable feed yet).
# When it is installable, run the full stage -> ack / stage -> timeout-rollback
# happy path; otherwise verify the graceful-degrade contract (501 when absent,
# ordinary writes unaffected). Same shape as 40_unbound_uci_ext_test.sh.
if $SSH 'apk add apply-confirm 2>/dev/null' && $SSH 'test -x /usr/sbin/apply-confirm'; then
	HAVE_AC=1
	echo "[apply-confirm] installed; running full commit-confirm path"
else
	HAVE_AC=0
	echo "[apply-confirm] not installable on this VM; running 501 graceful-degrade smoke only"
fi

cleanup() { $SSH 'uci -q delete firewall.acc_test 2>/dev/null; uci -q commit firewall 2>/dev/null || true'; }
trap cleanup EXIT INT TERM

if [ "$HAVE_AC" = 0 ]; then
	echo "--- confirmed write returns 501 confirm_unavailable when apply-confirm is absent ---"
	# Use the ?confirm= query fallback: uhttpd CGI drops custom request headers
	# (the reason the fallback exists), so X-Uapi-Confirm is unreliable here.
	code=$(curl -sS -o /tmp/ac_body.json -w '%{http_code}' -H "$ADMIN" \
		-H 'Content-Type: application/json' \
		-X POST "$URL/firewall/rules?confirm=60" \
		-d '{"id":"acc_test","target":"ACCEPT","match":{"src_zone":"lan"}}')
	[ "$code" = "501" ] || { cat /tmp/ac_body.json; fail "expected 501, got $code"; }
	grep -q '"code": "confirm_unavailable"' /tmp/ac_body.json || fail "expected confirm_unavailable"

	echo "--- the rejected confirmed write committed nothing ---"
	[ -z "$($SSH 'uci -q get firewall.acc_test.target' 2>/dev/null || true)" ] \
		|| fail "501 confirmed write must not have committed the section"

	echo "--- a normal (unconfirmed) write is unaffected ---"
	code=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" \
		-H 'Content-Type: application/json' \
		-X POST "$URL/firewall/rules" \
		-d '{"id":"acc_test","target":"ACCEPT","match":{"src_zone":"lan"}}')
	[ "$code" = "200" ] || fail "normal write expected 200, got $code"

	echo "--- GET /confirm also degrades to 501 ---"
	code=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" "$URL/confirm")
	[ "$code" = "501" ] || fail "GET /confirm expected 501 when absent, got $code"

	echo "apply-confirm graceful-degrade smoke ok."
	exit 0
fi

echo "--- confirmed write returns 202 + a confirm token ---"
resp=$(curl -sS -D /tmp/ac_hdr.txt -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules?confirm=30" \
	-d '{"id":"acc_test","target":"ACCEPT","match":{"src_zone":"lan"}}')
echo "$resp" | grep -q '"confirm"' || fail "202 body missing confirm block: $resp"
head -1 /tmp/ac_hdr.txt | grep -q '202' || fail "expected 202 status"
token=$(echo "$resp" | jq -r '.confirm.token')
[ -n "$token" ] && [ "$token" != "null" ] || fail "no confirm token in body"
[ "$($SSH 'uci -q get firewall.acc_test.target')" = "ACCEPT" ] || fail "confirmed write did not commit"

echo "--- POST /confirm/<token> acks; the change persists ---"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" -X POST "$URL/confirm/$token")
[ "$code" = "200" ] || fail "ack expected 200, got $code"
sleep 2
[ "$($SSH 'uci -q get firewall.acc_test.target')" = "ACCEPT" ] || fail "acked change was rolled back"
$SSH 'uci -q delete firewall.acc_test; uci commit firewall'

echo "--- confirmed write left unacked rolls back at the deadline ---"
resp=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules?confirm=3" \
	-d '{"id":"acc_test","target":"ACCEPT","match":{"src_zone":"lan"}}')
token=$(echo "$resp" | jq -r '.confirm.token')
[ -n "$token" ] && [ "$token" != "null" ] || fail "no token for timeout test"
[ "$($SSH 'uci -q get firewall.acc_test.target')" = "ACCEPT" ] || fail "write not committed pre-timeout"
sleep 8
[ -z "$($SSH 'uci -q get firewall.acc_test.target' 2>/dev/null || true)" ] \
	|| fail "unacked change was not rolled back after the deadline"

echo "apply-confirm commit-confirm path ok."
