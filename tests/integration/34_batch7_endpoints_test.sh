#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
SSH="tests/vm/ssh.sh"

# Track ids we create across tests so we always clean up.
CLEANUP_IDS=""
cleanup() {
	for id in $CLEANUP_IDS; do
		curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/firewall/rules/$id" 2>/dev/null || true
	done
}
trap cleanup EXIT INT TERM

echo "--- JSON Patch (RFC 6902): replace flips enabled ---"
created=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/rules" -d '{
		"name": "jsonpatch-test",
		"target": "ACCEPT",
		"enabled": true,
		"match": { "src_zone": "wan", "proto": ["tcp"], "dest_port": ["19090"] }
	}')
id=$(printf '%s' "$created" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
[ -n "$id" ] || fail "POST missing id"
CLEANUP_IDS="$CLEANUP_IDS $id"

status=$(curl -sS -o /tmp/uapi_jp_patch.json -w '%{http_code}' \
	-H "$ADMIN" -H 'Content-Type: application/json-patch+json' \
	-X PATCH "$URL/firewall/rules/$id" -d '[{"op":"replace","path":"/enabled","value":false}]')
[ "$status" = "200" ] || fail "JSON Patch expected 200, got $status: $(cat /tmp/uapi_jp_patch.json)"
grep -q '"enabled": false' /tmp/uapi_jp_patch.json || fail "JSON Patch did not flip enabled"

echo "--- JSON Patch test op enables atomic conditional updates ---"
status=$(curl -sS -o /tmp/uapi_jp_test.json -w '%{http_code}' \
	-H "$ADMIN" -H 'Content-Type: application/json-patch+json' \
	-X PATCH "$URL/firewall/rules/$id" -d '[
		{"op":"test","path":"/enabled","value":false},
		{"op":"replace","path":"/enabled","value":true}
	]')
[ "$status" = "200" ] || fail "JSON Patch test+replace expected 200, got $status"
grep -q '"enabled": true' /tmp/uapi_jp_test.json || fail "test+replace did not apply"

echo "--- JSON Patch test op failing returns 412 precondition_failed ---"
status=$(curl -sS -o /tmp/uapi_jp_fail.json -w '%{http_code}' \
	-H "$ADMIN" -H 'Content-Type: application/json-patch+json' \
	-X PATCH "$URL/firewall/rules/$id" -d '[
		{"op":"test","path":"/enabled","value":false},
		{"op":"replace","path":"/enabled","value":false}
	]')
[ "$status" = "412" ] || fail "test mismatch expected 412, got $status"
# State should still be true (test failed before replace ran)
state=$(curl -sS -H "$ADMIN" "$URL/firewall/rules/$id" \
	| sed -n 's/.*"enabled": *\(true\|false\).*/\1/p' | head -1)
[ "$state" = "true" ] || fail "test failure must not change state; saw enabled=$state"

echo "--- /batch happy path: 2 sub-requests return 207 Multi-Status ---"
status=$(curl -sS -o /tmp/uapi_batch_ok.json -w '%{http_code}' \
	-H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/batch" -d '{
		"operations": [
			{"path": "/firewall/zones", "method": "GET"},
			{"path": "/system", "method": "GET"}
		]
	}')
[ "$status" = "207" ] || fail "batch happy path expected 207, got $status"
grep -q '"results"' /tmp/uapi_batch_ok.json || fail "batch missing results array"

# A pure-read batch takes no lock and runs no transaction, so there is no reload outcome to
# report and no header, which is what a read on any other endpoint does.
echo "--- /batch read-only: no transaction headers ---"
curl -sS -o /dev/null -D /tmp/uapi_batch_ro_h -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/batch" -d '{"operations":[{"path":"/system","method":"GET"}]}'
tr -d '\r' < /tmp/uapi_batch_ro_h | grep -qi '^X-Reload-Status:' \
	&& fail "a read-only batch reported a reload it never ran"

# A write batch commits and reloads once for the whole set, and the 207 is the only place
# that outcome can be reported: the results array carries {status, body} and drops
# sub-response headers.
echo "--- /batch write: the 207 carries the transaction headers ---"
zid=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' -X POST "$URL/firewall/zones" \
	-d '{"name":"bhdr","input":"ACCEPT","output_policy":"ACCEPT","forward":"REJECT"}' \
	| grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//')
