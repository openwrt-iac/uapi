SSH="tests/vm/ssh.sh"
UAPI_PREFIX_ENTRY="/api/v2=/usr/share/uapi/main.uc"

push_file_to_vm() {
	$SSH "cat > $2" < "$1"
}

ensure_wireless_radio() {
	if $SSH 'ls /sys/class/ieee80211/ 2>/dev/null | grep -q .'; then return 0; fi
	$SSH 'apk add kmod-mac80211-hwsim 2>&1 | tail -3' >/dev/null 2>&1 || return 1
	$SSH 'modprobe mac80211_hwsim radios=1' || return 1
	for i in 1 2 3 4 5; do
		$SSH 'ls /sys/class/ieee80211/ 2>/dev/null | grep -q .' && break
		sleep 1
	done
	$SSH 'ls /sys/class/ieee80211/ 2>/dev/null | grep -q .' || return 1
	$SSH 'wifi config 2>&1 | tail -3' >/dev/null 2>&1 || true
	return 0
}

# One-time bootstrap: install deps, push every source file in a single tar
# stream, wire the uhttpd prefix, restart. Guarded by a tmpfs sentinel so a
# second call is a no-op. Each request to /api/v2 forks a fresh ucode child
# that reads the on-disk source, so per-test isolation only needs a clean
# token store, not a re-copy of the source tree.
bootstrap_uapi() {
	$SSH 'test -f /var/run/uapi-bootstrapped' 2>/dev/null && return 0
	$SSH 'apk add uhttpd-mod-ucode ucode-mod-uci ucode-mod-digest 2>&1' | tail -3
	tar c -C . \
		src/main.uc src/raw.uc \
		build/openapi.json VERSION \
		cli/uapi-token \
		src/lib src/resources \
		| $SSH '
			rm -rf /tmp/uapi-bundle &&
			mkdir -p /tmp/uapi-bundle /usr/share/uapi/lib /usr/share/uapi/resources &&
			tar x -C /tmp/uapi-bundle &&
			cp /tmp/uapi-bundle/src/main.uc /usr/share/uapi/main.uc &&
			cp /tmp/uapi-bundle/src/raw.uc /usr/share/uapi/raw.uc &&
			cp /tmp/uapi-bundle/build/openapi.json /usr/share/uapi/openapi.json &&
			cp /tmp/uapi-bundle/VERSION /usr/share/uapi/VERSION &&
			cp /tmp/uapi-bundle/src/lib/*.uc /usr/share/uapi/lib/ &&
			cp /tmp/uapi-bundle/src/resources/*.uc /usr/share/uapi/resources/ &&
			cp /tmp/uapi-bundle/cli/uapi-token /usr/bin/uapi-token &&
			chmod +x /usr/bin/uapi-token &&
			rm -rf /tmp/uapi-bundle
		'
	$SSH "touch /etc/uapi.insecure
	      uci -q del_list uhttpd.main.ucode_prefix='$UAPI_PREFIX_ENTRY' || true
	      uci add_list uhttpd.main.ucode_prefix='$UAPI_PREFIX_ENTRY'
	      uci commit uhttpd
	      /etc/init.d/uhttpd restart
	      touch /var/run/uapi-bootstrapped"
	sleep 2
}

# install_uapi is kept for backward compat with every existing integration
# test. After bootstrap it's lightweight: clean the token store and mint
# the per-test tokens. The bootstrap step is a no-op on second-and-later
# calls thanks to the sentinel.
install_uapi() {
	bootstrap_uapi
	$SSH 'rm -f /etc/config/uapi'
	ADMIN_TOKEN=$($SSH 'uapi-token create --name test_admin --scope "*:rw"' 2>/dev/null | head -1)
	RO_TOKEN=$($SSH 'uapi-token create --name test_readonly --scope "*:ro"' 2>/dev/null | head -1)
	FW_RO_TOKEN=$($SSH 'uapi-token create --name test_firewall_ro --scope "firewall:ro"' 2>/dev/null | head -1)
	export ADMIN_TOKEN RO_TOKEN FW_RO_TOKEN
}

# firewall4 renders the uci config and nftables loads it as one atomic
# transaction, so an HTTP 200 says nothing about whether a rule exists on the
# box. fw4 silently drops a section it cannot parse, and nft rejects the whole
# table if any rendered rule is invalid. Both failures are invisible to a
# status-code assertion, and both have shipped.
#
# These assert on what fw4 RENDERS from uci rather than on the applied table.
# The CI image stubs /etc/init.d/firewall to a no-op because applying a real
# ruleset would tear down the port forwards the tests run over, so the live
# table is never populated here. Rendering needs no running firewall, shows
# both failures anyway (a dropped section emits no rule; an unloadable one
# fails `nft -c`), and is equally safe to run against a real router.

fail() { echo "FAIL: $*"; exit 1; }

fw4_render() {
	$SSH 'command -v fw4 >/dev/null 2>&1 || { echo "__NO_FW4__"; exit 0; }; fw4 print 2>/dev/null'
}

# Guards against the assertions quietly passing on an image without fw4, which
# would recreate exactly the false confidence this is meant to remove.
require_fw4() {
	$SSH 'command -v fw4 >/dev/null 2>&1' || fail "fw4 is not installed in the test image; the firewall assertions cannot run"
}

# fw4 tags every rule it emits with `!fw4: <name>`, so the section name is the
# handle. On failure, report fw4's own complaint about that section: it is
# almost always the explanation.
assert_fw4_emits() {
	require_fw4
	if ! fw4_render | grep -qF -- "$1"; then
		needle=$(printf '%s' "$1" | sed 's/^!fw4: //')
		why=$($SSH 'fw4 print 2>&1 >/dev/null' | grep -iF -- "$needle" | head -2)
		# The needle is usually a rendered fragment, not a section name, so the
		# targeted lookup misses. fw4's own warnings name the option that got the
		# section dropped, which is the answer nearly every time.
		if [ -z "$why" ]; then
			why=$($SSH 'fw4 print 2>&1 >/dev/null' | grep -v 'is disabled' | head -3 | tr '\n' ' ')
			why="${why:-no fw4 warning either; the section may never have been written}"
		fi
		fail "firewall4 renders no rule matching '$1' -- $why"
	fi
}

assert_fw4_omits() {
	require_fw4
	if fw4_render | grep -qF -- "$1"; then
		fail "firewall4 still renders a rule matching '$1'"
	fi
}

# Check-loads the rendered ruleset without applying it, which is the assertion
# that catches the atomic-failure class: nft -f is all-or-nothing, so a single
# unrenderable token rejects every rule and the router keeps its old ruleset
# while `firewall reload` still exits 0.
assert_fw4_loads() {
	require_fw4
	err=$($SSH 'fw4 print 2>/dev/null | nft -c -f - 2>&1' | head -3)
	[ -z "$err" ] || fail "nftables would reject the whole ruleset: $err"
}
