# Building the uapi APK

The version comes from a single source: the `VERSION` file at the repo root (semver, e.g. `1.0.0-rc1`). The OpenWrt Makefile translates that to apk-style `PKG_VERSION` (hyphens become underscores), and `make stage` ships a copy to `/usr/share/uapi/VERSION` so `main.uc` and `/healthz` report the same string.

This document walks through producing `uapi-<version>-r1.apk` for OpenWrt 25.12.5 using the official OpenWrt SDK. Substitute the actual version from the `VERSION` file (or the release page) wherever you see `<version>` below.

## Package contract

**No daemon of our own.** The package's job is (a) drop files, (b) wire our handler into uhttpd's config, (c) clean up that wiring on removal. There is no `uapi` process, no `procd` service definition, no init script.

**Wires only to the `main` uhttpd instance.** Operators running multiple uhttpd instances who want the API on another instance configure it manually (the post-install message points at this).

**No conflicts.** Coexists with rpcd, LuCI, and anything else hosted on uhttpd.

**No default token shipped.** Operators mint the first token via `uapi-token create` after install. Shipping a default would be a security hole.

**Distribution.** v1 launch ships on the project-owned OpenWrt feed at `openwrt-iac.github.io/feed/`. Submission to the official `packages` feed is a later step, not a blocker.

## What gets installed

```
/usr/share/uapi/main.uc                  uhttpd ucode-prefix entry point
/usr/share/uapi/raw.uc                   generic /raw/<package>/<id> handler
/usr/share/uapi/VERSION                  package version (one line)
/usr/share/uapi/lib/*.uc                 every module in src/lib (the install globs
                                          the directory, so this needs no list here)
/usr/share/uapi/resources/*.uc           curated resource modules
/usr/share/uapi/openapi.json             generated OpenAPI 3.1 spec
/usr/bin/uapi-token                      token CLI
/etc/config/uapi                         conffile (mode 0600, conffile-marked)
/etc/uci-defaults/99-uapi                one-shot install hook
```

Runtime files created on first use (tmpfs, reset on reboot):

```
/tmp/uapi-ratelimit/<token>.txt          per-token bucket state
/tmp/uapi-idempotency/<sha>.json         per-key cached POST responses (24h TTL)
/tmp/uapi-metrics/<series>/<labels>.txt  Prometheus counter/histogram store
/var/run/uapi-token-update/<token>       last-used throttle sentinel
/var/lock/uapi.lock                      global flock (SH for uci tx, EX for non-uci)
/var/lock/uapi.pkg.<package>.lock        per-package EX flock
```

`/etc/config/uapi` is marked as a conffile, so upgrades preserve
operator-created tokens.

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

The `postinst` script runs `/etc/uci-defaults/99-uapi` immediately on live installs (not chroots/INSTROOT builds) and then deletes the script. That single run:

1. Strips any older mount (`/api/v2=`, `/api/v1=`) from `uhttpd.main.ucode_prefix`, so an upgraded box does not serve the same `main.uc` under a prefix whose surface no longer exists.
2. Adds `/api/v3=/usr/share/uapi/main.uc` unless it is already listed.
3. Commits the uhttpd config and reloads uhttpd, but only if either step changed something.

`postinst` then restarts uhttpd unconditionally, because uhttpd-mod-ucode caches the compiled VM at parent startup and a reload would keep serving the previous version's code.

After that, `https://<router>/api/v3/healthz` is reachable.

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
3. Reloads uhttpd.

These three steps run BEFORE the handler file is deleted. Order matters: if the prefix entry survived past handler removal, uhttpd would dispatch `/api/v3/*` to a missing `main.uc` and every request would 500 until the operator manually fixed the uhttpd config. Reorder only with care.

The token store at `/etc/config/uapi` is preserved (conffile semantics). To wipe it: `rm /etc/config/uapi` after removal.

## Upgrade contract

`/etc/config/uapi` is marked as a conffile (`Package/uapi/conffiles` in the OpenWrt Makefile). The token store is precious user state and is preserved across `apk upgrade`. Files under `/usr/share/uapi/` are package-owned and freely overwritten by the upgrade; never add conffile markers to handler or library files there or upgrades will stop replacing them.

## Release artifacts

Tag-pushed releases produce more than just the APK:

- **APK** at `bin/packages/all/uapi-<version>-r<N>.apk`. `PKGARCH:=all` means a single APK works on every OpenWrt arch.
- **SPDX 2.3 SBOM** at `build/sbom.spdx.json` (via `make sbom APK=<apk>`). Carries every shipped file's sha256, package dependencies, and the built APK's verification hash.
- **Multi-arch verification**: CI's `verify-arch-build` matrix cross-compiles against `aarch64_generic`, `arm_cortex-a7`, and `mips_24kc` SDKs. It does NOT prove arch-neutrality: it compares no digests and has no x86_64 leg to compare against. What it hard-fails on is a missing per-arch SDK pin, a tarball that does not match its pin, a cross-build that breaks, and a build that yields no `.apk`. See the comment on the job itself.
- **Signed tag**: required for the `release-apk` job to run; verified against `.github/release-signers.asc`.
- **Reproducible SDK pin**: `build/sdk.sha256` records the exact SDK tarball checksums for all four arches.

See `docs/release-process.md` for the full release flow, signed-tag setup, and pre-tag checklist.
