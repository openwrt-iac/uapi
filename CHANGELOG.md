# Changelog

All notable changes to this project will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- (Reserved for next-cycle changes.)

## [1.0.0] - TBD

Initial release. Native HTTP REST API for OpenWrt 25.12+ packaged as a single `.apk`.

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

[Unreleased]: https://github.com/raspbeguy/uapi/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/raspbeguy/uapi/releases/tag/v1.0.0
