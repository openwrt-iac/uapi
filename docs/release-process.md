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
QEMU VM, and attaches that one artifact to the GitHub Release. The apk
feed itself is rebuilt by
`openwrt-iac/openwrt-iac.github.io`'s `publish.yml` workflow, which
pulls the latest stable Release asset from each source repo listed in
its `feed.yml`. uapi no longer owns a gh-pages feed of its own.

The `verify-arch-build` matrix job cross-compiles against the SDKs for
`aarch64_generic`, `arm_cortex-a7`, and `mips_24kc` on tag push. It does
not prove arch-neutrality, despite what this said until 2.5.0: it
compares no digests and has no x86_64 leg to compare against. It fails
the release on a missing per-arch SDK pin, a tarball that does not match
its pin, a cross-build that breaks under any of the three, or a build
that produces no `.apk` - which is what 2.4.1 actually relied on. Per-arch SDK tarball sha256 lives in
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
- CI verifies the tag's signature, not its name: nothing compares the pushed
  tag against the file, so that stays a manual checklist item below.

Bump `VERSION`, regenerate `build/openapi.json` via `make openapi`, commit.

## Candidate sweep before a version number is fixed

Once a release number is on the table, sweep for work that belongs in it before
cutting the branch. The point is not to pad the release: it is that the bracket
the number implies is decided at that moment, and something eligible left behind
usually waits a whole cycle, while something ineligible slipped in forces a
retag.

Look at least at the open issues, the open PRs, `docs/roadmap.md`, and whatever
is already sitting under `## [Unreleased]` in `CHANGELOG.md`. Also worth a
glance: `docs/deprecations.md` when a removal window has come due, and anything
previously parked as blocked upstream, since the blocker may have cleared.

Filter each candidate through the bracket in `docs/versioning.md` rather than by
how useful it is. A patch takes bug fixes with no surface change, plus the
carve-out for a tightening whose old behaviour produced state no caller could
rely on. A minor takes anything additive. Field deprecations are additive spec
surface and belong in a minor even when the fix they accompany is a patch.

Two things this catches, both seen in practice. Roadmap entries go stale: the
hardening section once listed four items as outstanding that had all shipped,
one of them a release earlier. And a fix can look patch-sized while carrying a
minor-sized companion, which is how a header meant to report an apply outcome
nearly rode along with the bug fix it belonged to.

Record the outcome even when it is empty. "Swept, nothing eligible" is worth
saying, because the next reader cannot tell a sweep that found nothing from a
sweep that never happened.

## Release flow

### Major versions ship as `-rc` first

For any MAJOR bump, tag `vX.0.0-rc1` (or `-rc2`, etc.) BEFORE the final
`vX.0.0`. The release-apk workflow auto-detects `-rc/-alpha/-beta/-pre`
and marks the GitHub release as a prerelease (its
`case "$TAG" in *-rc*|*-alpha*|*-beta*|*-pre*) PRE=--prerelease ;;` block).

**RCs do NOT publish to the apk feed.** The feed aggregator at
`openwrt-iac/openwrt-iac.github.io` pulls each source repo's latest
*stable* GitHub Release via `gh release list --exclude-pre-releases`;
prereleases are filtered out at the source. RCs go to the uapi GitHub
Release page only, marked `--prerelease`; operators who want to
install one download the APK from the release page and
`apk add --allow-untrusted /tmp/uapi-<rc>.apk` deliberately. Same
path the maintainer uses to dogfood the RC on the live router.

Announce the RC explicitly to known downstream consumers - the
`openwrt-iac/uapi` Terraform provider author, anyone with a published
client - and give them a ~1-2 week window to file wire-surface
feedback. Promote `rc<N>` to the final `vX.0.0` only after the window
closes with no fundamental issues outstanding. v2.0.0 went straight to
stable and immediately surfaced material provider-side feedback; this
rule exists to convert that "post-release scramble" into "pre-release
polish".

Skip RCs for MINOR or PATCH unless the change set is unusually large.

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
   soak (RSS/fd growth thresholds) + bench. The bench measures and reports
   per-endpoint p99; it does not gate, because no baseline is committed. Read
   the numbers in the run log or the `bench-run` artifact if a release is
   expected to move latency.
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
   - GitHub Release create + APK attach (always; RCs get `--prerelease`)
9. **Verify the release** is visible on GitHub Releases. The feed at
   `openwrt-iac.github.io/feed/` picks up the new asset on its next
   `publish.yml` run (nightly schedule or manual
   `gh workflow run publish.yml --repo openwrt-iac/openwrt-iac.github.io`).

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

- [ ] Candidate sweep done for this version number (see above), and its
  outcome noted even if nothing was eligible.
- [ ] `VERSION` matches the target tag.
- [ ] `build/openapi.json`'s `info.version` matches (`make openapi-check`).
- [ ] `CHANGELOG.md` has the entry for this version.
- [ ] Any version number a doc announced ahead of time now matches reality.
  `docs/deprecations.md` carries a target release in its "Deprecated since"
  column before that release exists, and the roadmap names target versions
  too. Both go stale the moment a number moves or a scope slips, which is how
  the commit-confirm plan ended up still naming 2.4.0 after 2.4.0 shipped
  without it. Grep the docs for the version being cut and for the one before
  it.
- [ ] `make test coverage` green.
- [ ] CI green on the branch being tagged, for the exact commit that will be tagged.
  `main` for a release off the current major, `release/<major>.<minor>.x` for a patch on an
  older one. Both are built on push.
- [ ] `.github/release-signers.asc` contains your GPG public key block.
- [ ] `build/sdk.sha256` pins ALL four arch SDKs at the right
  `OPENWRT_VERSION` (x86_64 + aarch64_generic + arm_cortex-a7 + mips_24kc).
- [ ] `gh workflow run ci.yml --ref main` green - validates the per-arch
  SDK pins via `verify-arch-build` without consuming a tag.

After tagging, before announcing:

- [ ] release-apk workflow completed.
- [ ] verify-arch-build matrix completed (all three non-x86 arches green).
- [ ] APK attached to the GitHub Release.
- [ ] **Stable releases only**: trigger `gh workflow run publish.yml --repo
      openwrt-iac/openwrt-iac.github.io` (or wait for the nightly schedule) and confirm
      `apk update` against `openwrt-iac.github.io/feed/...` finds the new version. For an RC,
      confirm the opposite instead, that `apk policy uapi` still offers the previous stable:
      the aggregator filters prereleases at source, so an RC reaching the feed is the bug.
- [ ] Smoke install on a real router works.
- [ ] SBOM attached.

## Rollback

If a tagged release is broken in the field:

1. Identify the breakage; file an issue.
2. Mark the GitHub Release as "Pre-release" or "Draft" via `gh release
   edit <tag> --prerelease` to demote it in the UI. The aggregator's
   `--exclude-pre-releases` filter then pulls the next-highest stable
   on its next run.
3. Ship a `vX.Y.(Z+1)` patch with the fix; the next aggregator run
   picks up the higher version and signs a fresh `packages.adb`.
4. The broken APK doesn't necessarily get re-served (it's only on
   GitHub Releases at that point); operators who already installed
   the broken version aren't auto-downgraded, but `apk upgrade uapi`
   resolves to the patched version once the feed updates.

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
