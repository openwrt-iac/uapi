# `/api/v3/raw/<package>/<id>`: generic uci passthrough

The curated endpoints (`/firewall/rules`, `/network/interfaces`, etc.) wrap a small set of OpenWrt config types with stable schemas and Terraform-friendly JSON. For everything else, `/raw/` gives you the underlying uci surface with the same atomic-transaction guarantees and the same auth model.

**`/raw/` is not raw ubus.** The endpoint exposes arbitrary uci packages and section types, not arbitrary ubus services. Sending ubus calls directly through uapi remains off-limits. The closest uapi gets to ubus is reading the runtime block (`runtime: {...}`) that curated resources populate from selected ubus calls; that is per-resource, hand-curated, and read-only.

## Stability

**URL structure, verbs, auth/scope behavior, and error envelope are
stable within a package major** (today: v3.x). The composition rule
(`raw:*` permission + the section's domain-tree permission both
required) is part of the contract and will not loosen across minor
bumps.

**Payload shape follows uci.** uci is OpenWrt's moving target: when an
OpenWrt release renames a field, drops a section type, or changes the
default for an option, `/raw/<that-package>/...` payloads change with
it. Track those upstream changes the way you'd track them if you were
editing `/etc/config/...` directly.

If you want a stable, semver-bound contract, use the curated endpoint
for that resource if one exists, or open an issue to add one.

## Shape

`GET /api/v3/raw/<package>` lists every section in the package as an array. Each item has:

```json
{
  "id": "<section name>",
  ".type": "<section type>",
  "managed": true,
  "<option1>": "...",
  "<option2>": ["..."],
  ...
}
```

`managed: true` means the section has a real `.name` (named at creation by uapi or by another tool); `managed: false` means it is anonymous (`cfg012345`-style). uapi does not distinguish between writes to anonymous and named sections via `/raw/`. It is derived from uci's `.anonymous` flag on every read and is never stored, so `/raw/` ignores it on write: sending `managed` in a body neither changes the section nor lands as an option. Before 2.5.0 it did land, as a literal `option managed`, and that stored string then shadowed the derived value on read. If you want adoption (rename an anonymous section to a uapi-style ULID), the curated endpoints for that type provide `POST .../adopt`.

`GET /api/v3/raw/<package>/<id>` returns one section in the same shape.

`POST /api/v3/raw/<package>` creates a section. The request body must include `.type`. If `id` is supplied, it must match `/^[A-Za-z0-9_]+$/` (uci's section-name charset) and must not collide with an existing section; otherwise uapi returns `422 validation_failed` with field `id` and code `invalid_format`, or `409 conflict` respectively. If `id` is omitted, uapi generates a ULID-style id with a type-derived single-char prefix.

```json
{
  ".type": "rule",
  "target": "ACCEPT",
  "src": "lan",
  "dest_port": "8080",
  "proto": "tcp"
}
```

The response is the new section plus:

```json
{
  ...
  "reloaded": true,
  "reload_services": ["firewall"]
}
```

`reloaded: false` plus a `reload_note` string when uapi does not know which service to reload for the package. The configuration is on disk; you must reload the relevant daemon manually.

`PUT` replaces all non-meta options. `PATCH` merges. `DELETE` is `204 No Content`.

## Auth

Every raw request needs **two** scope checks, evaluated independently:

1. **Raw tree**: `raw` or `raw:<package>` must permit the verb.
2. **Domain tree**: the section's `.type` is mapped to its curated domain path (`firewall.rule` -> `firewall:rules`, etc.) and the same verb must be permitted there. For packages not in the curated map, the domain path is just `[<package>]`.

The dual check exists so granting `raw:rw` does not silently bypass a carefully-scoped `firewall:rules:ro`. If the deepest matching scope on either tree denies, the request is denied.

For packages absent from that map (e.g. `openvpn`, `mwan3`, `usteer`), only `*:rw` or a package-level scope like `openvpn:rw` permits the domain side.

## Reload mapping

The reload service list is computed from `/etc/config/ucitrack` plus a small fallback table for known packages:

| Package    | Reload services |
|------------|-----------------|
| network    | network         |
| wireless   | network         |
| firewall   | firewall        |
| dhcp       | dnsmasq         |

If `/etc/config/ucitrack` has an entry for the package, its `option init` (plus `list affects` chain) takes precedence over the fallback table.

## Examples

See `examples/curl/raw.sh` for end-to-end usage.

## When not to use `/raw/`

If a curated endpoint exists for the section type, prefer it. The curated layer:

- Normalizes `"1"`/`"0"`/`"on"`/`"off"` to real JSON booleans.
- Lifts single-value uci list options to JSON arrays consistently.
- Validates per-field (formats, enums, cross-references) before staging.
- Returns a stable schema that survives uci-side renames.
- Generates ULID IDs that survive `/etc/config` rewrites.

`/raw/` skips all of that. It is the escape hatch, not the front door.