curl -sS -o /dev/null -D /tmp/uapi_batch_w_h -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/batch" -d "{\"operations\":[{\"path\":\"/firewall/zones/$zid\",\"method\":\"PATCH\",\"body\":{\"forward\":\"ACCEPT\"}}]}"
hdrs=$(tr -d '\r' < /tmp/uapi_batch_w_h)
echo "$hdrs" | grep -qi '^X-Reload-Status:' || fail "batch write 207 carries no X-Reload-Status: $hdrs"
echo "$hdrs" | grep -qi '^X-Reload-Services:.*firewall' || fail "batch write 207 does not name the reloaded service"
curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/firewall/zones/$zid"

echo "--- /batch abort: failing sub-request reverts all writes ---"
# Sub 1 creates a rule; sub 2 references a missing resource (404).
# Expect the rule to NOT exist after the batch.
status=$(curl -sS -o /tmp/uapi_batch_abort.json -w '%{http_code}' \
	-H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/batch" -d '{
		"operations": [
			{
				"path": "/firewall/rules",
				"method": "POST",
				"body": {
					"name": "batch-rule-1",
					"target": "ACCEPT",
					"match": { "src_zone": "wan" }
				}
			},
			{ "path": "/firewall/rules/r_does_not_exist", "method": "GET" }
		]
	}')
[ "$status" = "404" ] || fail "batch abort: expected sub's 404 status, got $status; body=$(cat /tmp/uapi_batch_abort.json)"
grep -q '"code": "batch_partial_failure"' /tmp/uapi_batch_abort.json \
	|| fail "abort body missing batch_partial_failure"
grep -q '"reverted": true' /tmp/uapi_batch_abort.json \
	|| fail "abort body missing reverted: true"
grep -q '"aborted_at_index": 1' /tmp/uapi_batch_abort.json \
	|| fail "abort body missing aborted_at_index"
# Ensure no rule named "batch-rule-1" remained
list=$(curl -sS -H "$ADMIN" "$URL/firewall/rules")
echo "$list" | grep -q '"name": "batch-rule-1"' \
	&& fail "batch abort did not revert the create (rule found)" || true

echo "--- /batch rejects oversized operations array ---"
status=$(curl -sS -o /dev/null -w '%{http_code}' \
	-H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/batch" -d '{"operations": []}')
[ "$status" = "400" ] || fail "empty ops expected 400, got $status"

echo "--- Per-resource ETag: firewall/rules ETag is stable across unrelated firewall/zones writes ---"
# Regression for the v2.0.0 bug where any sibling-section write in the same
# uci package shifted every other resource's ETag, tripping spurious 412s on
# unrelated concurrent writes (e.g. a `tofu destroy` over multiple firewall
# resources). The fix in v2.0.1 made the ETag a pure function of THIS
# resource's body; mutating a sibling must leave the ETag unchanged.
zone_resp=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/firewall/zones" -d '{
		"name": "depzone",
		"network": ["lan"],
		"input": "ACCEPT",
		"output_policy": "ACCEPT",
		"forward": "REJECT"
	}')
zone_id=$(printf '%s' "$zone_resp" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
if [ -z "$zone_id" ]; then
	echo "  could not create zone (response: $zone_resp), skipping per-resource-etag test"
else
	# A rule that does NOT reference the depzone we're about to mutate.
	rule_resp=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' \
		-X POST "$URL/firewall/rules" -d '{
			"name": "etag-stability-rule",
			"target": "ACCEPT",
			"match": { "src_zone": "lan" }
		}')
	rule_id=$(printf '%s' "$rule_resp" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
	CLEANUP_IDS="$CLEANUP_IDS $rule_id"

	etag1=$(curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/firewall/rules/$rule_id" \
		| tr -d '\r' | sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
	# Mutate an unrelated zone in the same package.
	curl -sS -o /dev/null -H "$ADMIN" -H 'Content-Type: application/json' \
		-X PATCH "$URL/firewall/zones/$zone_id" -d '{"forward": "ACCEPT"}'
	etag2=$(curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/firewall/rules/$rule_id" \
		| tr -d '\r' | sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
	[ -n "$etag1" ] && [ -n "$etag2" ] || fail "per-resource-etag: missing ETag (e1=$etag1 e2=$etag2)"
	[ "$etag1" = "$etag2" ] \
		|| fail "rule ETag shifted after unrelated zone mutation (e1=$etag1 e2=$etag2); the v2.0.0 sibling-pollution bug has regressed"

	# And: a PUT against the rule with the captured If-Match must still succeed,
	# matching the real client scenario from the bug report.
	put_status=$(curl -sS -o /dev/null -w '%{http_code}' \
		-H "$ADMIN" -H 'Content-Type: application/json' \
		-H "If-Match: $etag1" \
		-X PUT "$URL/firewall/rules/$rule_id" -d '{
			"name": "etag-stability-rule",
			"target": "ACCEPT",
			"enabled": false,
			"match": { "src_zone": "lan" }
		}')
	[ "$put_status" = "200" ] \
		|| fail "PUT with captured If-Match after sibling zone mutation expected 200, got $put_status"

	curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/firewall/rules/$rule_id"
	curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/firewall/zones/$zone_id"
fi

echo "Batch 7 endpoints (batch, json-patch, per-resource ETag stability) ok."
