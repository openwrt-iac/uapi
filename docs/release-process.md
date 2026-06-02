# uapi release process

What ships, who signs what, where it lands. This document is operator-facing;
the high-level architectural contract lives in `CLAUDE.md`.

## Architecture neutrality

uapi is `PKGARCH:=all` (in `build/openwrt/uapi/Makefile`). The package
contains no compiled code - only ucode scripts and shell glue - so the same
`uapi-<version>-<release>.apk` is consumable by every OpenWrt host
architecture (x86_64, aarch64, arm, mips, etc.) at the same OpenWrt major
version. We do NOT build a separate APK per arch; the OpenWrt apk-tools
install handles arch-neutral packages directly.

The `release-apk` job builds a single APK (against the x86_64 SDK because
that's the simplest to host on GitHub runners), smoke-tests it in an x86
QEMU VM, and publishes that one artifact to both the GitHub Release and
the gh-pages feed.

The `verify-arch-build` matrix job cross-compiles against the SDKs for
`aarch64_generic`, `arm_cortex-a7`, and `mips_24kc` on tag push to PROVE
the arch-neutrality invariant - if any arch's build diverges from
expectation, something arch-specific snuck into the package and the
release should be held. Per-arch SDK tarball sha256 lives in
`build/sdk.sha256`; refresh those lines whenever `OPENWRT_VERSION` bumps
(URLs are in the matrix in `.github/workflows/ci.yml`).

### Pre-tag arch validation

`verify-arch-build` also accepts `workflow_dispatch`, so you can validate
the SDK pins against a candidate without tagging:

```
gh workflow run ci.yml --ref main
```

This fires the same `unit + lint + integration + verify-arch-build`
chain that a tag push would, minus the `release-apk` publish steps.
Useful right after bumping `OPENWRT_VERSION` to confirm the new
per-arch sha256 lines actually match upstream.

Operators who want a runtime per-arch smoke test (the CI matrix only
verifies compile) can run
`tests/integration/release_apk_smoke.sh <path-to-apk>` against their own
arch's QEMU VM or live router.

## Versioning

`VERSION` at the repo root drives every other version string:

- `build/openwrt/uapi/Makefile` reads it via `$(shell sed 's/-/_/g' files/VERSION)`.
- `build/gen_openapi.uc` reads it and stamps `info.version`.
- `src/main.uc` reads it at parent VM startup; `/healthz` returns it.
- CI tag-verification compares the pushed tag against the file.

Bump `VERSION`, regenerate `build/openapi.json` via `make openapi`, commit.

## Release flow

Per-release steps (operator does these in order):

1. **Cut a release candidate branch** if the release is substantive
   (`v2.0.0-rc1`). For patch releases, just work on a topic branch.
2. **Update `VERSION`** to the target value. **Regenerate** the OpenAPI:
   `make openapi`. Commit.
3. **Update `CHANGELOG.md`** with the section for the new version. Even
   for `rc` releases. Commit.
4. **Run the full test suite locally**: `make test coverage`. The CI runs
   `make lint test-unit coverage` plus the integration / soak / bench
   suite, so a green local `make test coverage` is necessary but not
   sufficient.
5. **Open PR, get CI green**: lint + unit + coverage gate + integration +
   soak (RSS/fd growth thresholds) + bench (p99 regression gate vs
   `bench/baseline.json`).
6. **Merge to main**.
7. **Sign and push the tag**:
   ```
   git tag -s v2.0.0 -m "v2.0.0"
   git push origin v2.0.0
   ```
   The tag MUST be signed with a GPG key whose public block is in
   `.github/release-signers.asc`. Set up once locally:
   ```
   git config --global user.signingkey <YOUR-GPG-FINGERPRINT>
   git config --global tag.gpgsign true
   gpg --armor --export <YOUR-GPG-FINGERPRINT> > .github/release-signers.asc
   git add .github/release-signers.asc && git commit -m "release: trust <fingerprint>"
   git push
   ```
   CI's release-apk job runs `git verify-tag` first; an unsigned tag (or a
   tag from a signer not in the allowed list) fails the workflow before
   any artifact is produced.
8. **Watch the release-apk workflow.** It runs (in order):
   - tag signature verification
   - reproducible-SDK pin check (against `build/sdk.sha256`)
   - SDK download + sha256 verify
   - `make stage` (populate `build/openwrt/uapi/files`)
   - `make package/uapi/compile` in the SDK
   - APK upload as workflow artifact
   - VM smoke test (`tests/integration/release_apk_smoke.sh`)
   - GitHub Release create + APK attach
   - gh-pages feed publish (signed index, `apk mkndx --sign-key`)
