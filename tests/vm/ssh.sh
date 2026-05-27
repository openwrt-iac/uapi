#!/bin/sh
exec ssh -i "$(dirname "$0")/id_ed25519" \
	-o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null \
	-o LogLevel=ERROR \
	-p 2222 root@127.0.0.1 "$@"
