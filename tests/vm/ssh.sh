#!/bin/sh
# One master connection, reused by every later call. The suite makes several hundred ssh
# invocations across its 48 scripts and each was paying a full handshake: measured at 253ms
# without multiplexing against 12ms with it, and the handshake is CPU-bound key exchange, so
# an emulated VM pays at least as much.
#
# The socket lives in /tmp rather than beside this script because a Unix socket path is capped
# at 108 bytes and a checkout under a long path silently blows that limit. `%C` hashes host,
# port and user, so two VMs cannot share a socket.
#
# Verified rather than assumed, because a wedged master would trade speed for flakiness: after
# killing the master with SIGKILL and leaving its socket behind, the next call reconnects; a
# plain file in the socket's place is likewise stepped over; and an unreachable host still
# fails in ConnectTimeout rather than hanging on the socket.
exec ssh -i "$(dirname "$0")/id_ed25519" \
	-o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null \
	-o LogLevel=ERROR \
	-o ControlMaster=auto \
	-o ControlPath=/tmp/uapi-vm-%C \
	-o ControlPersist=120 \
	-p 2222 root@127.0.0.1 "$@"
