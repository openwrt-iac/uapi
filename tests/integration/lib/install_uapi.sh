SSH="tests/vm/ssh.sh"
UAPI_PREFIX_ENTRY="/api/v1=/usr/share/uapi/main.uc"

push_file_to_vm() {
	$SSH "cat > $2" < "$1"
}

install_uapi() {
	$SSH 'apk add uhttpd-mod-ucode ucode-mod-uci ucode-mod-digest 2>&1' | tail -3

	$SSH 'mkdir -p /usr/share/uapi/lib /usr/share/uapi/resources'
	push_file_to_vm src/main.uc /usr/share/uapi/main.uc
	push_file_to_vm src/raw.uc /usr/share/uapi/raw.uc
	push_file_to_vm build/openapi.json /usr/share/uapi/openapi.json
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

	$SSH "uci -q del_list uhttpd.main.ucode_prefix='$UAPI_PREFIX_ENTRY' || true
	      uci add_list uhttpd.main.ucode_prefix='$UAPI_PREFIX_ENTRY'
	      uci commit uhttpd
	      /etc/init.d/uhttpd restart"
	sleep 2

	ADMIN_TOKEN=$($SSH 'uapi-token create --name test_admin --scope "*:rw"' 2>/dev/null | head -1)
	RO_TOKEN=$($SSH 'uapi-token create --name test_readonly --scope "*:ro"' 2>/dev/null | head -1)
	FW_RO_TOKEN=$($SSH 'uapi-token create --name test_firewall_ro --scope "firewall:ro"' 2>/dev/null | head -1)
	export ADMIN_TOKEN RO_TOKEN FW_RO_TOKEN
}
