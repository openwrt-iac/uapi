#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
RO="Authorization: Bearer $RO_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
SSH="tests/vm/ssh.sh"

cleanup_tokens() {
	$SSH 'uapi-token revoke api_minted 2>/dev/null || true'
	$SSH 'uapi-token revoke api_shortlived 2>/dev/null || true'
	$SSH 'uapi-token revoke api_lan_only 2>/dev/null || true'
	$SSH 'uapi-token revoke api_rate_limited 2>/dev/null || true'
	$SSH 'uapi-token revoke api_strict_rl 2>/dev/null || true'
	$SSH 'uapi-token revoke cli_rl 2>/dev/null || true'
}
trap cleanup_tokens EXIT INT TERM
cleanup_tokens

echo "--- GET /tokens (admin lists tokens) ---"
status=$(curl -sS -o /tmp/uapi_tokens_list.json -w '%{http_code}' -H "$ADMIN" "$URL/tokens")
[ "$status" = "200" ] || fail "GET /tokens expected 200, got $status"
grep -q '"test_admin"' /tmp/uapi_tokens_list.json || fail "list missing test_admin"
grep -q '"hash"' /tmp/uapi_tokens_list.json && fail "list must not expose hash"
grep -q '"salt"' /tmp/uapi_tokens_list.json && fail "list must not expose salt"

echo "--- GET /tokens denied for ro caller (writes scope check excludes ro for create, but list needs *:ro - covered by *:rw) ---"
# ro token has *:ro which subsumes uapi:tokens:ro -> list is allowed.
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "$RO" "$URL/tokens")
[ "$status" = "200" ] || fail "RO list expected 200, got $status"

echo "--- POST /tokens (admin mints a new token) ---"
resp=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/tokens" -d '{
		"name": "api_minted",
		"scopes": ["firewall:rules:ro"]
	}')
echo "$resp" | grep -q '"bearer"' || fail "POST /tokens missing bearer: $resp"
bearer=$(echo "$resp" | sed -n 's/.*"bearer": *"\([^"]*\)".*/\1/p')
[ -n "$bearer" ] || fail "no bearer parsed"

echo "--- the minted bearer authenticates and is scoped as requested ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' \
	-H "Authorization: Bearer $bearer" "$URL/firewall/rules")
[ "$status" = "200" ] || fail "minted token cannot list firewall/rules: $status"
# But cannot mint another token (no uapi:tokens scope)
status=$(curl -sS -o /dev/null -w '%{http_code}' \
	-H "Authorization: Bearer $bearer" -X POST "$URL/tokens" -d '{
		"name": "would-be", "scopes": ["*:ro"]
	}' -H 'Content-Type: application/json')
[ "$status" = "403" ] || fail "minted ro token must not POST /tokens, got $status"

echo "--- POST /tokens scope escalation blocked (caller has firewall:ro asks for *:rw) ---"
# Mint a constrained token first
fw_ro_bearer=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/tokens" -d '{"name": "api_shortlived", "scopes": ["firewall:ro"]}' \
	| sed -n 's/.*"bearer": *"\([^"]*\)".*/\1/p')
[ -n "$fw_ro_bearer" ] || fail "could not mint constrained token"
status=$(curl -sS -o /dev/null -w '%{http_code}' \
	-H "Authorization: Bearer $fw_ro_bearer" -H 'Content-Type: application/json' \
	-X POST "$URL/tokens" -d '{"name": "evil", "scopes": ["*:rw"]}')
[ "$status" = "403" ] || fail "scope escalation expected 403, got $status"

echo "--- a token read and revoked by position is named, and its bucket, marker and series go with it ---"
# api_shortlived is the last token in the file, and its request above created its state.
[ "$(curl -sS -g -H "$ADMIN" "$URL/tokens/@token[-1]" | jq -r .name)" = "api_shortlived" ] \
	|| fail "GET /tokens/@token[-1] did not name api_shortlived"
$SSH "test -e /tmp/uapi-ratelimit/api_shortlived.txt" || fail "api_shortlived has no bucket to reap"
$SSH "test -e /var/run/uapi-token-update/api_shortlived" || fail "api_shortlived has no marker to reap"
curl -sS -H "$ADMIN" "$URL/metrics" | grep -q 'token_id="api_shortlived"' \
	|| fail "api_shortlived has no series to fold"
status=$(curl -sS -g -o /dev/null -w '%{http_code}' -H "$ADMIN" -X DELETE "$URL/tokens/@token[-1]")
[ "$status" = "204" ] || fail "DELETE /tokens/@token[-1] expected 204, got $status"
$SSH "test -e /tmp/uapi-ratelimit/api_shortlived.txt" && fail "the revoke by position left the bucket"
$SSH "test -e /var/run/uapi-token-update/api_shortlived" && fail "the revoke left the last-used marker"
metrics=$(curl -sS -H "$ADMIN" "$URL/metrics")
echo "$metrics" | grep -q 'token_id="api_shortlived"' && fail "the revoke left the series of the token"
echo "$metrics" | grep -q 'uapi_requests_total{.*token_id="-retired"}' \
	|| fail "the revoke folded no series into token_id=\"-retired\""

echo "--- DELETE /tokens/<id> returns 204 ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" \
	-X DELETE "$URL/tokens/api_minted")
[ "$status" = "204" ] || fail "DELETE expected 204, got $status"
# Subsequent auth attempts with that bearer fail
status=$(curl -sS -o /dev/null -w '%{http_code}' \
	-H "Authorization: Bearer $bearer" "$URL/firewall/rules")
[ "$status" = "401" ] || fail "revoked token still works: $status"

echo "--- POST /tokens with expires_in_seconds creates an expiring token ---"
short=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/tokens" -d '{
		"name": "api_shortlived_b", "scopes": ["firewall:rules:ro"],
		"expires_in_seconds": 3
	}')
