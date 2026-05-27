SSH="tests/vm/ssh.sh"
UAPI_PREFIX_ENTRY="/api/v1=/usr/share/uapi/main.uc"

push_file_to_vm() {
	$SSH "cat > $2" < "$1"
}

install_uapi() {
	$SSH 'apk add -q uhttpd-mod-ucode 2>&1' | tail -3

	$SSH 'mkdir -p /usr/share/uapi/lib'

	for f in src/main.uc; do
		push_file_to_vm "$f" "/usr/share/uapi/main.uc"
	done
	for f in src/lib/*.uc; do
		push_file_to_vm "$f" "/usr/share/uapi/lib/$(basename "$f")"
	done

	$SSH 'touch /etc/uapi.insecure'

	$SSH "uci -q del_list uhttpd.main.ucode_prefix='$UAPI_PREFIX_ENTRY' || true
	      uci add_list uhttpd.main.ucode_prefix='$UAPI_PREFIX_ENTRY'
	      uci commit uhttpd
	      /etc/init.d/uhttpd restart"
	sleep 2
}
