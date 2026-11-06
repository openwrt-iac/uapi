# Integration VM

Boots a real OpenWrt x86_64 QEMU VM for integration testing.

## Pinned versions

Two series run, selected by `OPENWRT_SERIES` (`stable` by default, `main` on the
v4 line, where CI sets it from the ref):

- **stable**: OpenWrt release **25.12.6**, image
  `openwrt-25.12.6-x86-64-generic-ext4-combined.img.gz` from
  `https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/`.
- **main**: the daily snapshot, image
  `openwrt-x86-64-generic-ext4-combined.img.gz` from
  `https://downloads.openwrt.org/snapshots/targets/x86/64/`. The filename is
  fixed while the content is not; `setup.sh` re-decompresses and re-injects
  whenever the downloaded archive is newer than what it prepared.

When bumping the stable target, update the `stable` branch of the series case
in `setup.sh`, `OPENWRT_VERSION` and `OPENWRT_IMAGE_CACHE_KEY` in
`.github/workflows/ci.yml`, the pins in `build/sdk.sha256`, and this file.

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

```sh
# The main snapshot instead of the stable release
OPENWRT_SERIES=main make test-integration
```
