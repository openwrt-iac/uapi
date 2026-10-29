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
$SSH 'uci -q revert network; cp -p /etc/config/network /tmp/uapi-staged-network'
$SSH 'uci -q revert dhcp; cp -p /etc/config/dhcp /tmp/uapi-staged-dhcp'
cleanup() {
	$SSH 'touch /tmp/uapi56-release
	      uci -q revert dhcp
	      if [ -f /tmp/uapi-staged-dhcp ]; then
	          cp -p /tmp/uapi-staged-dhcp /etc/config/dhcp && rm -f /tmp/uapi-staged-dhcp
	          /etc/init.d/dnsmasq reload
	      fi
	      uci -q revert firewall
	      if [ -f /tmp/uapi-staged-before ]; then
	          cp -p /tmp/uapi-staged-before /etc/config/firewall && rm -f /tmp/uapi-staged-before
	          /etc/init.d/firewall reload
	      fi
	      uci -q revert network
	      if [ -f /tmp/uapi-staged-network ]; then
	          cp -p /tmp/uapi-staged-network /etc/config/network && rm -f /tmp/uapi-staged-network
	          /etc/init.d/network reload
	      fi
	      rm -f /tmp/uapi56-hold.uc /tmp/uapi56-held /tmp/uapi56-release' || true
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

# libuci skips a commit with no changes. uapi rewrote the package anyway, which dropped its
# comments and could drop a commit that landed during the request.
echo "--- a write that changes nothing leaves the file as it is ---"
$SSH '{ echo "# kept by a write that changes nothing"; cat /etc/config/firewall; } > /tmp/uapi-staged-fw &&
      cat /tmp/uapi-staged-fw > /etc/config/firewall && rm -f /tmp/uapi-staged-fw'
status=$(curl -sS -o /tmp/uapi_staged_patch.json -w '%{http_code}' -H "$ADMIN" \
	-H 'Content-Type: application/json' -X PATCH "$URL/firewall/defaults" -d "{\"drop_invalid\": $flip}")
[ "$status" = 200 ] || { cat /tmp/uapi_staged_patch.json; fail "PATCH of an unchanged drop_invalid returned $status"; }
$SSH 'grep -q "^# kept by a write that changes nothing" /etc/config/firewall' \
	|| fail "a write that changed nothing rewrote /etc/config/firewall"

# A PATCH that names nothing wrote the private_key of a wireguard interface again, because the read
# masks it, and on a lookup rule it deleted an `action` that the rule does not hold. The bus counted
# each as a write, so the commit rewrote the package. Both sections stay disabled, so netifd sets up
# neither.
echo "--- a PATCH that names nothing leaves /etc/config/network as it is, for a wireguard interface and a lookup rule ---"
$SSH "uci set network.uapi56wg=interface; uci set network.uapi56wg.proto=wireguard; uci set network.uapi56wg.disabled=1
	uci set network.uapi56wg.private_key=yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
	uci add_list network.uapi56wg.addresses=10.98.56.1/30
	uci set network.uapi56rule=rule; uci set network.uapi56rule.src=10.98.56.0/30; uci set network.uapi56rule.lookup=100
	uci set network.uapi56rule.disabled=1
	uci commit network
	{ echo '# kept by a PATCH that names nothing'; cat /etc/config/network; } > /tmp/uapi-staged-net &&
	cat /tmp/uapi-staged-net > /etc/config/network && rm -f /tmp/uapi-staged-net"
# It reloaded network all the same, and its headers said so.
for path in interfaces/uapi56wg rules/uapi56rule; do
	status=$(curl -sS -D /tmp/uapi_staged_patch.h -o /tmp/uapi_staged_patch.json -w '%{http_code}' -H "$ADMIN" \
		-H 'Content-Type: application/json' -X PATCH "$URL/network/$path" -d '{}')
	[ "$status" = 200 ] || { cat /tmp/uapi_staged_patch.json; fail "an empty PATCH of network/$path returned $status"; }
	$SSH 'grep -q "^# kept by a PATCH that names nothing" /etc/config/network' \
		|| fail "an empty PATCH of network/$path rewrote /etc/config/network"
	hdrs=$(tr -d '\r' < /tmp/uapi_staged_patch.h)
	echo "$hdrs" | grep -qix 'X-Reload-Status: no_reload' && echo "$hdrs" | grep -qix 'X-Kernel-Status: no_kernel' \
		&& ! echo "$hdrs" | grep -qi '^X-Reload-Services:' && ! echo "$hdrs" | grep -qi '^X-Kernel-Applied:' \
		|| fail "an empty PATCH of network/$path reported a reload or a kernel apply: $hdrs"
done

# The commit replays the writes of the request over what another writer committed, and fails when
# one no longer applies. That answered 500, and reload_failed_restored in a batch. Here the batch has
# staged its write of the rule and waits for libuci's flock on /etc/config/dhcp, which a holder
# takes first, while the shell deletes the rule.
echo "--- a batch whose rule the shell deletes during the request answers 409 conflict, and the delete stays ---"
id_of() { grep -oE '"id": "[^"]+"' | head -1 | sed 's/^"id": "//; s/"$//'; }
rid=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' -X POST "$URL/firewall/rules" \
	-d '{"name": "uapi56r", "target": "ACCEPT", "match": {"src_zone": "lan", "proto": ["tcp"], "dest_port": ["5656"]}}' | id_of)
hid=$(curl -sS -H "$ADMIN" -H 'Content-Type: application/json' -X POST "$URL/dhcp/hosts" \
	-d '{"name": "uapi56h", "macs": ["02:00:00:00:56:56"], "ip": "192.168.1.56"}' | id_of)
[ -n "$rid" ] && [ -n "$hid" ] || fail "could not create the rule and the host of the batch"
$SSH 'cat > /tmp/uapi56-hold.uc' <<'UC'
let fs = require('fs');
let f = fs.open(ARGV[0], "r");
f.lock("x");
fs.writefile("/tmp/uapi56-held", "");
for (let i = 0; i < 300 && fs.stat("/tmp/uapi56-release") == null; i++) sleep(100);
UC
$SSH 'rm -f /tmp/uapi56-held /tmp/uapi56-release
      ucode /tmp/uapi56-hold.uc /etc/config/dhcp </dev/null >/dev/null 2>&1 &' &
n=0
until $SSH 'test -e /tmp/uapi56-held'; do
	n=$((n + 1)); [ $n -lt 50 ] || fail "the holder never took the flock of /etc/config/dhcp"; sleep 0.2
done
curl -sS -o /tmp/uapi_staged_batch.json -w '%{http_code}' -H "$ADMIN" -H 'Content-Type: application/json' \
	-X POST "$URL/batch" -d "{\"operations\": [
		{\"path\": \"/firewall/rules/$rid\", \"method\": \"PATCH\", \"body\": {\"name\": \"uapi56r2\"}},
		{\"path\": \"/dhcp/hosts/$hid\", \"method\": \"PATCH\", \"body\": {\"name\": \"uapi56h2\"}}]}" \
	> /tmp/uapi_staged_batch.status &
req=$!
# The request process of uhttpd opens the file before it waits on the flock. The snapshot opens it
# too, for a moment and before the firewall write, so the file has to stay open across two looks.
waiting() {
	$SSH 'for p in /proc/[0-9]*; do
	          [ "$(cat $p/comm 2>/dev/null)" = uhttpd ] && ls -l $p/fd 2>/dev/null | grep -q " /etc/config/dhcp$" && echo ${p#/proc/}
	      done; true'
}
n=0 seen=""
while :; do
	now=$(waiting)
	[ -n "$now" ] && [ "$now" = "$seen" ] && break
	seen=$now n=$((n + 1))
	[ $n -lt 100 ] || { $SSH 'touch /tmp/uapi56-release'; fail "the batch never waited on /etc/config/dhcp"; }
	sleep 0.3
done
$SSH "uci delete firewall.$rid; uci commit firewall"
$SSH 'touch /tmp/uapi56-release'
wait $req || true
[ "$(cat /tmp/uapi_staged_batch.status)" = 409 ] || { cat /tmp/uapi_staged_batch.json; fail "the batch answered $(cat /tmp/uapi_staged_batch.status), expected 409"; }
jq -e '.code == "conflict" and (.message | test("another writer changed the package firewall") and test("A retry reads the new state"))' \
	/tmp/uapi_staged_batch.json >/dev/null || { cat /tmp/uapi_staged_batch.json; fail "the 409 is not the conflict of the firewall package"; }
[ -z "$($SSH "uci -q get firewall.$rid")" ] || fail "the restore brought back the rule that the shell deleted"
[ "$($SSH "uci -q get dhcp.$hid.name")" = uapi56h ] || fail "the batch kept its write of the host"
curl -sS -o /dev/null -H "$ADMIN" -X DELETE "$URL/dhcp/hosts/$hid"

echo "a change that a shell staged stays out of uapi's reads and writes until the shell commits it."
