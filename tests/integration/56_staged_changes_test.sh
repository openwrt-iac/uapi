#!/bin/sh
set -eu

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v3
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }

# `uci set` stages a change in /tmp/.uci, and libuci overlays that directory onto every cursor
# that loads the package by name. uapi's cursor did, so a GET showed a value that neither the
# file nor fw4 held, the next uapi write of the package committed it, and a write that uapi
# refused deleted it. LuCI keeps its staged changes in a directory per session.

$SSH 'uci -q revert firewall; cp -p /etc/config/firewall /tmp/uapi-staged-before'
cleanup() {
	$SSH 'uci -q revert firewall
	      if [ -f /tmp/uapi-staged-before ]; then
	          cp -p /tmp/uapi-staged-before /etc/config/firewall && rm -f /tmp/uapi-staged-before
	      fi' || true
}
trap cleanup EXIT INT TERM

# Read under another package name, so that no change staged for `firewall` applies to it.
committed() {
	$SSH "mkdir -p /tmp/uapi-staged-cfg && cp /etc/config/firewall /tmp/uapi-staged-cfg/fwfile &&
	      uci -c /tmp/uapi-staged-cfg -q get fwfile.@defaults[0].$1; rm -rf /tmp/uapi-staged-cfg"
}
staged() { $SSH 'uci changes firewall' | grep -c "\.input='$STAGED'" || true; }
etag() {
	curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/firewall/defaults" | tr -d '\r' \
		| sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' | head -1
}

before=$(committed input)
[ -n "$before" ] || fail "firewall.@defaults[0] has no input to stage a change over"
STAGED=DROP
[ "$before" = DROP ] && STAGED=ACCEPT
etag_before=$(etag)

echo "--- stage input=$STAGED with uci set, and do not commit it ---"
$SSH "uci set firewall.@defaults[0].input=$STAGED"
[ "$(staged)" = 1 ] || fail "uci changes does not list the staged input"

echo "--- a GET reports what the file holds ---"
got=$(curl -sS -H "$ADMIN" "$URL/firewall/defaults" | jq -r .input)
[ "$got" = "$before" ] || fail "GET reported input=$got, the file holds $before and $STAGED is only staged"
[ "$(etag)" = "$etag_before" ] || fail "the ETag changed with a change that is only staged"
got=$(curl -sS -g -H "$ADMIN" "$URL/raw/firewall/@defaults[0]" | jq -r .input)
[ "$got" = "$before" ] || fail "a raw GET reported input=$got, the file holds $before"

echo "--- a uapi write commits its own change and leaves the staged one staged ---"
flip=true
[ "$(curl -sS -H "$ADMIN" "$URL/firewall/defaults" | jq -r .drop_invalid)" = true ] && flip=false
status=$(curl -sS -o /tmp/uapi_staged_patch.json -w '%{http_code}' -H "$ADMIN" \
	-H 'Content-Type: application/json' -X PATCH "$URL/firewall/defaults" -d "{\"drop_invalid\": $flip}")
[ "$status" = 200 ] || { cat /tmp/uapi_staged_patch.json; fail "PATCH /firewall/defaults returned $status"; }
[ "$(committed input)" = "$before" ] || fail "the uapi write committed the staged input"
want=0
[ "$flip" = true ] && want=1
[ "$(committed drop_invalid)" = "$want" ] || fail "the uapi write did not commit drop_invalid=$want"
[ "$(staged)" = 1 ] || fail "the uapi write removed the staged input"

echo "--- a refused write leaves the staged change staged ---"
status=$(curl -sS -o /tmp/uapi_staged_patch.json -w '%{http_code}' -H "$ADMIN" \
	-H 'Content-Type: application/json' -X PATCH "$URL/firewall/defaults" -d '{"input": "BOGUS"}')
[ "$status" = 422 ] || { cat /tmp/uapi_staged_patch.json; fail "PATCH input=BOGUS returned $status, expected 422"; }
[ "$(staged)" = 1 ] || fail "the refused write deleted the staged input"

echo "--- a commit by the shell between two requests is seen ---"
$SSH 'uci commit firewall'
body=$(curl -sS -H "$ADMIN" "$URL/firewall/defaults")
[ "$(echo "$body" | jq -r .input)" = "$STAGED" ] || fail "GET did not see the input that the shell committed"
[ "$(echo "$body" | jq -r .drop_invalid)" = "$flip" ] || fail "the shell commit lost the drop_invalid that uapi committed"

echo "a change that a shell staged stays out of uapi's reads and writes until the shell commits it."
