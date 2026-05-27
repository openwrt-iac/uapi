#!/bin/sh
set -eu
cd "$(dirname "$0")"

TIMEOUT=${TIMEOUT:-120}
deadline=$(( $(date +%s) + TIMEOUT ))

echo "Waiting up to ${TIMEOUT}s for SSH on 127.0.0.1:2222"
while [ "$(date +%s)" -lt "$deadline" ]; do
	if ssh -i id_ed25519 \
	       -o StrictHostKeyChecking=no \
	       -o UserKnownHostsFile=/dev/null \
	       -o ConnectTimeout=2 \
	       -o BatchMode=yes \
	       -p 2222 root@127.0.0.1 true 2>/dev/null; then
		echo "VM is up"
		exit 0
	fi
	sleep 2
done

echo "Timed out waiting for SSH" >&2
echo "---qemu.log tail---" >&2
tail -50 qemu.log >&2 || true
exit 1
