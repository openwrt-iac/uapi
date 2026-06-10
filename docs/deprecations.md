# uapi deprecations log

Canonical list of wire-surface fields that have been deprecated but are still accepted during a deprecation window. Each entry lives here from the release that deprecated it through the release that removes it.

A field is on this page if and only if it is currently accepted-but-deprecated. Once removed (in a major release), the entry moves to the "Removed in past releases" section below.

Policy: a deprecation in a minor release means both forms (old and new) are accepted; the old form is marked `deprecated: true` in `build/openapi.json` so codegen tools surface a warning; the removal of the old form happens no sooner than the next major.

## Active deprecations

| Field | Replaced by | Deprecated since | Removal target | Migration |
|---|---|---|---|---|
| `network/interfaces.name` (request input) | `network/interfaces.id` | 2.2.0 | v3 | Send `id` instead of `name` at create time. Both fields accept the same charset (uci section-name rules); on `proto=wireguard` both are IFNAMSIZ-tight (15 char cap). If both are supplied they must match or the request returns `422 conflict`. The `id` field is the universal "section name at create" input across every CRUD resource in 2.2.0; `name` was a 2.1.0-era shim that only worked on `network/interfaces`. |

## How to migrate

For each deprecated input field your client sends, switch to the replacement column. uapi accepts both during the window, so the migration can be staged: update writes first, observe nothing breaks, then drop the old field. Reads are unaffected (response shape unchanged during the window).

The OpenAPI spec at `/openapi.json` carries `deprecated: true` on every deprecated request field. Codegen tools that respect that flag (openapi-generator, oapi-codegen, etc.) will emit warnings in the generated client when you regenerate; that's the signal your client has surface area to migrate.

## Removed in past releases

(none yet; uapi has not cut a v3.)
