#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

UAPI_PREFIX="/api/v2=/usr/share/uapi/main.uc"

echo "--- uhttpd/instances: GET main shows uapi's ucode_prefix entry ---"
got=$(call "$URL/uhttpd/instances/main")
echo "$got" | head -1 | grep -q "$UAPI_PREFIX" \
	|| fail "main instance should already have $UAPI_PREFIX in ucode_prefix"

echo "--- uhttpd/instances: PATCH main without ucode_prefix is rejected with 422 conflict ---"
patch_response=$(call -X PATCH -H 'Content-Type: application/json' \
	"$URL/uhttpd/instances/main" -d '{ "ucode_prefix": [] }')
echo "$patch_response"
status=$(echo "$patch_response" | tail -1)
[ "$status" = "422" ] || fail "expected 422 (self-lockout block), got $status"
echo "$patch_response" | head -1 | grep -q '"code": "conflict"' \
	|| fail "expected field-level conflict on ucode_prefix"

echo "--- uhttpd/instances: PATCH main with bogus listen_http is rejected with 422 invalid_format ---"
bad_listen=$(call -X PATCH -H 'Content-Type: application/json' \
	"$URL/uhttpd/instances/main" -d '{ "listen_http": ["not-a-host:port"] }')
echo "$bad_listen" | tail -1 | grep -q '^422$' \
	|| fail "expected 422 on bad listen_http format"

echo "--- uhttpd/instances: PATCH main that keeps the uapi prefix is accepted ---"
# The PATCH triggers /etc/init.d/uhttpd reload, which restarts the very uhttpd
# serving this curl, so the response may arrive as a clean 200 or as curl exit
# 52 (empty reply) depending on the reload timing. Treat both as "accepted";
# confirm via a follow-up GET that the change actually took effect.
patch_set=$(curl -sS -o /dev/null -w '%{http_code}' \
	-H "$ADMIN" -H 'Content-Type: application/json' \
	-X PATCH "$URL/uhttpd/instances/main" \
	-d "{\"ucode_prefix\": [\"$UAPI_PREFIX\", \"/dummy=/usr/share/uapi/main.uc\"]}" || true)
case "$patch_set" in
	200|000) ;;  # 200 = clean response; 000 = curl couldn't read response (uhttpd restarting)
	*) fail "expected PATCH to be accepted (200 or empty-reply 000), got $patch_set" ;;
esac

# Give uhttpd a moment to finish the restart, then confirm the change took.
for i in 1 2 3 4 5; do
	body=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" "$URL/uhttpd/instances/main") || true
	[ "$body" = "200" ] && break
	sleep 1
done
got=$(call "$URL/uhttpd/instances/main")
echo "$got" | head -1 | grep -q '/dummy=/usr/share/uapi/main.uc' \
	|| fail "PATCH did not persist (no /dummy prefix in GET response)"
echo "$got" | head -1 | grep -q "$UAPI_PREFIX" \
	|| fail "PATCH dropped the uapi prefix despite the lockout guard"

echo "--- uhttpd/instances: revert the dummy prefix (cleanup) ---"
curl -sS -o /dev/null -H "$ADMIN" -H 'Content-Type: application/json' \
	-X PATCH "$URL/uhttpd/instances/main" \
	-d "{\"ucode_prefix\": [\"$UAPI_PREFIX\"]}" || true
for i in 1 2 3 4 5; do
	curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" "$URL/uhttpd/instances/main" 2>/dev/null \
		| grep -q '^200$' && break
	sleep 1
done

echo "uhttpd/instances self-lockout protection ok."
