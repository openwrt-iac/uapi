# Building the uapi APK

The version comes from a single source: the `VERSION` file at the repo root
(semver, e.g. `1.0.0-rc1`). The OpenWrt Makefile translates that to apk-style
`PKG_VERSION` (hyphens become underscores), and `make stage` ships a copy to
`/usr/share/uapi/VERSION` so `main.uc` and `/healthz` report the same string.

This document walks through producing `uapi-<version>-r1.apk` for OpenWrt main
using the snapshot SDK of OpenWrt main. Substitute the actual version from the
`VERSION` file (or the release page) wherever you see `<version>` below.

## Package contract

**No daemon of our own.** The package's job is (a) drop files, (b) wire our
handler into uhttpd's config, (c) clean up that wiring on removal. There is no
`uapi` process, no `procd` service definition, no init script.

**Wires only to the `main` uhttpd instance.** Operators running multiple uhttpd
instances who want the API on another instance configure it manually.

**No conflicts.** Coexists with rpcd, LuCI, and anything else hosted on uhttpd.

**No default token shipped.** Operators mint the first token via `uapi-token
create` after install. Shipping a default would be a security hole.

**Distribution.** The package ships on the project-owned OpenWrt feed at
`openwrt-iac.github.io/feed/`. Submission to the official `packages` feed is
open as openwrt/packages#30752, and is not a blocker.

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

Created by the install hook when it does not exist, and never a file of the
package:

```
/etc/config/uapi                         token store, mode 0600
```

uapi creates its runtime files under `/var/run` and `/var/lock` on first use.
They are on tmpfs, so a reboot resets them. `docs/architecture.md` § Where state
lives lists each of them with its mode and lifetime.

Dependencies (pulled in automatically):

```
uhttpd uhttpd-mod-ucode ucode
ucode-mod-ubus ucode-mod-uci ucode-mod-fs ucode-mod-digest ucode-mod-log ucode-mod-io
rpcd-mod-iwinfo
```

`main.uc` uses `ucode-mod-io` to make the stdin of a request non-blocking, so
that a request body that does not arrive answers 400 after 10 s instead of
holding the request until the script timeout of uhttpd (`docs/security.md`,
Public endpoints). It installs `/usr/lib/ucode/io.so`, 20 KB on x86_64 (a 7 KB
apk). A package built without the dependency still runs, but has no deadline:
uapi then reads a body from the blocking pipe, and logs one `uapi-body-deadline`
line when uhttpd starts.

## The netifd floor

uapi 4.x supports OpenWrt main and the release that OpenWrt cuts from it, and
not OpenWrt 25.12. Routers on 25.12 stay on uapi 3.5.0. The package tells apk
with a versioned dependency in `build/openwrt/uapi/Makefile`:

```
EXTRA_DEPENDS:=netifd (>=2026.07.17)
```

The build writes it into the metadata of the APK as `netifd>=2026.07.17`, as it
writes `ucode>=2022.03.22` for the `EXTRA_DEPENDS` of `firewall4`. The APK
smoke test checks that the installed package carries it.

