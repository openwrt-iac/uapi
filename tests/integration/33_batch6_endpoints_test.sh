#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
SSH="tests/vm/ssh.sh"

# Wipe per-test state so a previous run doesn't poison this one.
$SSH 'rm -rf /var/run/uapi-metrics /var/run/uapi-idempotency /var/run/uapi-ratelimit /var/run/uapi-error-ring /var/run/uapi-token-update' >/dev/null 2>&1 || true

echo "--- /metrics returns Prometheus text under *:ro ---"
# Generate a couple of requests so there's data to scrape.
curl -sS -o /dev/null -H "$ADMIN" "$URL/firewall/rules"
curl -sS -o /dev/null -H "$ADMIN" "$URL/system"
body=$(curl -sS -H "$ADMIN" "$URL/metrics")
echo "$body" | grep -q 'uapi_requests_total{' || fail "metrics: uapi_requests_total missing"
echo "$body" | grep -q 'uapi_request_duration_seconds_bucket' || fail "metrics: histogram missing"
echo "$body" | grep -q 'path="/firewall/rules",status="200"' || fail "metrics: a route lost its path label"

echo "--- /metrics gives one path label to every path that no route serves ---"
curl -sS -o /dev/null "$URL/nope_$(date +%s)_a/x"
curl -sS -o /dev/null "$URL/raw/nope_$(date +%s)_b/x"
curl -sS -o /dev/null -H "$ADMIN" "$URL/firewall/nope_$(date +%s)_c"
body=$(curl -sS -H "$ADMIN" "$URL/metrics")
echo "$body" | grep -q 'nope_' && fail "metrics: a path that no route serves has its own label"
echo "$body" | grep -q 'path="unmatched",status="401",token_id="-"} 2$' \
	|| fail "metrics: two unknown paths are not one unmatched series of 2"
echo "$body" | grep -q 'path="unmatched",status="404",token_id="test_admin"} 1$' \
	|| fail "metrics: the unknown path with a token is not one unmatched series"

echo "--- /metrics rejected with insufficient_scope when token lacks ro ---"
# A token with only firewall:ro should NOT be able to read metrics.
status=$(curl -sS -o /tmp/uapi_metrics_403.json -w '%{http_code}' \
	-H "Authorization: Bearer $FW_RO_TOKEN" "$URL/metrics")
[ "$status" = "403" ] || fail "metrics scope check failed, got $status"
grep -q 'insufficient_scope' /tmp/uapi_metrics_403.json || fail "expected insufficient_scope"

echo "--- /diagnostics returns version + uptime + resources_loaded ---"
status=$(curl -sS -o /tmp/uapi_diag.json -w '%{http_code}' -H "$ADMIN" "$URL/diagnostics")
[ "$status" = "200" ] || fail "diagnostics expected 200, got $status"
grep -q '"version"'           /tmp/uapi_diag.json || fail "diag missing version"
grep -q '"uptime_seconds"'    /tmp/uapi_diag.json || fail "diag missing uptime_seconds"
grep -q '"resources_loaded"'  /tmp/uapi_diag.json || fail "diag missing resources_loaded"
grep -q '"lock_state"'        /tmp/uapi_diag.json || fail "diag missing lock_state"
grep -q '"firewall:rules"'    /tmp/uapi_diag.json || fail "diag missing firewall:rules in resources"

echo "--- /diagnostics denied for token without uapi:diagnostics:ro ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' \
	-H "Authorization: Bearer $FW_RO_TOKEN" "$URL/diagnostics")
[ "$status" = "403" ] || fail "diag scope check failed, got $status"

echo "--- Idempotency-Key replays POST result on second use ---"
# uhttpd CGI env allowlist strips Idempotency-Key; we pass it via the
# ?idempotency_key= query param. Proxies that forward the header still work.
key1="idem-$(date +%s)-1"
first=$(curl -sS -D /tmp/uapi_idem1.h -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules?idempotency_key=$key1" -d '{
		"name": "idem-test-1",
		"target": "ACCEPT",
		"enabled": true,
		"match": { "src_zone": "wan", "proto": ["tcp"], "dest_port": ["18080"] }
	}')
