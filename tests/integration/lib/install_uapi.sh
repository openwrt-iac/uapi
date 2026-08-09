SSH="tests/vm/ssh.sh"
UAPI_PREFIX_ENTRY="/api/v2=/usr/share/uapi/main.uc"

# Everything the box runs. Named once so the push and the fingerprint below
# cannot drift apart and start attesting to a different set of files than the
# one actually installed.
PUSH_PATHS="src/main.uc src/raw.uc build/openapi.json VERSION cli/uapi-token src/lib src/resources"

fail() { echo "FAIL: $*"; exit 1; }

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

# Content fingerprint of exactly what gets pushed. Paths are included so a
# rename counts as a change, and mtimes are not, so an untouched tree keeps its
# fingerprint across runs.
source_fingerprint() {
	# shellcheck disable=SC2086
	find $PUSH_PATHS -type f | sort | xargs md5sum | md5sum | cut -d' ' -f1
}

# Bootstrap: install deps, push every source file in a single tar stream, wire
# the uhttpd prefix, restart. Each request to /api/v2 forks a fresh ucode child
# that reads the on-disk source, so per-test isolation only needs a clean token
# store, not a re-copy of the source tree.
#
# The sentinel records WHICH tree is installed, not merely that something is.
# A bare "have we bootstrapped" flag lives in tmpfs and so outlives the session
# that wrote it: a leftover one silently made the whole suite exercise whatever
# was already on the box instead of the working tree, and a run that passed
# that way looked exactly like a real pass. Recording the fingerprint also
# makes an edit-then-rerun cycle correct rather than merely fast.
bootstrap_uapi() {
	local want installed
	want=$(source_fingerprint)
	installed=$($SSH 'cat /var/run/uapi-bootstrapped 2>/dev/null' 2>/dev/null || true)
	if [ "$want" = "$installed" ] && [ -z "${UAPI_FORCE_BOOTSTRAP:-}" ]; then
		return 0
	fi

	$SSH 'apk add uhttpd-mod-ucode ucode-mod-uci ucode-mod-digest 2>&1' | tail -3
	# shellcheck disable=SC2086
	if ! tar c -C . $PUSH_PATHS \
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
	then
		fail "pushing the uapi source to the test box failed; the box still runs whatever it had"
	fi

	# The fingerprint is written last and only on success, so a push that dies
	# halfway leaves no claim about what is installed and the next run retries.
	$SSH "touch /etc/uapi.insecure
	      uci -q del_list uhttpd.main.ucode_prefix='$UAPI_PREFIX_ENTRY' || true
	      uci add_list uhttpd.main.ucode_prefix='$UAPI_PREFIX_ENTRY'
	      uci commit uhttpd
	      /etc/init.d/uhttpd restart
	      printf %s '$want' > /var/run/uapi-bootstrapped"
	sleep 2
}