short_bearer=$(echo "$short" | sed -n 's/.*"bearer": *"\([^"]*\)".*/\1/p')
[ -n "$short_bearer" ] || fail "no bearer in expiring-token response"
status=$(curl -sS -o /dev/null -w '%{http_code}' \
	-H "Authorization: Bearer $short_bearer" "$URL/firewall/rules")
[ "$status" = "200" ] || fail "expiring token fails immediately: $status"
sleep 5
status=$(curl -sS -o /tmp/uapi_expired_body.json -w '%{http_code}' \
	-H "Authorization: Bearer $short_bearer" "$URL/firewall/rules")
[ "$status" = "401" ] || fail "expired token still works: $status"
grep -q 'Token expired' /tmp/uapi_expired_body.json || fail "expected expired message"
$SSH "test -e /tmp/uapi-ratelimit/api_shortlived_b.txt" || fail "api_shortlived_b has no bucket to reap"

echo "--- POST /tokens with allowed_cidrs that excludes local addr returns 401 on use ---"
ip_scoped=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/tokens" -d '{
		"name": "api_lan_only", "scopes": ["firewall:rules:ro"],
		"allowed_cidrs": ["10.99.0.0/16"]
	}')
ip_bearer=$(echo "$ip_scoped" | sed -n 's/.*"bearer": *"\([^"]*\)".*/\1/p')
[ -n "$ip_bearer" ] || fail "no bearer for IP-scoped token"

echo "--- that mint reaped the bucket, the marker and the series of the expired token ---"
$SSH "test -e /tmp/uapi-ratelimit/api_shortlived_b.txt" && fail "the mint left the bucket of an expired token"
$SSH "test -e /var/run/uapi-token-update/api_shortlived_b" && fail "the mint left the marker of an expired token"
curl -sS -H "$ADMIN" "$URL/metrics" | grep -q 'token_id="api_shortlived_b"' \
	&& fail "the mint left the series of an expired token"
$SSH 'uapi-token revoke api_shortlived_b 2>/dev/null || true'
status=$(curl -sS -o /tmp/uapi_ip_body.json -w '%{http_code}' \
	-H "Authorization: Bearer $ip_bearer" "$URL/firewall/rules")
[ "$status" = "401" ] || fail "IP-scoped token from disallowed addr expected 401, got $status"
grep -q 'Source IP not permitted' /tmp/uapi_ip_body.json || fail "expected ip-not-permitted message"

echo "--- /auth/whoami surfaces expires_at/allowed_cidrs metadata ---"
# Use admin which has neither - those fields should be null/empty
who=$(curl -sS -H "$ADMIN" "$URL/auth/whoami")
echo "$who" | grep -q '"expires_at": null' || fail "whoami: admin expires_at must be null"
echo "$who" | grep -q '"allowed_cidrs": \[ \]' || fail "whoami: admin allowed_cidrs must be empty"

echo "--- validation errors on bad POST body ---"
bad=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/tokens" -d '{"name": "bad name with spaces", "scopes": ["*:rw"]}')
echo "$bad" | grep -q '"code": "validation_failed"' || fail "expected validation_failed"
echo "$bad" | grep -q '"field": "name"' || fail "expected name field error"

echo "--- POST /tokens with rate + burst persists per-token overrides ---"
rate_scoped=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/tokens" -d '{
		"name": "api_rate_limited", "scopes": ["firewall:rules:ro"],
		"rate": 7, "burst": 11
	}')
