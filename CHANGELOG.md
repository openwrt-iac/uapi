# Changelog

All notable changes to this project will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- (Reserved for next-cycle changes.)

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
- **`lib/values.uc` shared helpers.** `normalize_bool`, `as_list`, `is_valid_ipv4`, `is_valid_ipv6`, `is_valid_ip`, `is_valid_cidr` — dedupes 9 modules of inline copies (one of which had drifted).
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

First release candidate. Native HTTP REST API for OpenWrt 25.12+ packaged as a single `.apk`. The on-the-wire API contract (`/api/v1/...`) is what 1.0.0 will ship; the package version stays `rc` until real-world deployments shake out the install path on a variety of router configurations.

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

[Unreleased]: https://github.com/raspbeguy/uapi/compare/v1.0.0-rc2...HEAD
[1.0.0-rc2]: https://github.com/raspbeguy/uapi/compare/v1.0.0-rc1...v1.0.0-rc2
[1.0.0-rc1]: https://github.com/raspbeguy/uapi/releases/tag/v1.0.0-rc1
