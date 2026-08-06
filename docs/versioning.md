# API versioning policy

The URL prefix `/api/v<N>/` tracks the wire-contract major: uapi 2.x serves under `/api/v2/`, a future v3 would mount at `/api/v3/`. Within a given installed major, additions are backwards-compatible.

## Package version mirrors API major

Package version follows semver, with the major version aligned to the API major:

- **MAJOR (`(x+1).0.0`)**: breaking on-the-wire change. A given uapi installation serves exactly one API major; we do NOT mount `/api/v(x+1)/` alongside `/api/v<x>/` in the same binary. Operators who need to keep an old client working keep the previous package version installed (older APKs remain attached to their GitHub Releases at <https://github.com/openwrt-iac/uapi/releases>, and the signed git tag is the canonical contract document).
- **MINOR (`x.(y+1).0`)**: backwards-compatible additions only (see below).
- **PATCH (`x.y.(z+1)`)**: bug fixes only. No surface change.

A client tested against `x.y.z` works against every future `x.y'.z'` with `y' >= y`.

## Non-breaking changes (allowed within a major)

- New endpoints / resources.
- New optional request fields.
- New response fields. Clients must ignore unknown fields.
- New optional query parameters.
- New error codes. Clients branch on HTTP status and treat unknown `code` gracefully.
- New scope names.
- Field rename with both old and new accepted during a deprecation window: the old marked `deprecated: true` in `build/openapi.json`, an entry added to `docs/deprecations.md`, and the actual removal scheduled for the next major. The deprecation log is the canonical place the operator-facing migration lives.

## Breaking changes (require the next major)

- Removing a field that was never deprecated, or removing one ahead of its scheduled `docs/deprecations.md` removal target.
- Removing or renaming any endpoint or error code. Rename of a request field with a deprecation pair is non-breaking; see above.
- Changing a field's JSON type or semantic meaning. (Carve-out: when the declared type could not represent the field's real state, so that **no value of it was ever a correct answer**, correcting the type can ship in a minor with an explicit CHANGELOG entry naming the carve-out and the affected values. The test is strict: if any uci value produced a correct read under the old type, this does not apply and the change waits for the major. 2.5.0's `system.urandom_seed` and `lldpd.lldp_description` are the precedent, both typed boolean while holding a filesystem path and free text respectively: `true` was unreachable as a truthful answer, and every write replaced the operator's value with `"1"`.)
- Making a previously-optional request field required.
- Tightening validation to reject previously-accepted payloads. (Carve-out: when the previously-accepted payload produced broken state no caller can rely on, tightening can ship as a patch with an explicit CHANGELOG entry naming the carve-out. 2.2.1's cross-section uniqueness check is the precedent.)

## One installation, one API major

There is no parallel mount; we don't carry two surface areas in a single binary on resource-constrained hardware. Operators who need to keep a v1 client working keep the v1 package installed (the v1.2.1 APK stays available on the feed; the signed `v1.2.1` git tag is the canonical v1 contract). The migration table for v1 → v2 lives at `docs/migration-v1-to-v2.md`.

## `/raw/` stability

URL structure, verbs, auth/scope behavior, and error envelope are v1-stable. Payload shape follows uci, which is OpenWrt's moving target; if OpenWrt changes the `firewall` package schema, `/raw/firewall/...` payloads change with it. Documented loudly so users don't expect curated-level stability from raw. See `docs/raw.md` for the full stability disclaimer.

## OpenAPI spec versioning

The emitted `openapi.json` carries the same version as the API it describes (`info.version: "2.3.0"` for uapi v2.3.0). The spec is the source of truth for what's in the contract at any given release.

## Field annotations

Property schemas under `components.schemas.*.properties` carry two non-standard annotations beyond the OpenAPI baseline shape:

- **`default`**: the value `fromUci` synthesizes when the underlying uci option is absent. Standard OpenAPI 3.1 / JSON Schema 2020-12 keyword. The framework does NOT apply this default to incoming requests; it is documentation of the server-side fallback so IaC clients can keep the field sticky (Optional+Computed) instead of mistakenly treating it as caller-owned.
- **`x-uapi-clear-on-omit`** (vendor extension, boolean): when present and `true`, the field is caller-owned and an IaC client can safely send explicit JSON null on `PUT`/`PATCH` to clear the underlying uci option. The flag is mutually exclusive with `default:` (a defaulted-and-clearable field produces perpetual non-converging diffs).

Both annotations are enforced by `make lint-defaults`. See `docs/adding-a-resource.md` for the authoring rules.