# install_uapi is kept for backward compat with every existing integration
# test. After bootstrap it's lightweight: clean the token store and mint
# the per-test tokens. The bootstrap step is a no-op on second-and-later
# calls thanks to the sentinel.
install_uapi() {
	bootstrap_uapi
	ensure_daemon_packages || echo "WARN: lldpd/vnstat2 not installable; their resources will answer 503"
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

# The same gap on the dhcp side. uapi writes /etc/config/dhcp, and dnsmasq
# compiles that into /var/etc/dnsmasq.conf.<id> on reload; a write that reaches
# uci but never reaches the compiled file is invisible to a status code and to
# a read-back. `dnsmasq --test` is the counterpart to `nft -c`: it parses the
# generated file and reports a bad option or a bad value without disturbing the
# running server.
# Every instance, not just the first. OpenWrt compiles one file per `config
# dnsmasq` section, and dhcp/hosts exposes an `instance` field, so a host bound
# to a non-default instance lands in a file that a `head -1` glob never reads:
# that reported "no line matching" for a host the daemon had compiled correctly,
# and it also skipped a syntax error in any instance but the first.
#
# Caveat: deleting an instance leaves its compiled file behind until dnsmasq is
# restarted, so on a box with that history the glob can read a stale file. The
# tests never create or delete instances, so this cannot arise in a suite run.
DNSMASQ_CONFS='/var/etc/dnsmasq.conf.*'

require_dnsmasq() {
	if [ -z "${DNSMASQ_PRESENT:-}" ]; then
		$SSH "command -v dnsmasq >/dev/null 2>&1 && ls $DNSMASQ_CONFS >/dev/null 2>&1" \
			|| fail "the test image has no dnsmasq or no compiled config; the dhcp assertions cannot run"
		DNSMASQ_PRESENT=1
	fi
}

dnsmasq_render() {
	$SSH "cat $DNSMASQ_CONFS 2>/dev/null"
}

# dnsmasq --test takes one file at a time, so check each instance and report the
# first complaint. Empty output means every instance parsed.
dnsmasq_complaints() {
	$SSH "for f in $DNSMASQ_CONFS; do dnsmasq --test -C \"\$f\" 2>&1; done" \
		| grep -v 'syntax check OK' || true
}

assert_dnsmasq_emits() {
	require_dnsmasq
	if ! dnsmasq_render | grep -qF -- "$1"; then
		local why
		why=$(dnsmasq_complaints | head -2 | tr '\n' ' ')
		fail "no dnsmasq instance compiled a line matching '$1' -- ${why:-no dnsmasq complaint either; the section may never have been written}"
	fi
}

assert_dnsmasq_omits() {
	require_dnsmasq
	if dnsmasq_render | grep -qF -- "$1"; then
		fail "a dnsmasq instance still compiles a line matching '$1'"
	fi
}

assert_dnsmasq_loads() {
	require_dnsmasq
	local rendered err
	rendered=$(dnsmasq_render)
	# An empty compiled file would sail through --test, which is the same trap
	# nft -c has on empty input.
	if [ -z "$rendered" ]; then
		fail "dnsmasq compiled no config at all"
	fi
	err=$(dnsmasq_complaints | head -3 | tr '\n' ' ')
	[ -z "$err" ] || fail "dnsmasq would reject its own compiled config: $err"
}

# kmod-wireguard alone is not enough. netifd scans /lib/netifd/proto only when it
# starts, so a proto handler installed underneath a running netifd stays invisible
# and proto=wireguard never gets a netdev. The restart has to be detached, since
# it drops the link this ssh session is riding on. Readiness is netifd actually
# advertising the handler, not a fixed sleep.
# lldpd and vnstat2 are outside the bare image, so their resources answered 503
# init_script_missing and were never exercised against a real daemon. That is how
# `vnstat/interfaces` shipped modelling a section type vnstat never reads.
#
# Installed here rather than inside a test, and guarded on its own rather than on the
# bootstrap fingerprint, which covers the source tree and not this package list: adding
# a package would otherwise be a no-op on any VM already carrying the current source.
ensure_daemon_packages() {
	$SSH 'apk info -e lldpd >/dev/null 2>&1 && apk info -e vnstat2 >/dev/null 2>&1' && return 0
	$SSH 'apk add lldpd vnstat2 2>&1 | tail -3' || return 1
	$SSH 'apk info -e lldpd >/dev/null 2>&1 && apk info -e vnstat2 >/dev/null 2>&1'
}

ensure_wireguard() {
	$SSH 'apk info -e kmod-wireguard >/dev/null 2>&1 && apk info -e wireguard-tools >/dev/null 2>&1' && {
		$SSH 'lsmod | grep -q "^wireguard " || modprobe wireguard 2>/dev/null
		      lsmod | grep -q "^wireguard " && command -v wg >/dev/null' && \
		$SSH 'ubus call network get_proto_handlers 2>/dev/null | grep -q wireguard' && return 0
	}

	$SSH 'apk add kmod-wireguard wireguard-tools 2>&1 | tail -5' || return 1
	$SSH '(sleep 1; /etc/init.d/network restart) >/dev/null 2>&1 &' || true

	n=0
	while [ $n -lt 40 ]; do
		if $SSH 'ubus call network get_proto_handlers 2>/dev/null | grep -q wireguard'; then
			$SSH 'lsmod | grep -q "^wireguard " || modprobe wireguard 2>/dev/null' || true
			$SSH 'lsmod | grep -q "^wireguard " && command -v wg >/dev/null' && return 0
		fi
		n=$((n + 1)); sleep 2
	done
	return 1
}
