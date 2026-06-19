# Changelog

All notable changes to this project will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- (Reserved for next-cycle changes.)

## [2.2.2] - 2026-06-19

OpenAPI spec enrichment to support the terraform-provider-uapi clear-on-omit work. No wire-surface change on any CRUD endpoint; no runtime behavior change; the `/openapi.json` document gains per-property annotations that downstream codegen consumes.

### Added

- `default: <value>` on every `schema_properties` field where uapi's `fromUci` synthesizes an unconditional fallback (`normalize_bool(section.X, true|false)`, `section.X ?? "literal"`). ~88 annotations across ~25 curated resources. Standard OpenAPI 3.1 / JSON Schema 2020-12 keyword; clients (Redoc, openapi-codegen, the terraform-provider-uapi spec ingester) surface it natively. Conditional defaults (e.g. `network.interfaces.peerdns` defaults to true under `proto=dhcp` only) are intentionally NOT annotated because the literal value would mislead under other protos.

- `"x-uapi-clear-on-omit": true` vendor extension on caller-owned, non-defaulted fields that are safe for an IaC client to clear when the operator's config omits them. Conservative scope: `network/interfaces` static-proto fields (`ipaddr`, `ipaddrs`, `netmask`, `gateway`, `dns`) surfaced by the 125-resource Terraform apply field report behind [openwrt-iac/uapi#3](https://github.com/openwrt-iac/uapi/issues/3). Other resources can opt in once concrete leftover-prone shapes surface in the field. Mutually exclusive with `default:`; a field cannot be both defaulted and clearable without producing perpetual non-converging diffs.

### Internal

- Load-bearing WHY comment in `src/lib/handler.uc` near `_check_value` declaring that `default:` in `schema_properties` is OpenAPI documentation only; the framework MUST NOT apply it. `fromUci` owns server-side defaults. A future change that silently fills absent fields from `default:` would defeat PATCH delta semantics and break the provider's clear-on-omit work.

- New `make lint-defaults` (folded into `make lint`): shell-grep check that every `normalize_bool(section.X, V)` and `section.X ?? "literal"` pattern in `src/resources/*.uc` has a corresponding `default: V` in the same file's `schema_properties` block. Catches the drift case where a new defaulted field lands without the annotation.

## [2.2.1] - 2026-06-18

