# Building the uapi APK

The version comes from a single source: the `VERSION` file at the repo root (semver, e.g. `1.0.0-rc1`). The OpenWrt Makefile translates that to apk-style `PKG_VERSION` (hyphens become underscores), and `make stage` ships a copy to `/usr/share/uapi/VERSION` so `main.uc` and `/healthz` report the same string.

This document walks through producing `uapi-<version>-r1.apk` for OpenWrt 25.12.5 using the official OpenWrt SDK. Substitute the actual version from the `VERSION` file (or the release page) wherever you see `<version>` below.

## Package contract

**No daemon of our own.** The package's job is (a) drop files, (b) wire our handler into uhttpd's config, (c) clean up that wiring on removal. There is no `uapi` process, no `procd` service definition, no init script.

**Wires only to the `main` uhttpd instance.** Operators running multiple uhttpd instances who want the API on another instance configure it manually (the post-install message points at this).

**No conflicts.** Coexists with rpcd, LuCI, and anything else hosted on uhttpd.

**No default token shipped.** Operators mint the first token via `uapi-token create` after install. Shipping a default would be a security hole.

**Distribution.** v1 launch ships on the project-owned OpenWrt feed at `openwrt-iac.github.io/feed/`. Submission to the official `packages` feed is open as openwrt/packages#30752, and is not a blocker.

## What gets installed

```
/usr/share/uapi/main.uc                  uhttpd ucode-prefix entry point
/usr/share/uapi/raw.uc                   generic /raw/<package>/<id> handler
/usr/share/uapi/VERSION                  package version (one line)
/usr/share/uapi/lib/*.uc                 every module in src/lib (the install globs
                                          the directory, so this needs no list here)
/usr/share/uapi/resources/*.uc           curated resource modules
/usr/share/uapi/openapi.json             generated OpenAPI 3.1 spec, without whitespace
/usr/share/uapi/config.template          comments that 99-uapi copies to a new token store
/usr/bin/uapi-token                      token CLI
/etc/uci-defaults/99-uapi                one-shot install hook
/lib/upgrade/keep.d/uapi                 names /etc/config/uapi for sysupgrade (written by the build)
```

Created by the install hook when it does not exist, and never a file of the package:

```
/etc/config/uapi                         token store, mode 0600
```

Runtime files created on first use (tmpfs, reset on reboot):

```
/var/run/uapi-ratelimit/<token>.txt          per-token bucket state
/var/run/uapi-idempotency/<sha>.json         per-key cached POST responses (24h TTL)
/var/run/uapi-metrics/<series>/<labels>.txt  Prometheus counter/histogram store
/var/run/uapi-error-ring/ring.json           the last 20 errors, for /diagnostics
/var/run/uapi-token-update/<token>           last-used throttle sentinel
/var/lock/uapi.lock                          global flock (SH for uci tx, EX for non-uci)
/var/lock/uapi.pkg.<package>.lock            per-package EX flock
```

`<token>` is the token name, or its sha256 when the name is longer than 63 characters.

The `/var/run/uapi-*` directories have mode 0700 and their files 0600, see `docs/architecture.md` § Where state lives.

Dependencies (pulled in automatically):

```
uhttpd uhttpd-mod-ucode ucode
ucode-mod-ubus ucode-mod-uci ucode-mod-fs ucode-mod-digest ucode-mod-log
rpcd-mod-iwinfo
```

## Build steps

### 1. Get the matching OpenWrt SDK

```sh
SDK_URL=https://downloads.openwrt.org/releases/25.12.5/targets/x86/64/openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
mkdir -p build/sdk
curl -L "$SDK_URL" | tar --use-compress-program=unzstd -xvf - -C build/sdk --strip-components=1
```

Adjust `targets/x86/64` for your target architecture if cross-compiling for something other than x86_64. uapi is pure ucode (`PKGARCH:=all`), so the resulting `.apk` is architecture-independent.

### 2. Stage the package files

```sh
make openapi   # regenerate build/openapi.json
make stage     # populate build/openwrt/uapi/files/
```

