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

# Guards against the assertions quietly passing on an image missing either tool,
# which would recreate exactly the false confidence this is meant to remove.
# Memoized because the answer cannot change mid-run and every assertion would
# otherwise spend an SSH round trip re-asking.
require_fw4() {
	if [ -z "${FW4_PRESENT:-}" ]; then
		$SSH 'command -v fw4 >/dev/null 2>&1 && command -v nft >/dev/null 2>&1' \
			|| fail "the test image lacks fw4 or nft; the firewall assertions cannot run"
		FW4_PRESENT=1
	fi
}

fw4_render() {
	$SSH 'fw4 print 2>/dev/null'
}

# fw4 tags every rule it emits with `!fw4: <section>` on the same line as the
# match, so passing the section id first and a rendered fragment second pins the
# fragment to the section under test instead of to any rule that happens to
# contain it. On failure, report fw4's own complaint: a dropped section is nearly
# always the reason, and the warning names the option at fault.
assert_fw4_emits() {
	require_fw4
	local hits needle warnings why
	hits=$(fw4_render)
	for needle in "$@"; do
		hits=$(printf '%s\n' "$hits" | grep -F -- "$needle" || true)
	done
	if [ -z "$hits" ]; then
		warnings=$($SSH 'fw4 print 2>&1 >/dev/null' | grep -v 'is disabled' || true)
		why=$(printf '%s\n' "$warnings" \
			| grep -iF -- "$(printf '%s' "$1" | sed 's/^!fw4: //')" | head -2)
		[ -n "$why" ] || why=$(printf '%s\n' "$warnings" | head -3 | tr '\n' ' ')
		fail "firewall4 renders no single rule matching '$*' -- ${why:-no fw4 warning either; the section may never have been written}"
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
	local rendered err
	rendered=$(fw4_render)
	# nft -c exits 0 on empty input, so an fw4 that rendered nothing at all would
	# otherwise pass the very check this exists to make.
	if [ -z "$rendered" ]; then
		fail "fw4 rendered no ruleset at all: $($SSH 'fw4 print 2>&1 >/dev/null' | head -3 | tr '\n' ' ')"
	fi
	err=$(printf '%s\n' "$rendered" | $SSH 'nft -c -f - 2>&1' | head -3)
	[ -z "$err" ] || fail "nftables would reject the whole ruleset: $err"
}
