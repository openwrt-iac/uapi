# Building the uapi APK

The version comes from a single source: the `VERSION` file at the repo root (semver, e.g. `1.0.0-rc1`). The OpenWrt Makefile translates that to apk-style `PKG_VERSION` (hyphens become underscores), and `make stage` ships a copy to `/usr/share/uapi/VERSION` so `main.uc` and `/healthz` report the same string.

This document walks through producing `uapi-<version>-r1.apk` for OpenWrt 25.12.4 using the official OpenWrt SDK. Substitute the actual version from the `VERSION` file (or the release page) wherever you see `<version>` below.

## What gets installed

```
/usr/share/uapi/main.uc                  uhttpd ucode-prefix entry point
/usr/share/uapi/raw.uc                   generic /raw/<package>/<id> handler
/usr/share/uapi/VERSION                  package version (one line)
/usr/share/uapi/lib/*.uc                 shared modules (auth, scope, transaction,
                                          handler, errors, ids, ratelimit, metrics,
                                          idempotency, jsonpatch, token_store,
                                          non_uci, system_access, packages, log,
                                          bus, values, ucitrack, openapi)
/usr/share/uapi/resources/*.uc           curated resource modules (32 files)
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
SDK_URL=https://downloads.openwrt.org/releases/25.12.4/targets/x86/64/openwrt-sdk-25.12.4-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
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

1. Checks if `uhttpd.main.ucode_prefix` already lists `/api/v1=/usr/share/uapi/main.uc`. If so, exits cleanly.
2. Otherwise adds the entry, commits the uhttpd config, and reloads uhttpd.

After that, `https://<router>/api/v1/healthz` is reachable.

## Removal

`apk remove uapi` triggers the `prerm` hook, which:

1. Removes the `ucode_prefix` entry from `uhttpd.main`.
2. Commits uhttpd.
3. Reloads uhttpd.

The token store at `/etc/config/uapi` is preserved (conffile semantics). To wipe it: `rm /etc/config/uapi` after removal.

## Release artifacts

Tag-pushed releases produce more than just the APK:

- **APK** at `bin/packages/all/uapi-<version>-r<N>.apk`. `PKGARCH:=all` means a single APK works on every OpenWrt arch.
- **SPDX 2.3 SBOM** at `build/sbom.spdx.json` (via `make sbom APK=<apk>`). Carries every shipped file's sha256, package dependencies, and the built APK's verification hash.
- **Multi-arch verification**: CI's `verify-arch-build` matrix cross-compiles against `aarch64_generic`, `arm_cortex-a7`, and `mips_24kc` SDKs to prove the arch-neutrality invariant (no compiled code snuck in).
- **Signed tag**: required for the publish workflow to run; verified against `.github/allowed-signers`.
- **Reproducible SDK pin**: `build/sdk.sha256` records the exact SDK tarball checksums for all four arches.

See `docs/release-process.md` for the full release flow, signed-tag setup, and pre-tag checklist.