Bug fix surfaced by a 125-resource Terraform apply on real hardware ([openwrt-iac/uapi#4](https://github.com/openwrt-iac/uapi/issues/4)). The 2.2.0 pre-create uniqueness check guarded the section id but missed the value-collision case for resources whose cross-section reference key is a separate option (e.g. fw4 keys forwardings/rules/redirects on `firewall.zone.name`, not the section id). A managed create with `name="lan"` next to the box's default `lan` zone produced two `firewall.zone` sections with the same `name` value, which fw4 could not disambiguate.

### Changed

- Pre-create and pre-modify (`POST` / `PUT` / `PATCH`) now reject payloads whose value in a resource's cross-section reference field collides with another section of the same type in the same package. The check returns `422 conflict` naming the offending section, which surfaces the correct workflow to callers: use `POST .../adopt` (Terraform: `terraform import`) to take over an existing section rather than creating a duplicate.

  Affected resources: `firewall/zones` (`name`), `network/devices` (`name`), `sqm/queues` (`interface`). `dhcp/servers` was already self-checking; its existing per-resource check is unchanged. All other resources are unaffected.

  Tightening previously-accepted payloads is technically a breaking change under strict semver reading, but the previously-accepted behavior produced broken state no caller can rely on (two same-named zones, two sqm queues on one interface, etc.), so it ships as a patch.

### Internal

- New optional `unique_field` declaration on curated resource modules. Framework reads it in `handler.uc.make()` to drive the new uniqueness check. Documented at `docs/adding-a-resource.md`.

## [2.2.0] - 2026-06-12

Three field-feedback items from a real OPNsense-to-OpenWrt migration drove this release. The naming-model items (callers want to keep meaningful section names like `lan` / `wan` instead of getting ULIDs) land here; the apply-with-rollback / commit-confirmed safety net is tracked as an open design question at [openwrt-iac/uapi#3](https://github.com/openwrt-iac/uapi/issues/3) and didn't make this cut.

Validated end-to-end across two RC cycles: rc1 on a 14-resource Terraform config against a PC Engines APU2 (OpenWrt 25.12.4), rc2 with the over-restriction fixes the rc1 testing surfaced.

### Added

- Settable `id` at create on every CRUD resource. `POST /<resource>` now accepts an optional `id` field at top level; when supplied it becomes the uci section name AND the response `id`. When absent the server emits the existing ULID. Validation runs once in the framework: uci section-name charset, 32-char default cap, and in-package uniqueness across all section types (so `POST /firewall/rules` with `id: "lan"` while a zone `lan` already exists returns `422 conflict` cleanly instead of failing on commit). Per-resource modules can tighten further; `network/interfaces` keeps its IFNAMSIZ-tight 15-char cap for `proto=wireguard` since netifd binds the uci section name to the kernel netdev name.
- `create_if_missing` opt-in flag on singleton resource modules. When set, `PATCH /<singleton>` creates the underlying uci section (named `main`) if absent instead of returning 404. Applied to `/unbound/srv` and `/unbound/ext` because their extension UCI packages can be wiped by an operator without uapi getting any warning; other singletons stay opt-out so a missing section keeps surfacing as a real problem.

### Changed

- `POST /<resource>/<existing-id>/adopt` keeps the existing section name when the target section is already named. Previously adopt always renamed the section to a ULID, which broke uci cross-references where other sections referenced this one by name (e.g. `firewall.zones.lan` referenced by `firewall.rules.src_zone = "lan"`). Anonymous (`cfgXXXXXX`) sections still get renamed to a managed id, since they had no stable name to begin with. Named sections become an idempotent acknowledgement: keep the name, return the existing view, no service reload (the previous path called `reload(services)` unconditionally on the success path; N adopts during a Terraform import fired N firewall/network reloads).
- `network/devices` no longer requires `ports` when `type=bridge`. uci and netifd accept portless bridges; the 2.1.0 validation was stricter than the platform, which inverted Terraform's create-bridge-before-members ordering, blocked incremental bridges, and rejected adoption of pre-existing portless bridges. The validate check and the `openapi_conditional` clause are both removed; `toUci` already handled the empty-list case correctly.
- `dhcp/hosts` no longer requires `ip`. dnsmasq accepts entries with just `mac` + `name` for DNS-only reservations (hostname-to-MAC mapping without a static lease), and the resource already has a `dns: bool` field reflecting that workflow. The validate check and the `openapi_required: ["ip"]` entry are removed; the existing `openapi_conditional` that requires either `mac` or `duid` (the actual platform constraint) stays.

### Deprecated

- `network/interfaces.name` (request input) in favour of the universal `network/interfaces.id`. Both are accepted during the deprecation window; if both are supplied they must match. The OpenAPI spec marks `name` as `deprecated: true`. Removal is scheduled for v3. See `docs/deprecations.md`.

### Policy

- Field renames within a major release are now allowed when paired with a deprecation window (both old and new accepted, old marked `deprecated: true` in the OpenAPI spec, removal scheduled for the next major). The deprecation log at `docs/deprecations.md` is the operator-facing source of truth.

### Documentation

- `docs/adding-a-resource.md` grows a "Validation should not be stricter than the platform" section pointing at the bridge and DNS-only-host antipatterns as canonical examples. Catching client mistakes is the point of `validate()`; inventing constraints uci/netifd doesn't have is not.

## [2.1.0] - 2026-06-07

Two themes in one release: new curated singletons for the
`unbound-uci-ext` package, plus the infrastructure move to the
`openwrt-iac` GitHub organisation (originally staged on `main` for a
2.0.3 tag that was rolled into 2.1.0 instead, since no API change
had shipped under 2.0.3).

### Added

- Curated `unbound/srv` + `unbound/ext` singleton resources.
  Wrap the UCI namespaces provided by the new `unbound-uci-ext`
  package (separate repo: `openwrt-iac/unbound-uci-ext`), exposing
  the unbound `server:` clause directives + outside-server clauses
  that the main unbound package deliberately keeps out of UCI.
  Install `unbound-uci-ext` from the openwrt-iac feed first; if the
  daemon is absent, uapi returns `503 init_script_missing` cleanly
  via the standard pre-flight (no partial state).
  - `GET` / `PATCH /api/v2/unbound/srv` carries `interface_bind` (list),
    `interface_outgoing` (list), `ip_transparent` (bool), `srv_line`
    (list, verbatim passthrough). Plus the standard `enabled`
    switch. Pair with `unbound.@unbound[0].interface_auto = false`
    on the existing `unbound/server` singleton for exclusive
    binding (loopback-only recursive resolvers behind dnsmasq is
    the canonical case).
  - `GET` / `PATCH /api/v2/unbound/ext` carries `ext_line` (list, one
    entry per rendered line; build whole `forward-zone:` / `view:` /
    `stub:` / `remote-control:` clauses by listing them in order).
  - New scopes `unbound:srv`, `unbound:ext`. The existing
    `unbound:*` umbrella covers both alongside `unbound:server`.

### Notice: feed and site URLs moved

The signed apk feed and the project site have moved from
`raspbeguy.github.io/uapi/...` to `openwrt-iac.github.io/...`. The
old URLs will stop serving fresh APKs after a 30-day grace period.
To migrate, replace the contents of
`/etc/apk/repositories.d/uapi.list` and
`/etc/apk/keys/uapi-feed.pub.pem` with the new feed:

```sh
curl -fsSL https://openwrt-iac.github.io/feed/uapi-feed.pub.pem \
    | tee /etc/apk/keys/uapi-feed.pub.pem > /dev/null
echo 'https://openwrt-iac.github.io/feed/packages/all/uapi/packages.adb' \
    > /etc/apk/repositories.d/uapi.list
apk update
```

The new feed aggregates stable releases from every repo under the
`openwrt-iac` org (uapi, `unbound-uci-ext`, ...), so one feed line
installs any of them. The signing key was rotated as part of the
move; the new public key is served from the feed root.

### Repository moves

- `raspbeguy/uapi` → `openwrt-iac/uapi` (this repo).
- New: `openwrt-iac/unbound-uci-ext`, the extension package exposing
  unbound `server:` directives that the main unbound package
  deliberately keeps out of UCI.
- New: `openwrt-iac/openwrt-iac.github.io`, the site + feed aggregator
  (signed apk index rebuilt from each source repo's latest stable
  GitHub Release).

GitHub redirects `raspbeguy/uapi/...` URLs to the new owner for
~60 days; bookmarks and git remotes should be updated. Tags and
commit history are preserved.

### Removed

- `.github/workflows/publish-web.yml`: the static site is no
  longer published from this repo; lives in
  `openwrt-iac/openwrt-iac.github.io:web/`.
- `.github/workflows/feed-purge-rc.yml`: the feed aggregator
  filters prereleases at the source via
  `gh release list --exclude-pre-releases`, so a scrub workflow is
  no longer needed here.
- The `Publish to APK feed on gh-pages` step in `ci.yml`:
  release-apk now attaches the APK to the GitHub Release and stops
  there; the aggregator picks it up.
- `web/` and `keys/` directories, migrated to the org-site repo.
- `FEED_SIGNING_KEY` repo secret, moved to the org-site repo.

## [2.0.2] - 2026-06-05

Bug-fix patch addressing two items from a real-world v2.0.0 field
migration (a ~127-resource OPNsense -> OpenWrt cutover driven through
`terraform-provider-uapi`). Strictly additive on the wire surface
(C1's `name` field is opt-in); compatible with every existing v2.0.x
client.

### Added

- **Caller-supplied `name` on `POST /network/interfaces` (every proto).**
  Interface section names are first-class semantic handles in OpenWrt
  (referenced by firewall zones, routes, dhcp servers, sqm queues;
  visible in `uci show network`; shown by LuCI). uapi now lets the
  caller pick the section name:

  ```json
  { "proto": "wireguard", "name": "wg_prod",
    "private_key": "...", "addresses": ["10.0.0.1/24"] }

  { "proto": "static", "name": "guest",
    "ipaddr": "192.168.99.1", "netmask": "255.255.255.0" }
  ```

  Validation: `^[A-Za-z][A-Za-z0-9_]{0,14}$` (uci section-name
  charset, IFNAMSIZ-tight; one rule across every proto). Only valid
  at create time (PUT/PATCH reject with `read_only`; rename via
  DELETE + POST). Must not clash with an existing section in the
  `network` package. The `name` becomes the uapi `id`; GETs return it
  under `id` only (the field is request-only).

  When `name` is absent, the server emits a 14-char `wg_<11-char>`
  fallback for `proto=wireguard` or the standard 28-char ULID
  otherwise.

  Touched: `src/lib/ids.uc` (length param on `new_id`),
  `src/lib/handler.uc` (new `id_for_create(body)` resource hook,
  used by `create()` and `adopt()` to override the standard ULID),
  `src/resources/network.interfaces.uc` (the `name` schema property,
  validation, and the `id_for_create` implementation).

### Fixed

- **WireGuard tunnels can finally come up.**
  In v2.0.0/v2.0.1, posting `proto=wireguard` to `/network/interfaces`
  silently created a config that could never bring the tunnel up:
  uapi named every managed section with a ~28-char ULID, but netifd's
  `wireguard.sh` uses the section name verbatim as the kernel netdev
  name, and Linux IFNAMSIZ caps interface names at 15 chars. The
  write returned 200; `logread` carried the actual failure
  (`Attribute failed policy validation`). Worst kind of bug: 2xx
  response, no client signal, broken on the box.

  Fixed by the `name`/`id_for_create` machinery from the Added entry
  above: wireguard interfaces either get a caller-supplied name or
  the IFNAMSIZ-fitting `wg_<11-char>` fallback. Adoption of
  anonymous `proto=wireguard` sections also uses the short-id format;
  before this fix, adopting an anonymous wireguard section also broke
  the netdev.

- **`423` message identifies the actual lock under contention.**
  Same-package writes serialise on the per-package EX (the design;
  cross-package writes still parallelise via SH on the global). The
  `423 locked` response in v2.0.0/v2.0.1 always said
  *"Another write transaction holds the global lock"*, which sent
  operators debugging in the wrong direction when the actual blocker
  was on the per-package EX. The message now branches:

  - `Another write transaction holds the per-package lock for '<pkg>'`
    - another uci writer holds the same package's EX. This is the
    common case under Terraform parallelism for same-package fleets.
  - `A non-uci writer holds the global write lock` - a `with_lock`
    path (`apk` install/remove, `system/password`,
    `system/authorized_keys`) is in flight.

  Touched: `src/lib/transaction.uc` (`default_acquire_pkg` returns
  `{ contention: "global"|"package" }` so `transaction()` can
  distinguish; `multi_transaction` and `with_lock` emit the same
  shape), `src/lib/errors.uc` (`locked(ctx, retry_after, info?)`
  branches the message; new `locked_from(ctx, retry_after, result)`
  helper that pulls `lock_kind`+`package` out of a transaction result
  so every call site is one line and another miss is unrepeatable),
  `src/lib/handler.uc` + `src/raw.uc` + `src/main.uc` +
  `src/lib/non_uci.uc` (all five locked-translation sites pass the
  info through).

### Documentation

- `CLAUDE.md` Concurrency section now states the actual two-tier
  lock model (SH on global + EX on per-package, vs. EX on global for
  non-uci writes) and the per-package vs. global distinction in the
  423 message. The previous one-line "Writes acquire a global flock"
  predated the v1.1 per-package design and was outdated.
- `CLAUDE.md` resource module contract gains the new optional
  `id_for_create(body)` field plus a paragraph documenting the
  `proto=wireguard` ULID exception (the only case in v2.x where the
  section name is consumed as a kernel object name).
- `docs/concurrency.md` adds two subsections: "423 message identity"
  (what the new wording means) and "Terraform parallelism" (when to
  drop to `-parallelism=1` for same-package fleets).
- `docs/errors.md` 423 row updated to match.

### Operator note

For clients that drive same-package fleets under default Terraform
parallelism (`-parallelism=10`): the provider's existing
retry-with-backoff continues to absorb the 423s. The change here is
purely the wording of those 423s; no behaviour change. For very
large same-package fleets (>100 writes), consider
`-parallelism=1` for that resource type; see
`docs/concurrency.md` for the trade-off.

## [2.0.1] - 2026-06-05

Bug-fix patch. Fixes a correctness issue in optimistic-concurrency
behavior reported against v2.0.0: per-resource ETags were polluted by
sibling-section state in the same uci package, causing legitimate
`If-Match` writes to fail with `412 precondition_failed` when an
unrelated sibling section changed.

### Fixed

- **Per-resource ETags are no longer package-global.**
  In v2.0.0, the `_deps_hash` mechanism walked every section of a
  resource's declared `depends_on` type via `uci_foreach` and folded
  the whole set into the ETag. Adding, mutating, or deleting an
  *unrelated* sibling section shifted every other resource's ETag,
  including resources the sibling did not reference. Real-world
  surface: a multi-resource `tofu destroy` left rules behind because
  deleting a firewall zone shifted the rule's ETag mid-run, and the
  rule's `DELETE` carried the now-stale `If-Match` from plan time.

  The fix makes the ETag a pure hash of the resource's own normalized
  body (the `runtime` block is still excluded, as before). Sibling
  sections in the same uci package no longer influence each other's
  ETags, so `If-Match` fires only when *this* resource has actually
  changed. The behavior previously documented and announced as
  "Dependency-aware ETags" (v2.0.0-rc1 entry, lower in this file) is
  **removed**: the cross-reference invariants those resources care
  about (`rule.src_zone -> zone exists`, `member.interface -> interface
  exists`, etc.) were already enforced at `resource.validate()` time on
  every write, so the ETag mix added no real protection.

  Touched: `src/lib/handler.uc` (deletes `_deps_hash`, `_canon_section`,
  `etag_with_deps`; simplifies `compute_etag`/`set_etag_header`/
  `precondition_check` signatures); 11 resource modules drop their
  `depends_on` declaration (`firewall.rules`, `firewall.redirects`,
  `firewall.forwardings`, `dhcp.servers`, `network.routes`,
  `network.bridge_vlans`, `network.wireguard_peers`, `sqm.queues`,
  `mwan3.members`, `mwan3.policies`, `mwan3.rules`).

  Regression coverage: a new unit test
  (`tests/unit/handler_test.uc::ETag is stable across unrelated sibling
  section churn`) and an inverted integration test
  (`tests/integration/34_batch7_endpoints_test.sh`) lock the new
  per-resource semantics in. The unit test fixture declares
  `depends_on` so it would have failed against v2.0.0 buggy code.

### Operator note: client-held ETags

The fix changes how ETags are computed for the 10 resource families
that previously declared `depends_on` (firewall rules/redirects/
forwardings, dhcp servers, network routes/bridge_vlans/wireguard_peers,
sqm queues, mwan3 members/policies/rules). Clients holding v2.0.0
ETags for these resources will see a one-shot `412 precondition_failed`
on their next `If-Match` write; the response carries the current ETag
in the body and the client picks it up for subsequent writes. ETags
for the other resources are byte-identical across the upgrade (the
old code already short-circuited to a pure body hash when
`depends_on` was absent).

The idempotency cache may serve responses with old ETag headers for
up to 24 hours after upgrade; a chained "POST then `If-Match` next-write"
flow against the affected resources may see one extra 412 within that
window.

### Docs

The CLAUDE.md resource module contract drops the `depends_on` field.
`docs/architecture.md`, `docs/adding-a-resource.md`, `docs/resources.md`,
`docs/errors.md`, `docs/roadmap.md`, `docs/migration-v1-to-v2.md`,
`README.md`, and `web/index.html` are updated to describe per-resource
ETags. The OpenAPI `info.description` and the `ETag` header component
description in `build/openapi.json` are updated in lockstep.

## [2.0.0] - 2026-06-04

First stable v2 release. Promotion of `v2.0.0-rc4` after the dogfooding
and provider-integration windows closed with no further wire-surface
issues. No code or spec changes since rc4; only the `VERSION` bump and
the changelog promotion.

The cumulative v2 changes vs. v1.2.1 are listed across the four RC
entries below. As a contract summary:

- `/api/v2/` mount; 32 curated resource endpoints + `/raw/` passthrough
  + `/batch` + ops endpoints (`/healthz`, `/openapi.json`, `/schema`,
  `/metrics`, `/tokens`, `/auth/whoami`, `/diagnostics`).
- 665 unit tests, property-fuzz at 1000 iterations per resource per CI
  run, integration suite against a real OpenWrt 25.12 VM, soak test
  with RSS/fd-leak watch, perf-regression gate against
  `bench/baseline.json`.
- Per-package locking with deadlock-free batch acquisition; global
  `with_lock` for non-uci writes only.
- Optimistic concurrency via ETag + If-Match (header path through a
  reverse proxy; query-param fallback through uhttpd directly).
- Idempotency-Key support on POSTs; `Idempotent-Replayed` header on
  replays.
- Sensitive-field handling: write-only fields (`key`, `private_key`,
  `preshared_key`, `tls_auth`, `pkcs12`) with `has_<field>: bool`
  presence flag.
- Token mint via CLI or HTTP, scope-subset escalation guard, per-token
  rate limit, per-token request budget metric.
- OpenAPI 3.1.0 spec is the contract. `make openapi-check` gates spec
  drift in CI; `make lint-reserved` blocks Terraform-reserved or
  HCL-keyword schema property names; `make lint-refs` blocks dangling
  `$ref` strings.
- Multi-arch byte-identical APK (`PKGARCH:=all`) verified across
  x86_64 / aarch64 / arm_cortex-a7 / mips_24kc on every release.
- Signed tag (`git verify-tag` in CI), signed APK feed
  (`apk mkndx --sign-key`), reproducible SDK pin
  (`build/sdk.sha256`).
- gh-pages feed carries stable releases only; RCs publish to GitHub
  Releases (marked `--prerelease`) but never to the feed.

The v1.2.1 APK stays available on the feed indefinitely for operators
who need to pin to the v1 wire contract; `apk add 'uapi<2.0.0'` or
`apk add uapi=1.2.1-r1` gets you there. v1-to-v2 migration table at
`docs/migration-v1-to-v2.md`.

## [2.0.0-rc4] - 2026-06-04

Fourth release candidate for v2.0. Absorbs the second-pass review from
the Terraform-provider author against rc3: four wire-surface renames
the strict code generator flagged, plus six spec/doc correctness items
and a CI guard against the next provider-hostile field name. Folds in
operational fixes from the rc3 dogfooding cycle: the APK feed gate
that keeps RCs off the public feed, a Redoc dark-theme pass on the
documentation site, and a second test lint for spec integrity.

### Wire-surface renames (breaking vs. rc3)

These rename the JSON field; the underlying uci option stays the same.
A v1.2.x client never saw any of these fields, so there is no v1-to-v2
migration impact. The renames are bundled into rc4 so the operator
pays the migration cost once at the v2.0.0 boundary, not piecemeal.

- `mwan3/interfaces`: `count` -> `probe_count`. `count` collides with
  Terraform's reserved `count` meta-argument and was breaking the
  provider's schema validation.
- `firewall/zones`, `firewall/defaults`: `output` -> `output_policy`.
  `output` is an HCL block keyword; renders quoted in HCL and trips
  linters.
- `unbound/server`: `resource` -> `resource_limits`. Same HCL-keyword
  smell; also disambiguates from process-resource-limit semantics.
- `network/interfaces` runtime block: `ipv4-address`, `ipv6-address`,
  `ipv6-prefix` now emit snake_case (`ipv4_address`, `ipv6_address`,
  `ipv6_prefix`). ubus returns the hyphenated form; uapi normalizes
  per the project-wide snake_case-where-it-stops policy.

### Added

- **OpenAPI 3.1.0 nullable shape** throughout the spec
  (`type: [..., "null"]`), replacing the OpenAPI-3.0 `nullable: true`
  form. Strict 3.1 validators stop tripping on the legacy form.
- **`required` on nested `match`** for firewall rules and redirects:
  the sub-schema now states `required: ["src_zone"]` directly, in
  addition to the existing `openapi_conditional` form. Spec consumers
  that don't evaluate conditional schemas get the constraint for free.
- **Response headers documented under wire names** on every operation
  that emits them: `X-Request-Id` universally, `ETag` on item GETs and
  writes, `X-Reload-Status`/`X-Reload-Services` on writes,
  `Idempotent-Replayed` on POSTs, `Link`/`X-Next-Cursor` on paginated
  collections, `Retry-After` on 429/423, `WWW-Authenticate` on 401.
- **`adopt` operations gain a real description** explaining the
  ULID-rename + stale-id implications. Operation summaries fix the
  pluralization smell ("Adopt an anonymous firewall **rule**" instead
  of "rules").
- **`TokenCreateResponse` field descriptions**: `bearer` and `name`
  carry one-line explanations.
- **`has_<field>` convention documented** in `info.description` and
  `docs/adding-a-resource.md`. The snake_case-where-it-stops policy
  is now a written paragraph in the same doc.

### Hardening

- **`make lint-reserved`**: walks `build/openapi.json`'s
  `components.schemas` and fails CI on any top-level property whose
  name is a Terraform meta-argument (`count`, `for_each`, `depends_on`,
  `provider`, `lifecycle`, `connection`, `provisioner`) or HCL block
  keyword (`output`, `resource`, `data`, `module`, `variable`,
  `locals`, `terraform`). After rc4 the codebase has zero offenders;
  the guard catches the next provider-hostile name before it ships.
- **`make lint-refs`**: walks every `$ref` under `#/components/` in the
  emitted spec and fails on any dangling target. Caught a cross-
  section header rename that OpenAPI viewers had been rendering as
  an empty box.
- **APK feed gated to stable tags only**
  (`.github/workflows/ci.yml`). The `Publish to APK feed on gh-pages`
  step now skips any tag containing a hyphen (rc, alpha, beta, pre),
  so `apk add uapi` against the public feed only ever resolves to a
  true release. RCs still attach to the GitHub Release (marked
  `--prerelease`); install them deliberately via
  `apk add --allow-untrusted /tmp/uapi-<rc>.apk`.
- **`feed-purge-rc.yml` workflow**: operator-dispatched scrub for
  any pre-release APKs that landed before the gate existed. Defaults
  to dry-run, refuses to leave the feed empty, rebuilds the signed
  index from the remaining stable-only APKs. Used once on 2026-06-04
  to drop the five legacy RC APKs (1.0.0_rc1/rc2, 2.0.0_rc1/rc2/rc3).

### Documentation

- Redoc API reference at <https://raspbeguy.github.io/uapi/api/> now
  matches the project's dark palette throughout (sidebar, schema
  panels, code blocks). Heading typography uses the same sans-serif
  stack as the body to maintain visual rhythm on a docs page where
  every endpoint and section title is a heading.
- `docs/release-process.md` documents the stable-tags-only feed
  policy and the `feed-purge-rc` recovery workflow.
- `docs/installation.md` makes the stable-only feed convention
  explicit; RC install path described as deliberate manual download.
- `docs/migration-v1-to-v2.md` carries the rc3 -> rc4 wire renames
  alongside the original v1 -> v2 table.

### Internal

- `openapi_singular` is now a required field on every CRUD resource
  module (used by the adopt operation summary). The generator fails
  loudly on a missing declaration rather than silently emitting
  ungrammatical summaries.

## [2.0.0-rc3] - 2026-06-03

Third release candidate for v2.0. Folds in four hardening items and three
opportunistic resource curations from `docs/roadmap.md`. All changes are
additive (new error-envelope field, new metric label, new resource
endpoints, new scopes); rc2's wire surface is preserved.

### Added

- **mwan3 curation** (5 resources): `mwan3/interfaces` (per-WAN
  tracking), `mwan3/members`, `mwan3/policies`, `mwan3/rules`, and the
  `mwan3/globals` singleton. Cross-reference validation enforces
  `rule.use_policy -> policy`, `policy.use_members[] -> member`, and
  `member.interface -> interface`. `depends_on` chains those into
  ETag-aware dependency mixing.
- **usteer curation** (1 singleton, `usteer/config`): passive band-
  steering tuning. 33 options including `ssid_list` filter and two log
  list options. (`ssid_list` is a uci list option on the singleton, not
  a separate section type as the original roadmap implied.)
- **openvpn curation** (1 CRUD, `openvpn/instances`): per-tunnel config
  with ~50 options. `key`/`tls_auth`/`pkcs12` are write-only (read
  surfaces `has_<field>: bool`); `merge_for_patch` carries values
  forward so unrelated PATCHes do not wipe credentials. Filesystem path
  fields are validated against `^/[A-Za-z0-9_.+/-]+$` to reject
  shell-metacharacters.
- **Per-token request budget metric**: `uapi_requests_total` now carries
  a `token_id` label (operator-configured cardinality, bounded). Pre-auth
  failures (401 before authorize completes) fold to `token_id="-"`.
- **`/diagnostics` recent_errors ring buffer**: best-effort 20-entry
  sliding window of error envelopes emitted by the parent uhttpd VM.
  Each entry carries `{ts, request_id, code, status, method, path,
  message}`. Surface for post-incident debugging without syslog
  forwarding.

### Hardened

- **Constant-time hash compare in auth**: `values.constant_time_equals`
  closes the bulk timing channel previously disclosed under
  `docs/security.md` "Threat model out of scope". The authorize loop
  also no longer short-circuits on first match, removing the
  position-of-token timing leak.
- **Property-fuzz gate**: new `make test-property` runs at 1000
  iterations per resource (vs 200 in regular `make test`). Wired into
  CI as a distinct step so a fuzz regression has its own pass/fail line.

### Internal

- New scope paths: `mwan3`, `mwan3:globals/interfaces/members/policies/
  rules`, `usteer`, `usteer:config`, `openvpn`, `openvpn:instances`.
- New module `src/lib/error_ring.uc` (single-file JSON ring at
  `/tmp/uapi-error-ring/ring.json`; atomic rename pattern shared with
  ratelimit and idempotency).
- 37 new unit tests + 8 new property-fuzz subjects. 665/665 tests green.

## [2.0.0-rc2] - 2026-06-03

Second release candidate for v2.0. No wire-protocol changes vs rc1; the wire
surface is still locked at the rc1 contract. Fixes one real bug found by the
post-rc1 live-router smoke, twelve internal refactors from a structural code
review, and three new contributor docs.

### Fixed

- **`uapi-token create` no longer produces ghost tokens on hyphenated `--name`.**
  libuci rejects hyphens in section names with "Invalid argument", but
  ucode-mod-uci's `cursor.set` silently returns true on the rejection. The
  CLI would print a cleartext bearer that was never persisted; the operator
  got no signal until auth failed on every request. Both the CLI and the
  HTTP `POST /tokens` path now validate `--name`/`body.name` against
  `^[A-Za-z0-9_]+$` and fail loudly with a message that points the operator
  at the charset. All hyphenated example token names in `README.md`,
  `docs/tokens.md`, `web/`, and the OpenAPI intro now use underscores.

### Refactor (internal, no wire change)

Acted on a structural code review from a follow-up pass. Touches ~600 LOC
across handler, transaction, openapi generator, dispatcher, and resource
modules; spec output is byte-identical to rc1 throughout.

- `handler.uc` - extracted `diff_apply`, `etag_with_deps`, `apply_patch_body`
  from the make/make_singleton factories; `attach_reload_headers` shared by
  `translate_tx` and the DELETE 204 path. Both `patch()` functions are now
  linear: precondition check, apply_patch_body, validate, diff_apply,
  response.
- `transaction.uc` - `_finalize_after_reload(reload_err, restore_fn, body,
  services)` shared between single-package and multi-package paths. Removed
  the latent `result.body ?? result` fallback in favour of explicit null
  propagation.
- `gen_openapi.uc` - `responses(verb, success)` helper collapses 38 hand-
  spelled response blocks. `error_responses(verb)` gates write-only codes
  (409/412/422/423) off GETs and validates the verb at parse time.
  TAG_DESCRIPTIONS / X_TAG_GROUPS / STATIC_PATH_TAGS collapsed into one
  ordered `TAGS` list with derived builders.
- `errors.uc` - exported `STATUS_BY_CODE` / `FIELD_CODES` / `ALL_CODES`;
  gen_openapi now reads the error-code enum from there rather than
  hand-transcribing.
- `scope.uc` - `require_or_deny(...)` and a raw-tree variant
  `require_raw_scope(...)` collapse 20 hand-rolled scope-check sites
  in `main.uc` + `raw.uc`. Tightening the deny message format is now a
  one-helper edit.
- `src/lib/openapi_hints.uc` - new module holding cross-resource conditional
  fragments (`match_requires_src_zone`) imported by firewall.rules and
  firewall.redirects.
- `web/api/index.html` - uses the shared `web/style.css` instead of inline
  topbar CSS.

### Hardened

- **Redoc pinned to v2.5.3 with SRI integrity hash.** Was loading `latest`
  from a third-party CDN. The docs site sits next to the APK signing key
  on gh-pages, so a CDN-side compromise mattered. Browser now refuses any
  byte stream that doesn't match the committed sha384.

### Docs

- **New: `CONTRIBUTING.md`** - dev environment, `make` loop, what kinds of
  changes are welcome, commit/PR style, codebase tour.
- **New: `docs/ucode-quirks.md`** - language and OpenWrt-runtime gotchas
  that have each cost a debug round-trip on this project. First time these
  live in the public tree.
- **New: `docs/concurrency.md`** - fork-per-request rules, lock layout, the
  "would this require state to survive fork().exit()?" mental test.
- README docs list reshaped into operator-facing vs contributor-facing groups.
- `docs/migration-v1-to-v2.md` rename-note for `active_leases_v4_box_total`
  now describes the correct semantics (was previously inverted).

### Removed (slop / inverted-text cleanup)

- Stripped narrator preambles and stale field-name references from
  `transaction.uc`, `gen_openapi.uc`, CHANGELOG (rc1 retag intro removed),
  migration guide; 31 lines deleted, 4 added.

## [2.0.0-rc1] - 2026-06-03

First release candidate for v2.0. The wire surface is locked at this tag.

Major bump. One uapi installation serves exactly one API major; the v1 surface
no longer mounts under the v2 package. Operators who need v1 keep the 1.2.1
package installed. Migration table in `docs/migration-v1-to-v2.md`.

### Breaking

- **snake_case rename across `dropbear/instances`, `snmpd/system`, and
  `vnstat/config`** (16 fields total). Every fromUci/toUci key + every
  `schema_properties` entry now follows the project-wide `snake_case`
  convention. Full mapping in the migration guide.
- **Strict integer types** on every uci field declared `type: "integer"`.
  v1 accepted string-form integers (`"42"`); v2 requires real JSON integers
  (`42`). `fromUci` returns `null` for missing or non-numeric uci values via
  the new `values.as_int` coercion (previously `int("abc")` silently became
  `0`).
- **`schema_properties` completeness sweep.** Every fromUci-surfaced field has
  a typed schema entry. Bodies that previously slipped past the type check
  (silent drops in the toUci layer) now return `422 validation_failed`.
- **URL prefix bumped to `/api/v2/`** (was `/api/v1/`). The install hook
  removes the v1 entry from `uhttpd.main.ucode_prefix` and adds the v2
  one; clients must update their base URL. Versioning policy: one major
  per installed package, never parallel. Operators who need the v1 wire
  contract keep the 1.2.1 APK.

### Added

- **Conditional GET.** `If-None-Match: "<etag>"` (or `?if_none_match=` query
  param) returns `304 Not Modified` when the ETag matches. Same uhttpd
  CGI-allowlist carve-out as `If-Match`.
- **Inbound `X-Request-Id`** (or `?request_id=`) is echoed back; the
  server-generated ULID is used when absent or malformed.
- **`WWW-Authenticate: Bearer realm="uapi", error="<code>"`** on every 401
  (RFC 7235 + RFC 6750 compliance).
- **`/healthz` subsystem checks.** Body now includes `{checks: { ubus, uci,
  lock_dir, time_sync }}`. Returns 503 when any subsystem is degraded.
- **`/schema` / `/schema/<package>` / `/schema/<package>/<resource>`.** Public
  (no auth, like `/openapi.json`). Returns the resource module's
  `schema_properties` for dynamic clients without parsing the full OpenAPI.
- **`/auth/whoami`** returns the current bearer's token metadata
  (`token_id, scopes, source_ip, expires_at, allowed_cidrs, last_used_*`).
- **Token expiry.** `expires_at` field on token sections (`uapi-token create
  --expires-in 30d` extended). After the wall clock passes: `401 invalid_token`
  with `message: "Token expired"`.
- **Token IP scoping.** `allowed_cidrs` list on token sections. A request from
  a source IP outside the listed CIDRs returns `401 invalid_token` with
  `message: "Source IP not permitted for this token"`. Empty list = any IP.
- **Token last-used tracking.** `last_used_at` (epoch) and `last_used_ip`
  updated best-effort on each authed request; throttled to ~1 write/minute
  per token via a tmpfs sentinel.
- **`/tokens` HTTP route.** `GET` lists tokens (no secrets surfaced),
  `GET /<id>` reads one, `POST` mints a new bearer over the wire (returns the
  cleartext once), `DELETE /<id>` revokes. POST honours `expires_in_seconds`
  and `allowed_cidrs`. Scope check: caller must hold `uapi:tokens:rw` (or
  `*:rw`) AND every requested scope must be a strict subset of the caller's
  own - escalation returns `403 scope_escalation_blocked`.
- **Per-token rate limit.** File-backed token-bucket, default 100 req/s burst
  200. Returns `429 too_many_requests` with `Retry-After`. Configurable via a
  `config ratelimit` section in `/etc/config/uapi`.
- **`/metrics`** (Prometheus text). Series: `uapi_requests_total`,
  `uapi_request_duration_seconds_bucket`, `uapi_rate_limit_drops_total`,
  `uapi_lock_contention_total`, `uapi_validate_errors_total`. Path templates
  are normalized (`/firewall/rules/:id` not `/firewall/rules/r_01HX...`) to
  keep cardinality bounded. Scope: `uapi:metrics:ro`.
- **`/diagnostics`** returns version, uptime, loaded resources, current lock
  state. Scope: `uapi:diagnostics:ro`.
- **Idempotency keys.** `Idempotency-Key: <client-supplied>` header (or
  `?idempotency_key=`) on POST: first request caches the response under
  `sha256(token || key)`; subsequent requests with the same key replay the
  cached response (`Idempotent-Replayed: true` marker header). Same key with a
  different body returns `409 idempotency_key_conflict`. Cache TTL 24 h.
- **Cursor pagination.** Collection GETs accept `?cursor=c_<id>&limit=N`.
  Default 100, max 500. Response carries `Link: <...>; rel="next"` (RFC 8288)
  and `X-Next-Cursor: c_<id>` when more items follow. Malformed cursor →
  `400 invalid_cursor`.
- **`POST /batch`.** All-or-nothing across N packages. Body
  `{ operations: [{ path, method, body?, if_match? }, ...] }` (max 50). Pure
  reads acquire no lock; writes acquire per-package EX locks in sorted order
  (deadlock-free) under one combined snapshot/restore. Returns
  `207 Multi-Status` on success, the failing sub-request's status on abort
  with `{ code: "batch_partial_failure", aborted_at_index, reverted: true }`.
  Each sub-request is scope-checked independently.
- **JSON Patch (RFC 6902).** PATCH with
  `Content-Type: application/json-patch+json` switches from merge-patch (the
  default, RFC 7396) to JSON Patch ops:
  `add`/`remove`/`replace`/`move`/`copy`/`test`. `test` enables atomic
  conditional updates without `If-Match`.
- **Dependency-aware ETags.** Resources declare `depends_on: ["package:type"]`;
  the dependent's ETag mixes in the hash of the referenced state. Initial
  declarations: `firewall.rules`, `firewall.redirects`, `firewall.forwardings`
  → `firewall:zone`; `sqm.queues`, `network.routes`, `dhcp.servers`,
  `network.wireguard_peers` → `network:interface`; `network.bridge_vlans`
  → `network:device`. Changing a referenced section now invalidates the
  dependent's ETag.

### New error codes

- `429 too_many_requests` (rate limit)
- `403 scope_escalation_blocked` (token mint guard)
- `400 invalid_cursor` (pagination)
- `409 idempotency_key_conflict` (same key, different body)
- `batch_partial_failure` (carried in 4xx/5xx body when a `/batch` aborts)

### New scopes

`uapi`, `uapi:tokens`, `uapi:metrics`, `uapi:diagnostics`.

### Hardening

- **Non-uci base library** (`src/lib/non_uci.uc`) consolidates the
  `with_lock` + audit + envelope plumbing previously duplicated across
  `packages/*` and `system/access`.
- **Lock-and-state audit** (`docs/lock-state-audit.md`) - every fd-open and
  lock-acquire site walked; release proven on every exit including `die()`.
- **Function-level coverage gate** in CI: ≥80% of lib exports unit-tested,
  100% module-level coverage required.
- **Soak harness in CI** - short read-only sweep with RSS/fd-growth thresholds.
- **Performance benchmark gate** - p99 latency baseline per release; CI fails
  on >25% regression.
- **Signed-tag verification** required on release tags
  (`.github/allowed-signers`).
- **Reproducible SDK pin** - SHA256 checksum verified for the OpenWrt SDK
  download (`build/sdk.sha256`).
- **SPDX 2.3 SBOM** emitted per release. `make sbom` generates
  `build/sbom.spdx.json` with every shipped file's sha256, package
  dependencies, and the built APK's verification hash. CI attaches the
  SBOM to the GitHub Release alongside the APK.
- **Multi-arch build verification** on tag push. The `verify-arch-build`
  matrix job (aarch64_generic, arm_cortex-a7, mips_24kc) cross-compiles
  uapi against each arch's SDK to prove the `PKGARCH:=all` invariant
  holds (uapi is pure ucode + shell, so the byte-identical APK works on
  every arch; this job catches a regression if compiled code ever sneaks
  in).

### Documentation

- `docs/migration-v1-to-v2.md` - field renames, strict-int enforcement,
  new endpoint / error code / scope catalogs, client retry patterns.
- `docs/architecture.md` - fork model, lock layout, transaction recipe,
  schema layer, ETag derivation with dep mixing, rate-limit math, metrics
  emission path, where state lives.
- `docs/security.md` - threat model, scope tree examples, TLS posture,
  token storage, rate-limit guarantees, audit shape, hardened-deployment
  recommendations.
- `docs/release-process.md` - operator-facing release flow, SBOM,
  reproducible builds, arch-neutrality rationale, pre-release checklist,
  rollback.

### OpenAPI completeness and contract hardening

- **OpenAPI spec is now a complete machine-readable contract.** Every
  curated resource carries `required: [...]` derived from `validate()`'s
  unconditional requireds. Resources with proto/type discriminators
  (network/interfaces, network/devices, network/rules, dhcp/hosts,
  system/timeservers, wireless/interfaces) gain `allOf: [{if/then/required}]`
  blocks. The 3 resources that populate a runtime block
  (network/interfaces, wireless/interfaces, dhcp/servers) get typed
  `runtime` sub-shapes instead of an opaque `{type: object}`. Generator
  reads three new optional fields per resource module (`openapi_required`,
  `openapi_conditional`, `openapi_runtime`).
- **System endpoints now in the spec.** `/batch`, `/metrics`,
  `/diagnostics`, `/tokens` (GET / GET-by-id / POST / DELETE),
  `/auth/whoami`, `/schema`, `/schema/{package}`,
  `/schema/{package}/{resource}`, `/openapi.json`. The PATCH operations
  declare both content types (`application/json` for merge-patch,
  `application/json-patch+json` for RFC 6902).
- **Error envelope `code` is an explicit enum** in the spec. Includes
  every code uapi can emit (the full list now lives in the
  `ErrorEnvelope.properties.code.enum` array).
- **Response headers documented as components**: `WWW-Authenticate`,
  `Retry-After`, `ETag`, `X-Request-Id`, `Link` (RFC 8288),
  `X-Next-Cursor`, `Idempotent-Replayed`, `X-Reload-Status`,
  `X-Reload-Services`.
- **`X-Reload-Status` + `X-Reload-Services`** response headers on every
  write. `X-Reload-Status: ok` = init script exited 0 (NOT a runtime-
  convergence promise); `X-Reload-Status: no_reload` = the resource has
  no reload services. Documented loudly: convergence is out-of-band.
- **`dhcp/servers.runtime.active_leases_v4_total` renamed to
  `active_leases_v4_box_total`**. The old name was misleading - it sits
  on a per-server resource but counts box-wide (dnsmasq's lease file
  isn't interface-tagged). Breaking but in-window since v2.0.0 hadn't
  been announced. The v1.2.0 entry has been annotated with a forward
  pointer.
- **`/healthz` `version` field documented as the stable version-skew
  probe.** Clients should read it from there rather than inferring from
  the URL or installed package.
- **`dhcp/leases6.ia_type`** declares its enum (`IA_NA`/`IA_TA`/`IA_PD`)
  instead of being a bare string.
- **`docs/operations.md`** gains a "Success != converged" leading
  section and a "version is a stable contract field" note under
  `/healthz`.
- **Verified per-package lock granularity on a live router**: two
  concurrent writes against different uci packages both succeed in
  parallel (~280 ms each, no 423); same-package writes serialize
  correctly. The "single global write lock" concern in the review
  doesn't reflect current code - it's confusion with the
  `transaction.with_lock` path used by non-uci writes (apk,
  system/access), which DOES hold the global EX (correctly, because
  apk's own DB doesn't tolerate parallel installs).

## [1.2.1] - 2026-06-01

Patch release. Three small bugs found by exercising v1.2.0 against a real OpenWrt 25.12.4 router, plus one polish item (an honest error code when the daemon you're configuring isn't installed).

### Fixed

- **`packages/installed` always returned `[]` on apk-tools 3.x.** `list_installed()` called `apk info --installed`, a flag that exists on apk-tools 2.x but not 3.x (which OpenWrt 25 ships). Plain `apk info` is the right command; it prints one installed package name per line. The new implementation also filters output to the package-name regex so diagnostic lines never end up surfacing as fake packages.
- **`network/interfaces` `ipaddr` surfaced as an array on modern uci.** OpenWrt 25 uses `list ipaddr` for static-proto multi-address interfaces (loopback ships as `list ipaddr '127.0.0.1/8'`); uapi was returning the raw uci value, so a GET on a list-form interface returned `"ipaddr": ["127.0.0.1/8"]` instead of the schema-declared string. `fromUci` now surfaces both forms additively: `ipaddr` is always the first address as a string (preserving the v1.0/v1.1 contract); a new `ipaddrs` array carries the full list. `toUci` prefers `ipaddrs` when present and falls back to `ipaddr`. validate accepts either.
- **Makefile `lint-emdash` scanned `build/sdk/`** (OpenWrt feeds checkouts contain em-dashes in upstream package READMEs / test fixtures we don't author or control). `grep --exclude-dir=sdk` now skips it.

### Added

- **New error code `503 init_script_missing` with a pre-flight check.** Before any uci write, `transaction()` now confirms each `/etc/init.d/<svc>` listed in `reload_services` actually exists; missing → fail-fast with a 503 carrying the missing path in `message`, no uci change. Motivates this: live-router testing of v1.2.0 showed that POST `/sqm/queues` on a box without sqm-scripts produced `500 reload_failed_unrecovered`. The cause: step-5 reload returned exit 127 (script not found); the snapshot-restore worked but the SECOND reload attempt also returned 127 (same missing script), so uapi recorded both errors and surfaced "unrecovered" - misleading: uci IS in a known state, only the daemon reload couldn't run because the daemon isn't installed. The new pre-flight makes the two scenarios distinct on the wire:
  - `503 init_script_missing`: daemon not installed; uci state unchanged.
  - `500 reload_failed_restored`: daemon installed but reload exited non-zero; uci state restored from snapshot.
  - `500 reload_failed_unrecovered`: as before, only for the genuinely unrecoverable case (snapshot import / restore-reload both threw or returned errors).

  Step numbering in the atomic-transaction recipe shifts by one in CLAUDE.md: pre-flight is step 0, flock moves to step 1, etc.

### Tests

- Unit: 422 → 431 (+9 covering `ipaddr`/`ipaddrs` semantics, `init_script_missing` pre-flight against absent paths and unsafe names, empty `reload_services` pass-through).
- Integration: +1 file (`30_init_script_missing_test.sh`) verifying live behavior on a router without sqm-scripts: 503 returned, uci unchanged, healthy resources unaffected.

### Live verification

End-to-end run against a real OpenWrt 25.12.4 router (apk-tools 3.0.5) with the locally-built APK installed:

- 6 test phases, 131 assertions: 131 pass, 0 fail.
- `GET /packages/installed` now lists 188 packages (was 0).
- `GET /network/interfaces/loopback` returns `"ipaddr": "127.0.0.1/8"` (schema-conformant string) and `"ipaddrs": ["127.0.0.1/8"]`.
- `POST /sqm/queues` on the unpatched router returned `500 reload_failed_unrecovered`; on 1.2.1 it returns `503 init_script_missing` with `"init script /etc/init.d/sqm not found (is the daemon installed?)"` and leaves uci untouched.

## [1.2.0] - 2026-06-01

Minor release driven by a real Terraform-provider migration that exercised the v1.1 surface against an actual edge router. Three themes:

1. Closing the last "must drop to /raw/" gaps in the curated surface (proto=dhcp/dhcpv6 client options, NAT-loopback reflection on redirects, DHCPv6-reservation fields on dhcp/hosts, parity audit on unbound/server).
2. Surfacing the runtime state Terraform readers need (ubus-derived runtime blocks on network/interfaces, dhcp/servers, wireless/interfaces; new read-only dhcp/leases6 collection).
3. Closing the substantive deferred feature from v1.0's roadmap: ETags / If-Match optimistic concurrency.

Plus two non-uci additions (`system/password`, `system/authorized_keys`) for credential bootstrap, and a formalised "Non-uci resources" registry in CLAUDE.md so the bar for future non-uci additions stays high.

Purely additive: every endpoint, field, scope, response shape, and error code from 1.0.x and 1.1.x continues to work unchanged.

### Added

- **`network/interfaces` proto-conditional DHCP/DHCPv6 client fields.** Under `proto=dhcp`: `peerdns`, `defaultroute`, `metric`, `hostname`, `clientid`. Under `proto=dhcpv6`: `peerdns`, `reqprefix`, `reqaddress`, `ip6hint`, `ip6ifaceid`, `delegate`. Closes the "WAN with PD and noresolv" use case that previously required either dnsmasq workarounds or /raw/.
- **`firewall/redirects` NAT loopback.** New fields: `reflection` (bool), `reflection_src` (enum `internal`/`external`), `reflection_zone` (list). Native fw4 options; no more split-horizon-DNS workaround.
- **`dhcp/hosts` parity audit.** New fields: `duid` (DHCPv6 client id), `hostid` (IPv6 host-id hint), `mac_aliases` (additional MACs via uci `list mac`, backward-compatible with single-string `mac`), `broadcast` (`--dhcp-broadcast` workaround for older clients), `instance` (cross-refs `dhcp/dnsmasq` section names). validate requires either `mac` OR `duid`.
- **`unbound/server` parity audit.** New fields: `manual_conf`, `extended_stats`, `interface_auto`, `localservice`, `hide_binddata`, `rebind_protection`, `num_threads`, `ttl_min`, `domain`, `domain_type`. Listen-address binding deliberately not added; documented in `docs/non-uci-state.md` (no clean uci option exists upstream; use `/etc/unbound/unbound_srv.conf`).
- **`dhcp/leases6` (NEW read-only collection).** Parses `/tmp/(hosts/odhcpd|odhcpd.leases)` to surface odhcpd IPv6 lease state. Per-IA-address entries with `duid`, `iaid`, `hostname`, `interface`, `ia_type`, `ip`, `prefix_length`, `expires_at`. Forgiving parser fails soft on odhcpd format drift across versions.
- **`network/interfaces` runtime block.** Populated from `ubus call network.interface.<name> status`: `up`, `pending`, `available`, `l3_device`, `uptime`, `ipv4-address[]`, `ipv6-address[]`, `ipv6-prefix[]`, `route[]`. Drift-safe for Terraform (field already declared computed).
- **`dhcp/servers` runtime block.** Surfaces `active_leases_v4_total` (box-wide; dnsmasq doesn't tag leases by interface) and `active_leases_v6_iface` (per-interface; odhcpd does). *(renamed to `active_leases_v4_box_total` in v2.0.0; see the v2.0.0 entry below.)*
- **`wireless/interfaces` runtime block.** Looks up the kernel ifname via `network.wireless status`, then queries `iwinfo info`/`assoclist` via ubus. Surfaces `ifname`, `bssid`, `channel`, `frequency`, `signal`, `noise`, `txpower_actual`, `assoclist_count`. Requires new dep `rpcd-mod-iwinfo`.
- **`system/password` (non-uci, write-only).** `POST {user, password}` → 204. Shells out to `/bin/busybox passwd <user>` with the password piped twice via stdin (LuCI's recipe). Validates user as `^(root|[a-z][a-z0-9_-]*)$` and password as `>= 8` characters with no control bytes. Under `transaction.with_lock`. Audit log line carries the user name, never the password.
- **`system/authorized_keys` (non-uci).** `GET` lists; `POST` adds one; `PUT` replaces wholesale; `DELETE /<id>` removes one. File ops on `/etc/dropbear/authorized_keys` (mode 0600, atomic tmp+rename, symlink-safe). Server-side key validation against the allowed type set (`ssh-rsa`, `ssh-ed25519`, three ECDSA curves, two SK variants). Rejects newline/NUL injection in any key field. Stable id = sha256 prefix of the public-key blob (with a 48-bit dual-djb2 fallback in test environments without ucode-mod-digest).
- **ETags / `If-Match` optimistic concurrency.** Every CRUD `GET`, singleton `GET`, and successful write response carries an `ETag` header (sha256 prefix of the canonical JSON body, excluding the runtime block so live ubus drift doesn't trip spurious 412s). `PUT`, `PATCH`, `DELETE`, and singleton `PATCH` honour `If-Match`: stale value returns `412 precondition_failed` and aborts before any uci write. Multi-value (`"a", "b"`), `W/` weak prefix, and `*` (any-existing) all supported. Absent `If-Match` preserves last-write-wins. **uhttpd carve-out:** uhttpd's CGI env has a hard-coded HTTP_* allowlist that excludes If-Match; pass the ETag via `?if_match=<etag>` query parameter as the portable path (uapi accepts either).
- **New error code:** `412 precondition_failed`.
- **Non-uci resources registry in CLAUDE.md.** Six rows: `packages/installed`, `packages/feeds`, `dhcp/leases`, `dhcp/leases6`, `system/password`, `system/authorized_keys`. Each with source-of-truth, lock semantics, reload, audit shape. Adding a new non-uci resource means adding a row.
- **`docs/non-uci-state.md`.** Operator-facing companion to the registry, plus the out-of-scope state catalog (unbound listen-address binding, inittab, etherwake, px5g, FreeBSD sysctl, RRD/NetFlow history) with recommended out-of-band path for each.
- **Curation completeness rule** (CLAUDE.md): "*does this resource expose the options a typical real configuration of this section actually sets?*" as the test for any future curation gap.
- **`examples/curl/`** grew from 5 files to 15: `network_interfaces.sh`, `firewall_redirects.sh`, `firewall_forwardings.sh`, `wireguard_peers.sh`, `dhcp_servers.sh`, `uhttpd_instances.sh`, `sqm_queues.sh`, `dropbear_instances.sh`, `packages_installed.sh`, plus the existing ones.

### Changed

- **`handler.uc` resource factory** now passes `conn` as the second arg to every `fromUci` callsite (list, get_one, replace, patch, remove, adopt, singleton get/patch). Resources that don't need it ignore the extra arg; resources that want runtime data from ubus use it. Default behaviour unchanged for v1.0 resources.
- **`schema_properties` filled in** on seven v1.1 resources that shipped with empty stubs (`dhcp/odhcpd`, `snmpd/{com2secs,system}`, `uhttpd/certs`, `vnstat/{config,interfaces}`, `prometheus_node_exporter_lua/config`). OpenAPI codegen for downstream tooling now sees field types/ranges.
- **`uhttpd/certs.country`** validator accepts `^[A-Za-z]{2}$` (case-insensitive) and normalizes to uppercase in `toUci`. v1.1 accepted any 2-char string; the early v1.2 work tightened it to `^[A-Z]{2}$`, which was a backward-compat break and is now relaxed.
- **`unbound/server` enums** match upstream OpenWrt unbound: `protocol` now `{default, mixed, ip4_only, ip6_only, ip6_local, ip6_prefer}` (`auto` was rejected by the daemon); `resource` picks up `default`.
- **`tests/integration/14_observability_test.sh`** asserts the TLS-bypass audit-log gap is closed: a WRITE via `/etc/uapi.insecure` emits both the `uapi-insecure-bypass` NOTICE and the standard AUDIT line.
- **`tests/integration/22_network_extras_test.sh`** installs an `EXIT/INT/TERM` trap so the throwaway `br-uapitest` bridge is always cleaned up.

### Documentation

- **CLAUDE.md** updated: concurrency section describes the shipped ETag feature plus the uhttpd carve-out; the `v1.1+ roadmap` entry for ETags marked shipped; the curated endpoint list at the top still points readers at the generated `build/openapi.json` for the current authoritative list.
- **`docs/operations.md`** `/metrics` deferred-feature wording rewritten to reflect that the fork-per-request model is the actual blocker.
- **`docs/non-uci-state.md`** (NEW), see Added.

### Dependencies

- New runtime dep: `rpcd-mod-iwinfo` (for `wireless/interfaces` runtime block).

### Tests

- Unit: 350 (v1.1.1) → 422 (+72).
- Integration: 27 (v1.1.1) → 30 (+24_uhttpd_self_lockout, 25_dropbear_instances, 26_packages, 27_runtime_and_leases6, 28_system_access, 29_etags - already partly in v1.1.x; net +3 new files in v1.2).

### Notes

- Generated `openapi.json` grew to ~267 kB describing the expanded surface; spec carries `info.version: "1.2.0"`.
- Clients pinned to `uapi>=1.0` or `>=1.1` continue to work. Clients depending on any of the new endpoints or fields should pin `uapi>=1.2`.

## [1.1.1] - 2026-05-31

Patch release driven by a structured review of v1.1.0. No on-the-wire breaking changes. Two real bugs fixed, plus a security hardening sweep across the new v1.1 surface and several validation gaps closed.

### Fixed

- **handler.uc dynamic-type PUT/PATCH response leaked the sentinel `.type` instead of the real uci type.** For `network/wireguard_peers` this meant a successful write responded with `interface: "peer"` (substring after `"wireguard_"`) rather than the real parent interface name; a Terraform-style client refreshing from the write response would see drift on the next plan. The persisted uci state was always correct; only the response body was wrong. Static-type resources were unaffected (sentinel == real type). Added a regression test that PUT/PATCHes a wireguard peer and asserts the response `interface` matches the request.
- **`uhttpd/instances` self-lockout protection was documented but unimplemented.** The v1.1.0 code declared a `UAPI_PREFIX` constant and a `uapi_prefix_present` helper, but `validate()` was a no-op; a PATCH or PUT that stripped uapi's own `ucode_prefix` entry from the `main` instance silently locked the operator out of the API until console intervention. `validate(json, conn, id)` now enforces the check when `id == "main"` and rejects the write with `422 conflict` on the `ucode_prefix` field. To support this, `handler.uc` now passes `id` as a third argument to `validate()` (existing resources ignore it).

### Security

- **`packages/installed` and `packages/feeds` regex tightening (apk flag injection guard).** `PKG_NAME_RE` was `^[A-Za-z0-9_+.-]+$` and `FEED_NAME_RE` was `^[A-Za-z0-9_.-]+$`, both of which accepted a leading `-` or `.`. A name like `--allow-untrusted` or `--repository=http://attacker/` was regex-valid and reached `apk add` as a flag rather than a positional argument. Names starting with `.` (`.bashrc`, `..foo`) similarly bypassed the intended scoping. Patterns are now `^[A-Za-z0-9_+][A-Za-z0-9_+.-]*$` and `^[A-Za-z0-9_][A-Za-z0-9_.-]*$`; all `apk` invocations also use `--` to separate flags from positional arguments. Unit + integration tests cover both rejection paths.
- **`packages/*` writes now acquire the global `/var/lock/uapi.lock`.** The v1.1.0 implementation bypassed the transaction recipe's flock step; two concurrent installs raced apk's own DB lock and produced nondeterministic `5xx` instead of a clean `423 locked` with `Retry-After`. Refactored via the new `transaction.with_lock` helper, which acquires the same flock without the uci snapshot/reload machinery (apk doesn't go through uci).
- **`packages/*` error envelope no longer dumps raw apk stderr.** `apk add` / `apk del` failures previously surfaced the full stderr in `message`, which can contain absolute paths, mirror URLs, and on misconfigured feeds embedded credentials. The full output is now logged to syslog under the request_id; the response carries a generic `apk add failed (exit N); see syslog <request_id> for details` and the exit code.
- **`packages/*` info_one version-parse regex was broken.** `[:space:]` POSIX char-class syntax does not work in ucode/PCRE; `version` was silently always null. Now parses real `apk info` output.
- **`network/wireguard_peers` secret-masking now matches `wireless/interfaces`.** Previously the `preshared_key` field was returned as the literal string `"(set)"` on read; the field is now omitted on read and only `has_preshared_key: bool` surfaces. The PATCH path still carries the existing key forward via `merge_for_patch`.

### Changed

- **Resource validation gaps closed across v1.1 endpoints.** `snmpd/com2secs` now requires `source` (was silently accepting nonsense sections). `snmpd/accesses` cross-refs `group` against `snmpd/groups`. `vnstat/interfaces` cross-refs `interface` against `network/interfaces`. `network/rules` requires `goto` when `action=goto` (mirroring the existing `lookup` check). `system/timeservers` requires a non-empty server list when `use_dhcp=false`. `uhttpd/instances` validates `listen_http`/`listen_https` format and integer-field bounds. `firewall/defaults` validates `synflood_burst` / `synflood_rate` as positive ints. `uhttpd/certs` requires `commonname` and bounds `days` to 1-36500. `network/routes` validates `source` as IPv4/CIDR. `dhcp/dnsmasq` caps `cachesize` at 1000000 and requires `port` in 1-65535. `dhcp/servers` bounds `start`/`limit` to 0-254 (dnsmasq pool offset/size within a /24). `dropbear/instances` normalizes `PasswordAuth` / `RootPasswordAuth` / `GatewayPorts` to `"1"`/`"0"` (instead of mixed `"on"`/`"off"` and `"1"`/`"0"`).
- **`dhcp/servers` reload list narrowed to `["dnsmasq"]`.** ucitrack already cascades the `dhcp` package to `odhcpd`; the explicit listing produced a double reload.
- **CI: tag glob simplified to `v*` and concurrency cancels in-progress for non-tag refs.** The previous `v[0-9]+.[0-9]+.[0-9]+*` was GitHub filter-pattern syntax (where `+` is literal, not a regex quantifier) and worked by accident; the real release gate is the job-level `if: startsWith(github.ref, 'refs/tags/v')`. Branch and PR pushes now cancel superseded runs (saves runner minutes) but tag runs are never cancelled mid-publish.
- **`tests/integration/22_network_extras_test.sh`** installs an `EXIT/INT/TERM` trap so the throwaway `br-uapitest` bridge is always cleaned up on mid-test failure.

### Added

- **New integration tests for previously uncovered v1.1 endpoints:** `tests/integration/24_uhttpd_self_lockout_test.sh`, `25_dropbear_instances_test.sh`, `26_packages_test.sh`. The packages test specifically exercises the security hardening above against real `apk`.
- **`transaction.with_lock`** helper for non-uci write paths that need the same global serialization the uci recipe gets.

### Documentation

- **CLAUDE.md refreshed.** The curated endpoint list and the scope tree were stale (both still described v1.0); now point at the authoritative sources (`build/openapi.json`, `src/lib/scope.uc`) and enumerate the v1.1 additions.

## [1.1.0] - 2026-05-30

Comprehensive curation pass. Every additional uci section type a typical edge-router configuration relies on now has a curated CRUD or singleton endpoint, and uapi can manage its own runtime package set (apk install/remove and apk feeds). An orchestrator built on this release can drive `/api/v2/...` exclusively without falling through to `/raw/`. Purely additive: every endpoint, field, scope, and response shape from 1.0.x continues to work unchanged.

### Added

- **`network` extensions.**
  - `network/routes` (`network.route`) static routes; target/gateway/interface/table/metric/mtu/type. Validates target as CIDR/IP and cross-refs interface (skipped for blackhole/unreachable).
  - `network/rules` (`network.rule`) policy routing rules; in/out/src/dest/priority/lookup/goto/action/invert/mark.
  - `network/bridge_vlans` (`network.bridge-vlan`) bridge VLAN tagging; device/vlan/ports, vlan 1-4094, port spec regex, bridge cross-ref.
  - `network/wireguard_peers` dynamic-type resource over `wireguard_<parent_iface>`. Cross-refs the parent interface and requires it to be `proto=wireguard`. Preshared key is masked on read and carried through PATCH via `merge_for_patch`.
  - `network/interfaces` now accepts `proto=wireguard` with fields `private_key`, `listen_port`, `addresses` (CIDR list), `mtu`, `nohostroute`, `ip4table`, `ip6table`. `private_key` is masked on read (surfaced as `has_private_key: true`) and preserved across PATCH.
- **`firewall` extensions.**
  - `firewall/forwardings` (`firewall.forwarding`) zone-to-zone forwarding; cross-refs both zones.
  - `firewall/defaults` singleton input/output/forward verdict, syn_flood, drop_invalid, synflood_burst/rate, tcp_syncookies, flow_offloading.
- **`dhcp` extensions.**
  - `dhcp/servers` (`dhcp.dhcp`) per-interface DHCP server config; reloads dnsmasq + odhcpd.
  - `dhcp/dnsmasq` singleton global dnsmasq config; forwarders, address overrides, rebind protection, cache size, etc.
  - `dhcp/odhcpd` singleton odhcpd config; maindhcp, leasefile, loglevel.
- **`system` extensions.** `system/timeservers` (`system.timeserver`) enabled/enable_server/server list/use_dhcp; reloads sysntpd.
- **`dropbear/instances` (`dropbear.dropbear`).** Port, PasswordAuth, RootPasswordAuth, RootLogin, BannerFile, Interface, GatewayPorts.
- **`uhttpd` resources.**
  - `uhttpd/instances` (`uhttpd.uhttpd`) per-instance config; listen_http/listen_https/home/cert/key/ucode_prefix etc.
  - `uhttpd/certs` (`uhttpd.cert`) px5g cert generation params; days/bits/commonname/organization/location/state/country.
- **`unbound/server` singleton (`unbound.unbound`).** Recursive DNS server tuning; enabled/listen_port/dhcp_link/dnssec_enabled/recursion/resource/protocol/query_minimize/prefetch.
- **`sqm/queues` (`sqm.queue`).** Per-interface SQM shaping; interface/download/upload/qdisc/script/linklayer/overhead with enum validation.
- **`snmpd` resources.**
  - `snmpd/agents`, `snmpd/com2secs`, `snmpd/groups`, `snmpd/accesses`, and the `snmpd/system` singleton; together they cover the standard SNMPv1/v2c/v3 ACL stack.
- **`lldpd/config` singleton (`lldpd.lldpd`).** Protocol toggles (CDP/FDP/SONMP/EDP/LLDP-MED), lldp_class, mgmt IP, interface list.
- **`prometheus_node_exporter_lua/config` singleton.** listen_ipv6/listen_interface/listen_port plus per-collector booleans for cpu, meminfo, netdev, loadavg, filesystem, diskstats, uname, netstat, stat, vmstat, boottime, entropy, time, hwmon, textfile, thermal_zone, edac.
- **`vnstat` resources.** `vnstat/config` singleton (DatabaseDir/Interface5MinHours/MonthRotate) and `vnstat/interfaces` (per-iface enable).
- **`packages/installed` (apk packages).** CRUD-shaped resource over the on-router apk store. GET lists installed packages, POST installs (`apk add`), DELETE removes (`apk del`). Package names validated against `^[A-Za-z0-9_+.-]+$`. No uci involvement; shells out via `fs.popen` like `default_reload`.
- **`packages/feeds` (apk repositories).** Manages files under `/etc/apk/repositories.d/`. POST writes a new `.list` file with the supplied URL and runs `apk update`; DELETE removes the file and re-runs `apk update`. URL validated as `http(s)://`; feed name validated as `^[A-Za-z0-9_.-]+$`.
- **Scope tree.** New scopes: `network:routes`, `network:rules`, `network:bridge_vlans`, `network:wireguard_peers`, `firewall:forwardings`, `firewall:defaults`, `dhcp:servers`, `dhcp:dnsmasq`, `dhcp:odhcpd`, `system:timeservers`, `dropbear`, `dropbear:instances`, `uhttpd`, `uhttpd:instances`, `uhttpd:certs`, `unbound`, `unbound:server`, `sqm`, `sqm:queues`, `snmpd`, `snmpd:agents`, `snmpd:com2secs`, `snmpd:groups`, `snmpd:accesses`, `snmpd:system`, `lldpd`, `lldpd:config`, `prometheus_node_exporter_lua`, `prometheus_node_exporter_lua:config`, `vnstat`, `vnstat:config`, `vnstat:interfaces`, `packages`, `packages:installed`, `packages:feeds`. Wildcard `*:rw` continues to cover all of them.
- **Raw access composition.** `/raw/<package>/<id>` now consults the curated domain tree for every new section type above (including a `wireguard_*` prefix match for WG peers), so tokens carrying a curated scope but not `raw:rw` still see writes blocked or allowed consistently with the curated equivalent.

### Changed

- **`handler.uc` resource factory now supports dynamic uci types.** New optional hooks on the resource module: `type_predicate(t)`, `create_type(body)`, `id_prefix`. Default behavior is unchanged (a static `type` string still works exactly as in 1.0.x). The wireguard peers resource is the first user.

### Notes

- Generated `openapi.json` grew to ~250 kB describing the expanded surface; the spec carries `info.version: "1.1.0"`.
- Clients pinned to `uapi>=1.0` continue to work. Clients depending on any of the new endpoints should pin `uapi>=1.1`.

## [1.0.1] - 2026-05-30

Packaging fixes for the upgrade path. No API surface change; existing clients see no difference.

### Fixed

- **`apk upgrade uapi` now picks up the new code immediately.** uhttpd-mod-ucode compiles `main.uc` at parent startup and caches the VM; a plain reload does not re-read the script. 1.0.0's postinst only ran the uci-defaults wiring (which self-deletes after first install) and never told uhttpd to restart on upgrade, so operators upgrading from 1.0.0 would keep serving the previous compiled code until they manually `/etc/init.d/uhttpd restart`. 1.0.1's postinst restarts uhttpd unconditionally after the uci-defaults dance.
- **Bootstrap message no longer shown on upgrades.** The "Create a token / Verify reachable / OpenAPI spec at" banner only prints on first install (no tokens defined yet). Upgrades and remove/reinstall (where the conffile-preserved token store survives) suppress it.

## [1.0.0] - 2026-05-29

First stable release. Identical surface and behavior to 1.0.0-rc2; the version bump promotes the release candidate after CI and end-to-end testing confirmed the post-rc1 architectural changes (real-exit-code reload via `fs.popen`, TOCTOU fix, mid-tree scope wildcards, observability knobs, full integration coverage for every curated resource) hold up under real ubus/uci/netifd.

See the [1.0.0-rc1] and [1.0.0-rc2] entries below for the cumulative content shipping in v1.

## [1.0.0-rc2] - 2026-05-29

Major release-candidate iteration driven by an exhaustive code review of rc1 and a follow-on round of architectural hardening. The on-the-wire API contract is unchanged from rc1; the response semantics are now actually honest about what they claim.

### Fixed

- **Reload mechanism (the big one).** rc1 issued daemon reloads via `ubus call <service> reload`, which is fire-and-forget for every non-daemon service on OpenWrt (`firewall`, `dhcp`/`dnsmasq`): rpcd accepts the call, defers the init script, and unconditionally completes the request with `UBUS_STATUS_OK` regardless of the actual exit code. Net effect on rc1: uci writes hit disk, the API returned 200, the audit log said "success", and `fw4` never actually picked up the change until the next reboot. rc2 reloads via `fs.popen("/etc/init.d/<svc> reload")` and inspects the exit code directly. Reload failures now correctly trigger `500 reload_failed_restored` / `reload_failed_unrecovered` and the snapshot-restore recipe runs end-to-end.
- **TOCTOU window in handler.uc closed.** Every CRUD method (replace/patch/remove/adopt + raw equivalents) now loads the target section *inside* the flock callback. rc1 loaded outside, checked, then locked: a competing writer could mutate state between check and lock.
- **Raw create with explicit `id` now refuses to silently overwrite an existing section.** rc1's `POST /raw/<pkg>` with `body.id = <existing>` would clobber the section's type and merge options; rc2 returns `409 conflict` (pre-flight) plus a defense-in-depth recheck under the lock. The supplied id must also match `^[A-Za-z0-9_]+$` or the request gets `422 invalid_format`.
- **Top-level exception handler.** Uncaught throws inside `dispatch()` (commit failure, malformed scope, unexpected ubus error) now return a `500 internal_error` envelope with `X-Request-Id` and emit an `ERROR` audit line plus a `uapi-internal <request_id>` syslog trace. rc1 let them escape as a broken-CGI response with no envelope.
- **Healthz 503 envelope.** Now `{status:"degraded",errors:[...]}` (matching CLAUDE.md). rc1 incorrectly returned the standard error envelope.
- **System resource envelope.** `id` and `managed` are now stamped at the top level (every other curated resource already had them). `reload: ["system", "log"]` declared so `system` PATCH actually reloads the affected daemons. `log_remote` and `urandom_seed` normalized to JSON booleans on read.
- **Wifi PATCH key preservation.** rc1's PATCH on an encrypted `wireless.interfaces` section forced the caller to resend the cleartext passphrase. rc2 carries the key through via a `merge_for_patch` hook so `PATCH {"ssid":"new"}` works without exposing or losing the key.
- **bus wrapper handles ucode-mod-ubus null-return semantics.** ucode's `conn.call()` returns null on error and stashes the message in a separate `ubus.error()` accessor (not a thrown exception). rc1's `try/catch` therefore never fired. rc2's `bus.call` wrapper checks `r == null && ubus.error() != null` and surfaces real errors via `die()`.
- **Lock open-failure surfaces 500.** rc1 collapsed `fs.open("/var/lock/uapi.lock") == null` (infrastructure problem) into `423 locked` (transient contention). rc2 distinguishes them: contention is `423` with `Retry-After`, infrastructure failure is `500 internal_error` with the path.
- **Audit gating.** `ERROR`/`WARN` syslog now scoped to 401/403/5xx (matching CLAUDE.md). `/healthz` excluded from all log categories. Non-auth 4xx (404/405/409/422/423) no longer emit log lines.
- **ucitrack `/etc/init.d/<package>` fallback.** Now implemented (rc1 promised it; the code path was missing). Lets `/raw/` writes against packages without a ucitrack entry still trigger the right service.
- **OpenAPI schema accuracy.** `dhcp.leases` schema now lists `{expires_at,mac,ip,hostname,duid}` instead of a `{id,managed}` stub. `wireless.interfaces` surfaces `key` (writeOnly) and `has_key` (readOnly).
- **CIDR validation.** `999.0.0.0/24` is now rejected; rc1 only checked digit shape.
- **firewall.redirects** ports/IPs are now arrays (matching firewall.rules).
- **PATCH `match` deep-merge generalized.** rc1 hardcoded the `match` key in `handler.make().patch()`; rc2 uses a per-resource `merge_for_patch` hook, eliminating a latent footgun for the next nested-object resource.

### Added

- **Mid-tree scope wildcards.** `firewall:*:ro` permits ro on every firewall subresource but not the bare domain. `*:rules:ro` matches the `rules` subresource of every domain. Exact segments beat wildcards at the same depth.
- **Observability knobs.** `/etc/config/uapi`'s `config logging` section enables `option access '1'` (every request emits an `ACCESS` INFO line) and `option debug '1'` (per-ubus-call trace at `LOG_DEBUG`). Both default off.
- **`/etc/uapi.insecure` marker now leaves an audit trail.** Every request that bypasses TLS via the marker emits a `uapi-insecure-bypass <request_id> <method> <path> status=<n> remote=<addr>` syslog NOTICE.
- **Mutual TLS docs.** `docs/installation.md` covers the `tls_client_cert_file` / `tls_require_client_cert` route for service-account-as-cert auth.
- **`lib/values.uc` shared helpers.** `normalize_bool`, `as_list`, `is_valid_ipv4`, `is_valid_ipv6`, `is_valid_ip`, `is_valid_cidr` - dedupes 9 modules of inline copies (one of which had drifted).
- **Sample syslog output.** `docs/operations.md` includes example lines for every audit category plus the insecure-bypass and internal-error formats.
- **README "Why this approach" section** framing how uapi differs from prior REST-for-OpenWrt attempts.

### Security

- **Service-name regex guard in `default_reload`.** `^[A-Za-z0-9_-]+$` enforced before interpolating into the `/etc/init.d/<svc>` command string. Defense-in-depth against a future ucitrack entry that could otherwise carry shell metacharacters.
- **`validate()` runs inside the flock.** rc1 ran cross-reference checks (e.g. `firewall.rules.match.src_zone` exists) before acquiring the lock; rc2 runs them inside the transaction so a concurrent zone delete cannot race a rule creation.

### Tests

- **17 new integration tests** covering: TLS-required from non-loopback, lock contention (`423 locked` with `Retry-After`), reload-failure rollback (fail-once injection via `/tmp/fw-fail-once`), audit-line emission, observability knobs, top-level exception handler, raw-409 conflict, token-lifecycle + revocation propagation, CRUD for every previously-uncovered curated resource (network.devices, wireless.devices, wireless.interfaces), adoption flow for every CRUD-capable resource.
- **mac80211_hwsim** auto-loaded in the QEMU VM so wireless tests run for real instead of skipping.
- **Conffile preservation** verified across a same-version reinstall in `release_apk_smoke.sh`.
- **Audit-log assertion** in `03_firewall_rules_crud_test.sh` (captures `X-Request-Id`, greps `logread`).
- Unit suite grew from 253 to 270 cases.

### Removed

- 11 dead exports across `lib/` (`errors.STATUS_BY_CODE`/`FIELD_CODES`, `ids.ALPHABET`/`ULID_LEN`, `scope.KNOWN_PATHS`, `transaction.LOCK_PATH`, `ucitrack.FALLBACK`, `values.IPV4_RE`/`IPV6_RE`/`CIDR_RE`/`is_valid_ipv6`).
- Dead helpers `auth.stub_enabled` / `auth.stub_token` (no longer needed after the real auth implementation landed in v1.0.0-rc1).
- Dead `bus.uci_add` (every write path uses `uci_create_section`).

### Docs

- `CLAUDE.md` rewritten "Atomic transaction recipe" to describe the `fs.popen` reload path and the rationale (every ubus-mediated reload is fire-and-forget).
- "Deferred / future work" reorganized into a "v1.1+ roadmap" with explicit reasoning for each item still missing in v1; the items rc2 implemented (TOCTOU fix, mid-tree wildcards, ucitrack init.d fallback, reload-rollback integration test, ACCESS/DEBUG knobs) are gone from the list.
- Process items dropped from the roadmap (feed submission, raw→curated promotion, i18n).

## [1.0.0-rc1] - 2026-05-28

First release candidate. Native HTTP REST API for OpenWrt 25.12+ packaged as a single `.apk`. The on-the-wire API contract (`/api/v2/...`) is what 1.0.0 will ship; the package version stays `rc` until real-world deployments shake out the install path on a variety of router configurations.

### Surface

- Bearer-token auth with hierarchical scopes (`*:rw`/`*:ro`, `<domain>:rw/ro`, `<domain>:<sub>:rw/ro`), deepest-match-wins, raw access requires both raw-tree and domain-tree permission.
- 10 curated resources: `firewall/{rules,zones,redirects}`, `network/{interfaces,devices}`, `wireless/{devices,interfaces}`, `dhcp/{hosts,leases}`, `system`.
- Generic `/raw/<package>/<id>` passthrough for any uci section type uapi does not curate.
- `/healthz` (no auth) probes ubus reachability.
- `/openapi.json` serves the OpenAPI 3.1 spec (no auth).
- Token CLI: `uapi-token create/list/show/revoke`. Cleartext tokens printed exactly once at creation, stored salted-sha256.

### Guarantees

- Atomic writes: per-request global flock (`/var/lock/uapi.lock`), uci snapshot, validate, stage, commit, daemon reload, restore on reload failure.
- Concurrent reads are lock-free and always permitted at the scope level.
- Audit log line per successful write (syslog `daemon.notice`, plain text, parseable by `logread`).
- Stable resource IDs (ULID with one-char type prefix) survive `/etc/config` rewrites; anonymous sections from other tools are surfaced read-only with `managed: false` until explicit `POST .../adopt`.
- v1 API is additive-only: see CLAUDE.md "API versioning policy" for what triggers v2.

### Distribution

- Single `.apk` package built against the OpenWrt 25.12.4 SDK.
- Conffile-marked token store at `/etc/config/uapi` preserved across upgrades and removal.
- uci-defaults install hook wires `uhttpd.main.ucode_prefix` and self-deletes; pre-remove hook unwires it.
- Release-tier CI builds the APK and runs a full install/use/remove smoke test in a fresh QEMU VM.

[Unreleased]: https://github.com/raspbeguy/uapi/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/raspbeguy/uapi/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/raspbeguy/uapi/compare/v1.0.0-rc2...v1.0.0
[1.0.0-rc2]: https://github.com/raspbeguy/uapi/compare/v1.0.0-rc1...v1.0.0-rc2
[1.0.0-rc1]: https://github.com/raspbeguy/uapi/releases/tag/v1.0.0-rc1
