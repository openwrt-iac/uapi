# Integration VM

Boots a real OpenWrt x86_64 QEMU VM for integration testing.

## Image

The daily snapshot of OpenWrt main, image
`openwrt-x86-64-generic-ext4-combined.img.gz` from
`https://downloads.openwrt.org/snapshots/targets/x86/64/`. uapi 4.x supports
OpenWrt main and the release cut from it, and not 25.12, so no release image
runs here. The filename is fixed while the content is not; `setup.sh` downloads
it again when the server holds a newer one (`curl -z`), then re-decompresses and
re-injects.

## Scripts

- `setup.sh`: downloads the image when it is absent or the server holds a newer
  one, decompresses it, injects an SSH key for root login. Idempotent. Requires
  `sudo` for the loop mount step.
- `start.sh`: boots the image in the background via QEMU user-mode networking.
  Forwards host ports 2222->22, 8080->80, 8443->443. Writes PID to `qemu.pid`.
- `wait.sh`: blocks until SSH on port 2222 accepts a connection.
- `align_uhttpd.sh`: upgrades `uhttpd` and its installed `uhttpd-mod-*` from the
  feed, so that they come from one build. The image of a release ships them from
  the release build and the feed is rebuilt after it, and a plugin of another
  build than `uhttpd` stops or crashes it. `tests/integration/run.sh` and
  `release_apk_smoke.sh` run it first.
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

`make test-integration` runs `setup`, `start`, `wait`, the integration suite,
then `stop` even on failure.

