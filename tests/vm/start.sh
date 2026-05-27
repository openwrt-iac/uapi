#!/bin/sh
set -eu
cd "$(dirname "$0")"

IMAGE=openwrt.img
PIDFILE=qemu.pid
LOGFILE=qemu.log

if [ ! -f "$IMAGE" ]; then
	echo "Image not present. Run setup.sh first." >&2
	exit 1
fi

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
	echo "VM already running with pid $(cat "$PIDFILE")"
	exit 0
fi

KVM=""
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	KVM="-enable-kvm -cpu host"
fi

qemu-system-x86_64 \
	-display none -no-reboot \
	-m 128 $KVM \
	-drive file="$IMAGE",format=raw,if=virtio \
	-netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:8443-:443 \
	-device virtio-net,netdev=net0 \
	-serial file:"$LOGFILE" \
	-monitor none \
	-pidfile "$PIDFILE" \
	-daemonize

echo "VM booted, pid $(cat "$PIDFILE"), serial log at $LOGFILE"