id1=$(printf '%s' "$first" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
[ -n "$id1" ] || fail "first POST missing id: $first"
trap "curl -sS -o /dev/null -H \"$ADMIN\" -X DELETE \"$URL/firewall/rules/$id1\" || true" EXIT INT TERM

# Replay - should NOT create a second rule; should return cached body.
second=$(curl -sS -D /tmp/uapi_idem2.h -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules?idempotency_key=$key1" -d '{
		"name": "idem-test-1",
		"target": "ACCEPT",
		"enabled": true,
		"match": { "src_zone": "wan", "proto": ["tcp"], "dest_port": ["18080"] }
	}')
id2=$(printf '%s' "$second" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
[ "$id1" = "$id2" ] || fail "idempotent replay returned different id: $id1 vs $id2"
grep -i '^idempotent-replayed:' /tmp/uapi_idem2.h >/dev/null \
	|| fail "expected Idempotent-Replayed: true header on replay"

echo "--- same key + different body returns 409 idempotency_key_conflict ---"
status=$(curl -sS -o /tmp/uapi_idem_conflict.json -w '%{http_code}' \
	-H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules?idempotency_key=$key1" -d '{
		"name": "different-body",
		"target": "ACCEPT",
		"match": { "src_zone": "wan" }
	}')
[ "$status" = "409" ] || fail "idem same-key-different-body expected 409, got $status"
grep -q 'idempotency_key_conflict' /tmp/uapi_idem_conflict.json \
	|| fail "expected idempotency_key_conflict code"

echo "--- malformed idempotency_key returns 400 ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' \
	-H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules?idempotency_key=bad+key+with+spaces" -d '{
		"name": "x",
		"target": "ACCEPT",
		"match": { "src_zone": "wan" }
	}')
[ "$status" = "400" ] || fail "bad idempotency key expected 400, got $status"

echo "--- the idempotency cache is private, and a batch that only reads leaves no entry ---"
[ "$($SSH 'ls -ld /var/run/uapi-idempotency' | cut -c1-10)" = "drwx------" ] || fail "the idempotency directory is not 0700"
[ -z "$($SSH 'ls -l /var/run/uapi-idempotency' | grep -v -e '^total' -e '^-rw------- ')" ] || fail "an idempotency entry is not 0600"
before=$($SSH 'ls /var/run/uapi-idempotency | wc -l')
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/batch?idempotency_key=idem-$(date +%s)-read" \
	-d '{"operations": [{"method": "GET", "path": "/firewall/rules"}]}')
[ "$status" = "207" ] || fail "a batch that only reads expected 207, got $status"
[ "$($SSH 'ls /var/run/uapi-idempotency | wc -l')" = "$before" ] || fail "a batch that only reads left an idempotency entry"
key_w="idem-$(date +%s)-write"
batch_w='{"operations": [{"method": "PATCH", "path": "/firewall/rules/'"$id1"'", "body": {"name": "idem-test-1b"}}]}'
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/batch?idempotency_key=$key_w" -d "$batch_w")
[ "$status" = "207" ] || fail "a batch that writes expected 207, got $status"
[ "$($SSH 'ls /var/run/uapi-idempotency | wc -l')" = "$((before + 1))" ] || fail "a batch that writes left no idempotency entry"
curl -sS -o /dev/null -D /tmp/uapi_idem_batch.h -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/batch?idempotency_key=$key_w" -d "$batch_w"
grep -i '^idempotent-replayed:' /tmp/uapi_idem_batch.h >/dev/null || fail "the replay of a batch that writes is not marked replayed"

echo "--- every state directory is 0700 and every file in it 0600 ---"
dirs="/var/run/uapi-idempotency /var/run/uapi-metrics /var/run/uapi-ratelimit /var/run/uapi-error-ring /var/run/uapi-token-update"
for d in $dirs; do $SSH "test -d $d" || fail "$d is missing"; done
wrong=$($SSH "find $dirs \( -type f ! -perm 600 \) -o \( -type d ! -perm 700 \)")
[ -z "$wrong" ] || fail "these are not 0700 or 0600: $wrong"

echo "--- pagination: ?limit=N returns a partial page + Link/X-Next-Cursor ---"
# firewall/rules typically has zero managed entries on a clean install.
# Use raw to count anything, then test pagination on a real busy resource.
# Easier: just test on firewall/zones which always has at least lan + wan.
zone_count=$(curl -sS -H "$ADMIN" "$URL/firewall/zones" \
	| grep -o '"id":' | wc -l)
if [ "$zone_count" -lt 2 ]; then
	echo "  skip pagination test (need >=2 zones, found $zone_count)"
else
	pheaders=$(curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/firewall/zones?limit=1")
	echo "$pheaders" | tr -d '\r' | grep -qi '^x-next-cursor:' \
		|| fail "?limit=1 must emit X-Next-Cursor when more items exist"
	echo "$pheaders" | tr -d '\r' | grep -qi '^link:.*rel="next"' \
		|| fail "?limit=1 must emit Link rel=next"
fi

echo "--- pagination: malformed cursor returns 400 invalid_cursor ---"
status=$(curl -sS -o /tmp/uapi_invalid_cursor.json -w '%{http_code}' \
	-H "$ADMIN" "$URL/firewall/zones?cursor=bogus")
[ "$status" = "400" ] || fail "bad cursor expected 400, got $status"
grep -q 'invalid_cursor' /tmp/uapi_invalid_cursor.json \
	|| fail "expected invalid_cursor code"

echo "--- rate limit: normal traffic is not rate-limited ---"
# The 429 + Retry-After path needs a token with a tight override, which lives in
# 32_tokens_route_test.sh; against the generous server defaults all this can say
# is that ordinary traffic passes.
final_status=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" "$URL/firewall/rules")
[ "$final_status" != "429" ] || fail "normal traffic must not be rate-limited"

echo "Batch 6 endpoints ok."
