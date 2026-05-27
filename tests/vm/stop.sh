#!/bin/sh
set -u
cd "$(dirname "$0")"

PIDFILE=qemu.pid

if [ -f "$PIDFILE" ]; then
	PID=$(cat "$PIDFILE")
	# Try graceful shutdown first so the VM flushes its filesystems.
	ssh -i id_ed25519 \
	    -o StrictHostKeyChecking=no \
	    -o UserKnownHostsFile=/dev/null \
	    -o ConnectTimeout=3 \
	    -o BatchMode=yes \
	    -p 2222 root@127.0.0.1 'poweroff' 2>/dev/null || true

	for i in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "$PID" 2>/dev/null || break
		sleep 1
	done

	if kill -0 "$PID" 2>/dev/null; then
		kill "$PID" 2>/dev/null || true
		sleep 1
		kill -9 "$PID" 2>/dev/null || true
	fi
	rm -f "$PIDFILE"
fi

echo "VM stopped"
