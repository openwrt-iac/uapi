SSH="tests/vm/ssh.sh"
UAPI_PREFIX_ENTRY="/api/v1=/usr/share/uapi/main.uc"

push_file_to_vm() {
	$SSH "cat > $2" < "$1"
}

install_uapi() {
	echo ">> install: apk add modules"
	$SSH 'apk add uhttpd-mod-ucode ucode-mod-uci ucode-mod-digest 2>&1' | tail -5

	echo ">> install: push files"
	$SSH 'mkdir -p /usr/share/uapi/lib /usr/share/uapi/resources'
	push_file_to_vm src/main.uc /usr/share/uapi/main.uc
	for f in src/lib/*.uc; do
		push_file_to_vm "$f" "/usr/share/uapi/lib/$(basename "$f")"
	done
	for f in src/resources/*.uc; do
		push_file_to_vm "$f" "/usr/share/uapi/resources/$(basename "$f")"
	done
	push_file_to_vm cli/uapi-token /usr/bin/uapi-token
	$SSH 'chmod +x /usr/bin/uapi-token'

	$SSH 'rm -f /etc/config/uapi'
	$SSH 'touch /etc/uapi.insecure'

	echo ">> install: wire uhttpd"
	$SSH "uci -q del_list uhttpd.main.ucode_prefix='$UAPI_PREFIX_ENTRY' || true
	      uci add_list uhttpd.main.ucode_prefix='$UAPI_PREFIX_ENTRY'
	      uci commit uhttpd
	      /etc/init.d/uhttpd restart"
	sleep 2

	echo ">> install: smoke-test uapi-token"
	$SSH 'uapi-token --help' 2>&1 | head -10 || true

	echo ">> install: create admin token"
	set +e
	admin_out=$($SSH 'uapi-token create --name test_admin --scope "*:rw"' 2>&1)
	admin_rc=$?
	set -e
	echo "  exit=$admin_rc output=[$admin_out]"
	ADMIN_TOKEN=$(echo "$admin_out" | head -1)

	echo ">> install: create ro token"
	RO_TOKEN=$($SSH 'uapi-token create --name test_readonly --scope "*:ro"' 2>&1 | head -1)

	echo ">> install: create fw_ro token"
	FW_RO_TOKEN=$($SSH 'uapi-token create --name test_firewall_ro --scope "firewall:ro"' 2>&1 | head -1)

	echo "  tokens: admin=${#ADMIN_TOKEN} ro=${#RO_TOKEN} fw_ro=${#FW_RO_TOKEN}"
	export ADMIN_TOKEN RO_TOKEN FW_RO_TOKEN
}