`make stage` needs `python3`, which the OpenWrt SDK requires on the host too. `tools/compact_json.py` writes the spec into the APK without whitespace, and the stage fails unless that copy parses to the same JSON value as `build/openapi.json`, with the keys in the same order. `main.uc` reads the file whole into every request process that serves `GET /api/v3/openapi.json`, and uhttpd does not compress it. The compact copy is about 30% smaller. `build/openapi.json` stays indented in the repository, because reviews read its diffs. The uapi package of the OpenWrt packages feed builds from the release tarball and copies `build/openapi.json` as it is, so it installs the indented file until its Makefile runs `tools/compact_json.py`. Its Makefile must also install `files/usr/share/uapi/config.template` into `/usr/share/uapi/`, and no longer install a file at `/etc/config/uapi`, whose source the tarball no longer holds. Without the template the install hook creates no token store: the copy prints its error in the output of apk, the hook goes on, and `uapi-token create` creates the store at the first token.

### 3. Build inside the SDK

```sh
cd build/sdk
./scripts/feeds update -a
./scripts/feeds install -a

# Add our package as a local feed entry. The Makefile expects to find
# ./files relative to itself, so symlink the package dir we just staged.
ln -s ../../openwrt/uapi package/uapi

make defconfig
make package/uapi/compile V=s
```

The output `.apk` lands at `bin/packages/all/base/uapi-<version>-r1.apk` (or whatever the SDK reports at the end of the build).

### 4. Install on a router

```sh
scp bin/packages/all/base/uapi-*.apk root@<router>:/tmp/
ssh root@<router> 'apk add /tmp/uapi-<version>-r1.apk'
ssh root@<router> 'uapi-token create --name first --scope "*:rw"'
```

The CLI prints the cleartext bearer to stdout exactly once. Save it.

## Post-install behavior

The `postinst` script runs `/etc/uci-defaults/99-uapi` immediately on live installs (not chroots/INSTROOT builds) and then deletes the script. In an image, the script runs at first boot instead. That single run:

1. Creates `/etc/config/uapi` from `/usr/share/uapi/config.template`, with mode 0600, when the file does not exist. It copies the template to a temporary file and links that into place, so a store that `uapi-token create` makes at the same moment is kept. On an existing store it only sets mode 0600, because `uapi-token create` up to 3.2.0 made a missing store 0644 and libuci keeps the mode of the file at each commit.
2. Strips any older mount (`/api/v2=`, `/api/v1=`) from `uhttpd.main.ucode_prefix`, so an upgraded box does not serve the same `main.uc` under a prefix whose surface no longer exists.
3. Adds `/api/v3=/usr/share/uapi/main.uc` unless it is already listed.
4. If step 2 or 3 changed something, commits the uhttpd config and, if uhttpd is enabled, reloads it.

`postinst` then restarts uhttpd, because uhttpd-mod-ucode caches the compiled VM at parent startup and a reload would keep serving the previous version's code.

Both steps leave a disabled uhttpd stopped. On OpenWrt, `reload` and `restart` both start a stopped service, and an operator can disable uhttpd on purpose, for example because another web server uses its ports. That operator starts uhttpd when they want the API.

After the restart, `postinst` removes `/var/run/uapi-idempotency`, `/var/run/uapi-metrics`, `/var/run/uapi-ratelimit`, `/var/run/uapi-error-ring` and `/var/run/uapi-token-update`, and the four that an older uapi kept in `/tmp` with mode 0755 and files 0644. It removes each only when it is itself a directory that root owns. They hold the 24 h replay window of the idempotency cache and state that a reboot clears too, so each starts empty in a directory that uapi creates 0700: the counters start again from zero, which Prometheus reads as a reset, every token has a full burst, `recent_errors` is empty, and the idempotency cache replays nothing from before. The removal comes after the restart, because the previous version keeps writing those directories until uhttpd stops it. A request of the previous version still in flight at the restart can write one again, and that one stays until a reboot.

After that, `https://<router>/api/v3/healthz` is reachable if uhttpd is enabled.

The post-install message, printed only when the token store holds no token yet (so upgrades and reinstalls stay quiet):

```
uapi installed. Bootstrap:
  1. Create a token:    uapi-token create --name <label> --scope '*:rw'
  2. Verify reachable:  uclient-fetch -qO - --no-check-certificate \
                          --header="Authorization: Bearer <token>" \
                          https://127.0.0.1/api/v3/system
  3. OpenAPI spec at:   /usr/share/uapi/openapi.json (also GET /api/v3/openapi.json)

Future upgrades from the project feed:
  uclient-fetch -qO /etc/apk/keys/uapi-feed.pub.pem \
    https://openwrt-iac.github.io/feed/uapi-feed.pub.pem
  echo 'https://openwrt-iac.github.io/feed/packages/all/uapi/packages.adb' > /etc/apk/repositories.d/uapi.list
  apk update && apk upgrade uapi
```

