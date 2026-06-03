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
