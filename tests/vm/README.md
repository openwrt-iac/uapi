# Integration VM

Boots a real OpenWrt 25.12.4 x86_64 QEMU VM for integration testing.

## Pinned versions

- OpenWrt release: **25.12.4**
- Image: `openwrt-25.12.4-x86-64-generic-ext4-combined.img.gz`
- Source: `https://downloads.openwrt.org/releases/25.12.4/targets/x86/64/`

When bumping the OpenWrt target, update `IMAGE_URL` and `IMAGE_NAME` in `setup.sh` and update this file.

## Scripts

- `setup.sh`: downloads the image (if absent), decompresses it, injects an SSH key for root login. Idempotent. Requires `sudo` for the loop mount step.
- `start.sh`: boots the VM in the background via QEMU user-mode networking. Forwards host ports 2222->22, 8080->80, 8443->443. Writes PID to `qemu.pid`.
- `wait.sh`: blocks until SSH on port 2222 accepts a connection.
- `stop.sh`: graceful shutdown via SSH `poweroff`, then `kill` as fallback.
- `ssh.sh`: shorthand `ssh -i id_ed25519 -p 2222 root@localhost`.

## Local usage

```sh
tests/vm/setup.sh
tests/vm/start.sh
tests/vm/wait.sh
tests/vm/ssh.sh 'ubus call system info'
tests/vm/stop.sh
```

`make test-integration` runs `setup`, `start`, `wait`, the integration suite, then `stop` even on failure.