OpenWrt names a package that it builds from a git commit
`<date>~<commit>-r<release>`, from `PKG_SOURCE_DATE` and `PKG_SOURCE_VERSION` in
its Makefile (`include/download.mk` of OpenWrt). The date is the commit date in
netifd. netifd commit e97e36f ("config: accept 'true' for the interface disabled
option", which #311 needs) has the commit date 2026-07-17, and the floor is that
date:

| OpenWrt                                 | netifd                            | apk      |
|-----------------------------------------|-----------------------------------|----------|
| 25.12.6, and the `openwrt-25.12` branch | `2026.02.26~cbb83a18-r2`          | refuses  |
| main before 2026-09-13                  | `2026.07.08~6088f7b3-rN` or older | refuses  |
| main from 2026-09-13                    | `2026.09.11~06d06c86-r1`          | installs |
| main on 2026-11-22                      | `2026.10.28~a1e39a45-r1`          | installs |

apk compares the dotted date first. It sorts `2026.07.17~<commit>-r1` after
`2026.07.17`, so a netifd built from e97e36f itself passes too. `apk version -t`
of apk-tools 3.0.5, the apk of 25.12, gives these results.

On 25.12, apk refuses the package before it changes a file or runs a script:

- `apk add` of the APK file, or `apk add 'uapi>=4'`, stops with exit status 3:

  ```
  ERROR: unable to select packages:
    netifd-2026.02.26~cbb83a18-r2:
      breaks: uapi-<version>-r1[netifd>=2026.07.17]
      satisfies: world[netifd]
                 base-files-1718~981c978eff[netifd]
  ```

  On a router with 3.x, 3.x stays installed and keeps its token store.
- `apk upgrade` and `apk upgrade uapi`, with a feed that serves 4.x, keep 3.x
  and print nothing about uapi. `apk list --upgradable` still lists 4.x.
- `apk add uapi` on a router without uapi, from a feed that serves only 4.x,
  fails with the same error.

The floor is a date, not a commit. If a later 25.12 release takes a netifd of
the `openwrt-25.12` branch with a commit date after 2026-07-17, that netifd
passes the floor without e97e36f. Before each 4.x release, read
`package/network/config/netifd/Makefile` on the `openwrt-25.12` branch of
OpenWrt, and raise the floor above its date if needed.

## Build steps

### 1. Get the OpenWrt SDK

```sh
tools/openwrt-sdk.sh fetch x86/64 build/sdk
```

The script downloads the snapshot SDK of OpenWrt main for the target. OpenWrt
rebuilds it daily under the same name and deletes the previous one, so the
repository cannot pin its checksum. The script checks the signature of the
`sha256sums` published beside the SDK against
`build/openwrt-snapshot-usign.pub`, the usign key of the OpenWrt snapshot builds
(`usign/b5043e70f9a75cde` of the OpenWrt keyring), then the tarball against
those sums. It needs `signify-openbsd`, or `SIGNIFY=usign` where usign is
installed.

Give another target, such as `armsr/armv8`, if cross-compiling for something
other than x86_64. uapi is pure ucode (`PKGARCH:=all`), so the resulting `.apk`
is architecture-independent.

### 2. Stage the package files

```sh
make openapi   # regenerate build/openapi.json
make stage     # populate build/openwrt/uapi/files/
```

`make stage` needs `python3`, which the OpenWrt SDK requires on the host too.
`tools/compact_json.py` writes the spec into the APK without whitespace, and the
stage fails unless that copy parses to the same JSON value as
`build/openapi.json`, with the keys in the same order. `main.uc` reads the file
whole into every request process that serves `GET /api/v4/openapi.json`, and
uhttpd does not compress it. The compact copy is about 30% smaller.
`build/openapi.json` stays indented in the repository, because reviews read its
diffs. The uapi package of the OpenWrt packages feed builds from the release
tarball and copies `build/openapi.json` as it is, so it installs the indented
file until its Makefile runs `tools/compact_json.py`. Its Makefile must also
install `files/usr/share/uapi/config.template` into `/usr/share/uapi/`, and no
longer install a file at `/etc/config/uapi`, whose source the tarball no longer
holds. Without the template the install hook creates no token store: the copy
prints its error in the output of apk, the hook goes on, and `uapi-token create`
creates the store at the first token.

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

The output `.apk` lands under `bin/packages/<arch>/base/`, where `<arch>` is
the architecture of the SDK, such as
`bin/packages/x86_64/base/uapi-<version>-r1.apk`. The package itself is
`PKGARCH:=all`.

### 4. Install on a router

```sh
scp bin/packages/*/base/uapi-*.apk root@<router>:/tmp/
ssh root@<router> 'apk add /tmp/uapi-<version>-r1.apk'
ssh root@<router> 'uapi-token create --name first --scope "*:rw"'
```

The CLI prints the cleartext bearer to stdout exactly once. Save it.

## Post-install behavior

On OpenWrt 25.12, apk refuses the package before it runs a script (see The
netifd floor), so nothing below runs there.

The `postinst` script runs `/etc/uci-defaults/99-uapi` immediately on live
installs (not chroots/INSTROOT builds) and then deletes the script. In an image,
the script runs at first boot instead. That single run:

1. Creates `/etc/config/uapi` from `/usr/share/uapi/config.template`, with mode
   0600, when the file does not exist. It copies the template to a temporary
   file and links that into place, so a store that `uapi-token create` makes at
   the same moment is kept. On an existing store it only sets mode 0600, because
   `uapi-token create` up to 3.2.0 made a missing store 0644 and libuci keeps
   the mode of the file at each commit.
2. Strips any older mount (`/api/v3=`, `/api/v2=`, `/api/v1=`) from
   `uhttpd.main.ucode_prefix`, so an upgraded box does not serve the same
   `main.uc` under a prefix whose surface no longer exists.
3. Adds `/api/v4=/usr/share/uapi/main.uc` unless it is already listed.
4. If step 2 or 3 changed something, commits the uhttpd config and, if uhttpd is
   enabled, reloads it.

`postinst` then restarts uhttpd, because uhttpd-mod-ucode caches the compiled VM
at parent startup and a reload would keep serving the previous version's code.

One second after the restart, `postinst` asks procd whether every uhttpd
instance runs. A uhttpd that cannot load a plugin exits within that second. When
one does not run, `postinst` prints that neither uapi nor LuCI answers, and the
commands that align `uhttpd` and its `uhttpd-mod-*` on the feed (see
`docs/installation.md`, Align the uhttpd packages first), which is the cause on
an image whose feed was rebuilt after it. It reports and does not
upgrade them itself. The install still ends with status 0, because the package
files are in place.

Both steps leave a disabled uhttpd stopped. On OpenWrt, `reload` and `restart`
both start a stopped service, and an operator can disable uhttpd on purpose, for
example because another web server uses its ports. That operator starts uhttpd
when they want the API.

After the restart, `postinst` removes `/var/run/uapi-idempotency`,
`/var/run/uapi-metrics`, `/var/run/uapi-ratelimit`, `/var/run/uapi-error-ring`,
`/var/run/uapi-token-update` and `/var/run/uapi-interrupted-writes`, and the
four that an older uapi kept in `/tmp` with mode 0755 and files 0644. It removes
each only when it is itself a directory that root owns. They hold the 24 h
replay window of the idempotency cache and state that a reboot clears too, so
each starts empty in a directory that uapi creates 0700: the counters start
again from zero, which Prometheus reads as a reset, every token has a full
burst, `recent_errors` and `interrupted_writes` are empty, and the idempotency
cache replays nothing from before. The removal comes after the restart, because
the previous version keeps writing those directories until uhttpd stops it. A
request of the previous version still in flight at the restart can write one
again, and that one stays until a reboot.

After that, `https://<router>/api/v4/healthz` is reachable if uhttpd is enabled.

The post-install message, printed only when the token store holds no token yet
(so upgrades and reinstalls stay quiet):

```
uapi installed. Bootstrap:
  1. Create a token:    uapi-token create --name <label> --scope '*:rw'
  2. Verify reachable:  uclient-fetch -qO - --no-check-certificate \
                          --header="Authorization: Bearer <token>" \
                          https://127.0.0.1/api/v4/system
  3. OpenAPI spec at:   /usr/share/uapi/openapi.json (also GET /api/v4/openapi.json)

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

These three steps run BEFORE the handler file is deleted. Order matters: if the
prefix entry survived past handler removal, uhttpd would dispatch `/api/v4/*` to
a missing `main.uc` and every request would 500 until the operator manually
fixed the uhttpd config. Reorder only with care.

apk keeps the token store at `/etc/config/uapi`, because it is no file of the
package, and `apk del --purge` keeps it too. To wipe it: `rm /etc/config/uapi`
after removal. `apk del` also removes `/lib/upgrade/keep.d/uapi`, and a
sysupgrade still keeps the store, because base-files of OpenWrt 25.12.5 lists
all of `/etc/config/` in `/lib/upgrade/keep.d/base-files`.

## Upgrade contract

The token store at `/etc/config/uapi` is precious user state. The package does
not install it, and the install hook creates it when it does not exist. apk then
never writes, replaces or deletes it, at an upgrade, a reinstall or a removal.

An upgrade from 3.x to 4.x happens on OpenWrt main only. The APK smoke test
upgrades from 3.2.0 on the main snapshot. On 25.12, apk refuses the upgrade as
a whole before it changes a file (see The netifd floor), so the router keeps
3.x, its `/api/v3` mount and its token store.

Up to 3.2.0 the package shipped a template at that path. apk-tools 3 protects
`/etc`: at an upgrade it keeps a file there that differs from the one it
installed, and writes the shipped copy beside it as `/etc/config/uapi.apk-new`.
A store with tokens always differs, so every upgrade left that file. Do not
install a file at `/etc/config/uapi` again.

At the upgrade from 3.2.0 or earlier, the package that owned the store goes
away, and apk-tools 3.0.5 then handles the file as it handles every file that
leaves a package in a protected path. It keeps a store that holds tokens, and
deletes one that still equals the shipped template, which the install hook then
creates again. It also deletes the `/etc/config/uapi.apk-new` that the earlier
upgrades left. `apk upgrade --purge` across that upgrade deletes the store, and
the install hook then creates it again from the template, without a token: with
`--purge`, apk deletes every file that the old package shipped and the new one
does not, changed or not.

sysupgrade keeps a conffile that a package ships only when it differs from the
shipped file, by the checksum in `/lib/apk/packages/*.conffiles_static`, and it
keeps every file that `/etc/sysupgrade.conf` and `/lib/upgrade/keep.d/*` name.
`Package/uapi/conffiles` in the OpenWrt Makefile still lists `/etc/config/uapi`:
for a listed conffile that the package does not ship, the build writes its path
into `/lib/upgrade/keep.d/uapi`, as it does for the certificate and key of
uhttpd. base-files of OpenWrt 25.12.5 lists all of `/etc/config/` in
`/lib/upgrade/keep.d/base-files`, so a sysupgrade keeps the store without that
entry too. The entry makes the package name its own store, so that its backup
does not depend on a list of base-files. `tests/unit/package_test.uc` fails when
the package installs a file at `/etc/config/uapi` or drops the entry.

Files under `/usr/share/uapi/` are package-owned and freely overwritten by the
upgrade; never add conffile markers to handler or library files there or
upgrades will stop replacing them.

## Release artifacts

Tag-pushed releases produce more than just the APK:

- **APK** at `bin/packages/<arch>/base/uapi-<version>-r<N>.apk` in the SDK.
  `PKGARCH:=all` means a single APK works on every OpenWrt arch.
- **SPDX 2.3 SBOM** at `build/sbom.spdx.json` (via `make sbom APK=<apk>`).
  Carries every shipped file's sha256, package dependencies, and the built APK's
  verification hash.
- **Multi-arch verification**: CI's `verify-arch-build` matrix cross-compiles
  against `aarch64_generic`, `arm_cortex-a7`, and `mips_24kc` SDKs. It does NOT
  prove arch-neutrality: it compares no digests and has no x86_64 leg to compare
  against. What it hard-fails on is, at an SDK download, `sha256sums` without a
  valid signature of the snapshot key, a tarball that does not match those sums,
  a cross-build that breaks, and a build that yields no `.apk`. See the comment
  on the job itself.
- **Signed tag**: required for the `release-apk` job to run; verified against
  `.github/release-signers.asc`.
- **SDK signing key**: `build/openwrt-snapshot-usign.pub` pins the key that
  signs the checksums of the snapshot SDKs of every target. It pins who built
  the SDK, not its bytes, and the SDK of a release cannot be downloaded again
  after the next snapshot. `docs/release-process.md`, Reproducible builds, says
  what a verifier checks instead.

See `docs/release-process.md` for the full release flow, signed-tag setup, and
pre-tag checklist.
