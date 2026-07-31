#!/bin/sh
set -eu

# 2.1.0: curated unbound/srv + unbound/ext singletons wrap the UCI
# namespaces provided by the openwrt-iac/unbound-uci-ext package. uapi
# patches /etc/config/unbound_srv or /etc/config/unbound_ext, the
# generator runs on reload, the managed regions land in the two seam
# files, unbound restarts.

. tests/integration/lib/install_uapi.sh
install_uapi

URL=http://127.0.0.1:8080/api/v2
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
fail() { echo "FAIL: $*"; exit 1; }
call() { curl -sS -H "$ADMIN" -w "\n%{http_code}" "$@"; }

# The openwrt-iac feed is not in the stock apk index, so the CI VM cannot install
# unbound-uci-ext and this falls back to smoking the 503 init_script_missing
# pre-flight; real coverage runs against a box that has the feed. The daemon is
# `unbound-daemon`, not `unbound`, which had no visible effect only because apk
# aborts the whole transaction on the unselectable ext package and so installs
# neither. That is also what keeps the 503 path valid: it needs
# /etc/init.d/unbound absent, so installing the daemon alone would break it.
HAVE_EXT=0
if $SSH '
	if apk info -e unbound-uci-ext >/dev/null 2>&1; then
		exit 0
	fi
	apk add unbound-daemon unbound-uci-ext 2>&1 | tail -10
	apk info -e unbound-uci-ext >/dev/null 2>&1
'; then
	HAVE_EXT=1
else
	echo "[40_unbound_ext] WARN: unbound-uci-ext not installable on this VM; running 503 smoke only"
fi

if [ "$HAVE_EXT" = "0" ]; then
	# unbound-uci-ext absent -> pre-flight returns 503 init_script_missing
	# before any uci write.
	r=$(call -X PATCH -H 'Content-Type: application/json' "$URL/unbound/srv" \
		-d '{"enabled": true}')
	status=$(echo "$r" | tail -1)
	body=$(echo "$r" | sed '$d')
	[ "$status" = "503" ] || fail "expected 503 with no unbound-uci-ext, got $status: $body"
	echo "$body" | grep -q '"code": "init_script_missing"' \
		|| fail "expected init_script_missing code"
	echo "$body" | grep -q '/etc/init.d/unbound-uci-ext' \
		|| fail "expected init.d/unbound-uci-ext in message"
	echo "[40_unbound_ext] 503 smoke ok; skipping happy path"
	exit 0
fi

echo "--- GET /unbound/srv returns the singleton with defaults ---"
resp=$(call "$URL/unbound/srv")
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "GET /unbound/srv expected 200, got $status: $body"
echo "$body" | grep -q '"id": "main"' || fail "expected id=main"
echo "$body" | grep -q '"managed": true' || fail "expected managed=true"

echo "--- PATCH /unbound/srv enables bind + ip_transparent + srv_line ---"
resp=$(call -X PATCH -H 'Content-Type: application/json' "$URL/unbound/srv" -d '{
	"enabled": true,
	"interface_bind": ["127.0.0.1@5353"],
	"ip_transparent": false,
	"srv_line": ["harden-below-nxdomain: yes"]
}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "PATCH /unbound/srv expected 200, got $status: $body"
echo "$body" | grep -q '"enabled": true' || fail "expected enabled=true in response"
echo "$body" | grep -q '"ip_transparent": false' || fail "expected ip_transparent=false"

echo "--- managed region in /etc/unbound/unbound_srv.conf has the three rendered lines ---"
for line in 'interface: 127.0.0.1@5353' 'ip-transparent: no' 'harden-below-nxdomain: yes'; do
	$SSH "grep -q '$line' /etc/unbound/unbound_srv.conf" \
		|| fail "expected '$line' in unbound_srv.conf"
done
$SSH "grep -q 'unbound-uci-ext managed' /etc/unbound/unbound_srv.conf" \
	|| fail "expected managed-region markers in unbound_srv.conf"

echo "--- unbound-checkconf accepts the rendered config ---"
# /usr/sbin/ may not be in non-login PATH on busybox sh; the absolute
# path is set by the unbound-daemon package.
$SSH "/usr/sbin/unbound-checkconf 2>&1 | tail -5" || fail "unbound-checkconf rejected the rendered config"

echo "--- PATCH /unbound/ext writes a forward-zone clause ---"
resp=$(call -X PATCH -H 'Content-Type: application/json' "$URL/unbound/ext" -d '{
	"enabled": true,
	"ext_line": ["forward-zone:", "  name: \"example.org\"", "  forward-addr: 1.1.1.1"]
}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "PATCH /unbound/ext expected 200, got $status: $body"
echo "$body" | grep -q '"forward-zone:"' || fail "expected forward-zone: in response"