## Removal

`apk remove uapi` triggers the `prerm` hook, which:

1. Removes the `ucode_prefix` entry from `uhttpd.main`.
2. Commits uhttpd.
3. Reloads uhttpd, if it is enabled.

These three steps run BEFORE the handler file is deleted. Order matters: if the prefix entry survived past handler removal, uhttpd would dispatch `/api/v3/*` to a missing `main.uc` and every request would 500 until the operator manually fixed the uhttpd config. Reorder only with care.

apk keeps the token store at `/etc/config/uapi`, because it is no file of the package, and `apk del --purge` keeps it too. To wipe it: `rm /etc/config/uapi` after removal. `apk del` also removes `/lib/upgrade/keep.d/uapi`, and a sysupgrade still keeps the store, because base-files of OpenWrt 25.12.5 lists all of `/etc/config/` in `/lib/upgrade/keep.d/base-files`.

## Upgrade contract

The token store at `/etc/config/uapi` is precious user state. The package does not install it, and the install hook creates it when it does not exist. apk then never writes, replaces or deletes it, at an upgrade, a reinstall or a removal.

Up to 3.2.0 the package shipped a template at that path. apk-tools 3 protects `/etc`: at an upgrade it keeps a file there that differs from the one it installed, and writes the shipped copy beside it as `/etc/config/uapi.apk-new`. A store with tokens always differs, so every upgrade left that file. Do not install a file at `/etc/config/uapi` again.

At the upgrade from 3.2.0 or earlier, the package that owned the store goes away, and apk-tools 3.0.5 then handles the file as it handles every file that leaves a package in a protected path. It keeps a store that holds tokens, and deletes one that still equals the shipped template, which the install hook then creates again. It also deletes the `/etc/config/uapi.apk-new` that the earlier upgrades left. `apk upgrade --purge` across that upgrade deletes the store, and the install hook then creates it again from the template, without a token: with `--purge`, apk deletes every file that the old package shipped and the new one does not, changed or not.

sysupgrade keeps a conffile that a package ships only when it differs from the shipped file, by the checksum in `/lib/apk/packages/*.conffiles_static`, and it keeps every file that `/etc/sysupgrade.conf` and `/lib/upgrade/keep.d/*` name. `Package/uapi/conffiles` in the OpenWrt Makefile still lists `/etc/config/uapi`: for a listed conffile that the package does not ship, the build writes its path into `/lib/upgrade/keep.d/uapi`, as it does for the certificate and key of uhttpd. base-files of OpenWrt 25.12.5 lists all of `/etc/config/` in `/lib/upgrade/keep.d/base-files`, so a sysupgrade keeps the store without that entry too. The entry makes the package name its own store, so that its backup does not depend on a list of base-files. `tests/unit/package_test.uc` fails when the package installs a file at `/etc/config/uapi` or drops the entry.

Files under `/usr/share/uapi/` are package-owned and freely overwritten by the upgrade; never add conffile markers to handler or library files there or upgrades will stop replacing them.

## Release artifacts

Tag-pushed releases produce more than just the APK:

- **APK** at `bin/packages/all/uapi-<version>-r<N>.apk`. `PKGARCH:=all` means a single APK works on every OpenWrt arch.
- **SPDX 2.3 SBOM** at `build/sbom.spdx.json` (via `make sbom APK=<apk>`). Carries every shipped file's sha256, package dependencies, and the built APK's verification hash.
- **Multi-arch verification**: CI's `verify-arch-build` matrix cross-compiles against `aarch64_generic`, `arm_cortex-a7`, and `mips_24kc` SDKs. It does NOT prove arch-neutrality: it compares no digests and has no x86_64 leg to compare against. What it hard-fails on is a missing per-arch SDK pin, a tarball that does not match its pin, a cross-build that breaks, and a build that yields no `.apk`. See the comment on the job itself.
- **Signed tag**: required for the `release-apk` job to run; verified against `.github/release-signers.asc`.
- **Reproducible SDK pin**: `build/sdk.sha256` records the exact SDK tarball checksums for all four arches.

See `docs/release-process.md` for the full release flow, signed-tag setup, and pre-tag checklist.