echo "$rate_scoped" | grep -q '"bearer"' || fail "rate/burst POST failed: $rate_scoped"
got_rate=$($SSH "uci get uapi.api_rate_limited.rate")
got_burst=$($SSH "uci get uapi.api_rate_limited.burst")
[ "$got_rate" = "7" ] || fail "rate not persisted: got '$got_rate'"
[ "$got_burst" = "11" ] || fail "burst not persisted: got '$got_burst'"

echo "--- GET /tokens/<name> surfaces rate/burst on the read path ---"
read_back=$(curl -sS -H "$ADMIN" "$URL/tokens/api_rate_limited")
echo "$read_back" | grep -q '"rate": 7' \
	|| fail "GET response missing rate=7: $read_back"
echo "$read_back" | grep -q '"burst": 11' \
	|| fail "GET response missing burst=11: $read_back"
$SSH 'uapi-token revoke api_rate_limited 2>/dev/null || true'

echo "--- POST /tokens rejects rate <= 0 with validation_failed ---"
bad_rate=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/tokens" -d '{"name": "bad_rate", "scopes": ["*:ro"], "rate": 0}')
echo "$bad_rate" | grep -q '"code": "validation_failed"' || fail "rate=0 should 422"
echo "$bad_rate" | grep -q '"field": "rate"' || fail "rate=0 missing field=rate"

echo "--- per-token rate/burst override is actually enforced (burst then 429) ---"
# burst=2 -> first 2 requests succeed; rate=1/s -> a 3rd or 4th request fired
# within the same second should 429 because the bucket has not yet refilled.
strict_bearer=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/tokens" -d '{
		"name": "api_strict_rl", "scopes": ["firewall:rules:ro"],
		"rate": 1, "burst": 2
	}' | sed -n 's/.*"bearer": *"\([^"]*\)".*/\1/p')
[ -n "$strict_bearer" ] || fail "no bearer for rate-limited token"
codes=""
for i in 1 2 3 4; do
	curl -sS -o /dev/null -D "/tmp/uapi_rl_$i.hdrs" \
		-H "Authorization: Bearer $strict_bearer" "$URL/firewall/rules" >/dev/null
	code=$(head -1 "/tmp/uapi_rl_$i.hdrs" | awk '{print $2}')
	codes="$codes $code"
done
echo "  codes:$codes"
echo "$codes" | grep -q ' 429' \
	|| fail "expected 429 within a 4-request burst against rate=1/burst=2 token; got:$codes"
# The first 429 in the sequence must carry Retry-After.
for i in 1 2 3 4; do
	if grep -q '^HTTP/[0-9.]* 429' "/tmp/uapi_rl_$i.hdrs"; then
		grep -qi '^Retry-After:' "/tmp/uapi_rl_$i.hdrs" \
			|| fail "429 response #$i missing Retry-After header"
		break
	fi
done

echo "--- uapi-token revoke reaps the bucket and adds the drops of the token to token_id=\"-retired\" ---"
drops() {
	echo "$1" | awk -v s="uapi_rate_limit_drops_total{token_id=\"$2\"}" \
		'$1 == s { print $2; found = 1 } END { if (!found) print 0 }'
}
before=$(curl -sS -H "$ADMIN" "$URL/metrics")
[ "$(drops "$before" api_strict_rl)" -gt 0 ] || fail "api_strict_rl has no drops to fold"
want=$(( $(drops "$before" api_strict_rl) + $(drops "$before" -retired) ))
$SSH "test -e /tmp/uapi-ratelimit/api_strict_rl.txt" || fail "api_strict_rl has no bucket to reap"
$SSH 'uapi-token revoke api_strict_rl' >/dev/null 2>&1 || fail "uapi-token revoke api_strict_rl failed"
$SSH "test -e /tmp/uapi-ratelimit/api_strict_rl.txt" && fail "uapi-token revoke left the bucket"
after=$(curl -sS -H "$ADMIN" "$URL/metrics")
echo "$after" | grep -q 'token_id="api_strict_rl"' && fail "uapi-token revoke left the series of the token"
[ "$(drops "$after" -retired)" = "$want" ] \
	|| fail "token_id=\"-retired\" holds $(drops "$after" -retired) drops, expected $want"

echo "--- uapi-token create --rate / --burst persists overrides via CLI ---"
$SSH "uapi-token create --name cli_rl --scope '*:ro' --rate 5 --burst 9" >/dev/null
[ "$($SSH 'uci get uapi.cli_rl.rate')" = "5" ] || fail "CLI --rate not persisted"
[ "$($SSH 'uci get uapi.cli_rl.burst')" = "9" ] || fail "CLI --burst not persisted"
$SSH "uapi-token revoke cli_rl 2>/dev/null || true"

echo "tokens route + expiry + IP scoping + per-token rate/burst ok."