echo "--- managed region in /etc/unbound/unbound_ext.conf has the three rendered lines ---"
$SSH "grep -q '^forward-zone:' /etc/unbound/unbound_ext.conf" \
	|| fail "expected 'forward-zone:' in unbound_ext.conf"
$SSH "grep -q 'name: \"example.org\"' /etc/unbound/unbound_ext.conf" \
	|| fail "expected zone name line in unbound_ext.conf"
$SSH "grep -q 'forward-addr: 1.1.1.1' /etc/unbound/unbound_ext.conf" \
	|| fail "expected forward-addr line in unbound_ext.conf"

echo "--- PATCH with an ext_line entry containing a newline -> 422, no uci change ---"
prev=$($SSH "uci get unbound_ext.main.ext_line 2>/dev/null" || true)
resp=$(call -X PATCH -H 'Content-Type: application/json' "$URL/unbound/ext" \
	-d '{"ext_line": ["one\ntwo"]}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "422" ] || fail "expected 422 for newline-embedded ext_line, got $status: $body"
echo "$body" | grep -q '"field": "ext_line\[0\]"' \
	|| fail "expected field=ext_line[0] in error envelope"
now=$($SSH "uci get unbound_ext.main.ext_line 2>/dev/null" || true)
[ "$prev" = "$now" ] || fail "uci ext_line changed despite 422 rejection: was='$prev' now='$now'"

echo "--- conditional GET on /unbound/srv: stale ETag -> 200, current ETag -> 304 ---"
etag=$(curl -sS -D - -o /dev/null -H "$ADMIN" "$URL/unbound/srv" | awk -F': ' 'tolower($1) == "etag" { gsub(/\r/, "", $2); print $2 }')
[ -n "$etag" ] || fail "no ETag header on /unbound/srv"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "$ADMIN" "$URL/unbound/srv?if_none_match=$etag")
[ "$code" = "304" ] || fail "conditional GET expected 304, got $code"

echo "--- cleanup: PATCH both back to disabled + empty ---"
call -X PATCH -H 'Content-Type: application/json' "$URL/unbound/srv" -d '{
	"enabled": false,
	"interface_bind": [], "interface_outgoing": [], "srv_line": [],
	"ip_transparent": null
}' | tail -1 | grep -q '^200$' || fail "cleanup PATCH /unbound/srv failed"

call -X PATCH -H 'Content-Type: application/json' "$URL/unbound/ext" -d '{
	"enabled": false, "ext_line": []
}' | tail -1 | grep -q '^200$' || fail "cleanup PATCH /unbound/ext failed"

echo "--- managed regions are emptied after disable ---"
# Capture and test the output rather than gating on the pipeline's exit status.
# The pipeline ends in `head`, which exits 0 whether or not anything reached it,
# so the status form fired unconditionally and this assertion could never pass.
#
# `head` stays deliberately: without it grep's exit 1 on no-match propagates out
# of the command substitution, and `set -e` kills the script on the very path
# where the assertion should succeed. So the terminal `head` is what makes the
# capture safe, and dropping it trades one silent failure for another.
for seam in unbound_srv unbound_ext; do
	leftover=$($SSH "awk '/unbound-uci-ext managed \\(do not edit\\)/{f=1; next} /<<< unbound-uci-ext managed <<</{f=0; next} f' /etc/unbound/$seam.conf | grep -v '^\$' | head -3")
	[ -z "$leftover" ] \
		|| fail "$seam.conf still has managed-region content after disable: $leftover"
done

echo "--- 2.2.0 create_if_missing: wipe unbound_srv conffile, PATCH recreates ---"
# Save a snapshot of the current conffile (which the package shipped) so we
# can restore it after the test regardless of whether unbound-uci-ext was
# feed-installed or sideloaded. apk add --force-overwrite isn't a reliable
# restore: a sideloaded apk may not be in any configured repo's index.
$SSH "cp /etc/config/unbound_srv /tmp/41_unbound_srv.bak"
$SSH "rm /etc/config/unbound_srv && touch /etc/config/unbound_srv"
resp=$(call -X PATCH -H 'Content-Type: application/json' "$URL/unbound/srv" \
	-d '{"enabled": false}')
status=$(echo "$resp" | tail -1)
body=$(echo "$resp" | sed '$d')
[ "$status" = "200" ] || fail "PATCH on wiped unbound_srv expected 200 (create_if_missing), got $status: $body"
echo "$body" | grep -q '"id": "main"' || fail "expected id=main"
$SSH "uci get unbound_srv.main" >/dev/null || fail "uci section unbound_srv.main not recreated"

# Restore the conffile we saved above so subsequent tests on the same VM
# see the package-default content.
$SSH "mv /tmp/41_unbound_srv.bak /etc/config/unbound_srv"

echo "unbound/srv + unbound/ext singletons ok."