9. **Verify the release** is visible on GitHub Releases and the gh-pages
   feed.

## Reproducible builds

The SDK pin in `build/sdk.sha256` records the exact OpenWrt SDK tarball
URL + sha256 used for the release. CI verifies the checksum before
unpacking. An independent verifier can:

```
sha256sum -c build/sdk.sha256             # verify the SDK was the expected one
make stage                                # populate files/
( cd build/sdk && make package/uapi/compile )
sha256sum bin/packages/all/uapi-*.apk     # compare against the released APK
```

The build is deterministic: file ordering in the APK is sorted; the
package Makefile sets `PKG_RELEASE` so the version string doesn't change
between local and CI builds; `BUILD_DATE` can be overridden in CI if
needed for fully byte-identical builds.

## SBOM

`make sbom` emits SPDX 2.3 JSON at `build/sbom.spdx.json`. The CI release
workflow generates the SBOM and attaches it to the GitHub Release
alongside the APK:

```
make sbom APK=$(find build/sdk/bin -name 'uapi-*.apk' | head -1)
gh release upload v2.0.0 build/sbom.spdx.json --clobber
```

The SBOM lists every shipped file's sha256, every package dependency
(`uhttpd`, `uhttpd-mod-ucode`, etc.), and the package itself with the
built APK's verification sha256. Operators using SBOM-aware deployment
tooling (cosign, syft, etc.) can consume it directly.

## Auto-CHANGELOG

`CHANGELOG.md` is hand-curated, not auto-generated. The generator-driven
approach (`tools/gen_changelog.sh` against `git log --format='%s'
<prev-tag>..HEAD`) was considered for v2 and rejected: hand-written
changelog entries are more useful to operators (they explain *why*, not
just *what*) and the project's commit-subject convention is consistent
enough that an auto-generator would mostly produce
a list of `feat:` / `fix:` lines that any reader could compose from
`git log` directly.

## Pre-release verification checklist

Before tagging:

- [ ] `VERSION` matches the target tag.
- [ ] `build/openapi.json`'s `info.version` matches (`make openapi-check`).
- [ ] `CHANGELOG.md` has the entry for this version.
- [ ] `make test coverage` green.
- [ ] CI on `main` green for the commit that will be tagged.
- [ ] `.github/release-signers.asc` contains your GPG public key block.
- [ ] `build/sdk.sha256` pins ALL four arch SDKs at the right
  `OPENWRT_VERSION` (x86_64 + aarch64_generic + arm_cortex-a7 + mips_24kc).
- [ ] `gh workflow run ci.yml --ref main` green - validates the per-arch
  SDK pins via `verify-arch-build` without consuming a tag.

After tagging, before announcing:

- [ ] release-apk workflow completed.
- [ ] verify-arch-build matrix completed (all three non-x86 arches green).
- [ ] APK attached to the GitHub Release.
- [ ] APK visible in the gh-pages feed; `apk update` finds it.
- [ ] Smoke install on a real router works.
- [ ] SBOM attached.

## Rollback

If a tagged release is broken in the field:

1. Identify the breakage; file an issue.
2. Mark the GitHub Release as "Pre-release" or "Draft" via `gh release
   edit <tag> --prerelease` to demote it in the UI.
3. Ship a `vX.Y.(Z+1)` patch with the fix; the gh-pages feed automatically
   carries the highest version forward.
4. The broken APK stays in the feed (operators who pinned the broken
   version aren't auto-downgraded), but new installs and `apk upgrade
   uapi` resolve to the patched version.

We do not delete published APKs from the gh-pages feed.

## If uapi ever grows compiled code

The current arch-neutrality contract depends on `PKGARCH:=all` in
`build/openwrt/uapi/Makefile` (pure ucode + shell). If a future change
adds a C component:

1. Drop `PKGARCH:=all` from the package Makefile.
2. Convert `release-apk` from a single job into a matrix over arch (same
   matrix `verify-arch-build` uses today).
3. The smoke test still only runs on x86_64 (the QEMU image we host); add
   per-arch QEMU images if real runtime coverage matters.
4. Plan for ~4x release-apk runtime.

This is documented in case the principle is ever revisited; the
architectural intent is that it should not be.
