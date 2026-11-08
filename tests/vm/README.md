# Integration VM

Boots a real OpenWrt x86_64 QEMU VM for integration testing.

## Pinned versions

Two series run, selected by `OPENWRT_SERIES` (`stable` by default, `main` on the
v4 line, where CI sets it from the ref):

- **stable**: OpenWrt release **25.12.6**, image
  `openwrt-25.12.6-x86-64-generic-ext4-combined.img.gz` from
  `https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/`. `setup.sh`
  takes the version from `OPENWRT_VERSION`, or else from the x86-64 pin in
  `build/sdk.sha256`.
- **main**: the daily snapshot, image
  `openwrt-x86-64-generic-ext4-combined.img.gz` from
  `https://downloads.openwrt.org/snapshots/targets/x86/64/`. The filename is
  fixed while the content is not; `setup.sh` downloads it again when the server
  holds a newer one (`curl -z`), then re-decompresses and re-injects.

Each series keeps its own image (`openwrt-stable.img`, `openwrt-main.img`) and
its own injection marker, and `start.sh` boots the one that `OPENWRT_SERIES`
selects.

When bumping the stable target, update `OPENWRT_VERSION` and
`OPENWRT_IMAGE_CACHE_KEY` in `.github/workflows/ci.yml`, the default version in
`tools/openwrt-sdk.sh`, the pins in `build/sdk.sha256`, and this file.

## Scripts

- `setup.sh`: downloads the image (if absent, or for the snapshot if newer), decompresses it, injects an SSH key for root login. Idempotent. Requires `sudo` for the loop mount step.
- `start.sh`: boots the image of the selected series in the background via QEMU user-mode networking. Forwards host ports 2222->22, 8080->80, 8443->443. Writes PID to `qemu.pid`.
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
