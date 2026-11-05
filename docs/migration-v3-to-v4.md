# Migration v3 to v4

What changes between the v3 and v4 majors of the API, and what a client must do. The deprecation
window for each item ran from the 3.x release that announced it, not from v4; the announcing
releases and migration notes are in `docs/deprecations.md`.

## The mount moves to `/api/v4`

One installation serves exactly one API major. The package upgrade flips the prefix from
`/api/v3` to `/api/v4` and strips every older prefix, and a generated client takes the new base
URL from the v4 spec's `servers` block.

## `mwan3/interfaces.family` reads `ipv4` when unset

`mwan3.sh` and `mwan3track` both default an unset `family` to `ipv4`, so the read now answers
`"ipv4"` instead of `null` for a section that stores none (announced in 3.4.0, #306). `family` is
no longer in the request schema's `required`: a write may omit it, and a `null` removes the option,
after which the read answers `ipv4` again.

## `unsupported_media_type` and `unmanaged_resource` leave the error enum

The `ErrorEnvelope.code` enum no longer lists `unsupported_media_type` (415) or
`unmanaged_resource` (409), both dead (announced in 3.4.1, #323 and #321). The first was reserved
and never emitted (uapi never rejects a body on `Content-Type`); the second left with the
`managed` field and the adopt flow. Clients branching on either code must drop that branch.

## Boolean reads follow the platform's reader

The remaining readers that used `normalize_bool` now use `platform_bool` (announced in 3.4.0,
#310): `system.log_remote`, `system/timeservers` (`enabled`, `enable_server`, `use_dhcp`) and the
`usteer/config` booleans. The uci blob converter takes only `1`/`true` and `0`/`false`, so the
word spellings `on`/`yes`/`enabled` now read `false` there instead of `true`. Fields whose daemon
really takes the wider set keep it: fw4's `parse_bool` and libvalidate's `:bool:` (dropbear's auth
flags) still accept the ten spellings, and those reads are unchanged. Evidence: libuci `66127cd`
and ubox `6f78fa4`, pinned in `docs/ucode-quirks.md` (#312).

## A `wireless/interfaces` section with no `mode` reads `null`

wifi-scripts sets up nothing for a section without a `mode` (mac80211.sh skips an absent mode as
it skips an unknown one), so the read now answers `null` instead of `"ap"` (announced in 3.4.0,
#307). The write side changes the same way: a `null` mode is accepted and removes the option,
leaving a section that sets up nothing. A create or PUT that sends no mode stores none.

## `managed` and the adopt flow are removed

Every curated response envelope was `{id, managed, runtime, fields}`; it is now `{id, runtime,
fields}` (announced in 3.4.1, #321). `POST /<resource>/<id>/adopt` is gone (it answers 404), the
`?managed=` query filter is gone, and the `unmanaged_resource` (409) error code left the enum with
them.

## Curated string fields refuse newlines and carriage returns

One check in the type gate now refuses `\n` and `\r` in every curated string on write (announced
in 3.4.0, #276), replacing the per-field `LINE_RE`/`ONE_LINE_RE` audits, which had disagreed about
`\r`. The only opt-out is `system.notes`, marked `x-uapi-multiline`, which holds several lines on
purpose. Free-text fields such as descriptions that no daemon reads as one line are refused too;
that is the announced breaking part. Per-field `pattern`s keep their word, quote and glob rules.

## `network/routes.table` and `network/rules.lookup` accept a table name on write

The request type of both fields is now a union of integer and string (announced in 3.4.0, #240).
A name is resolved exactly as netifd resolves it (number, then `default`/`main`/`local`, then
`/etc/iproute2/rt_tables`) and stored as its id; a name that does not resolve answers 422, as does
an id of 0. The read still answers the id, so a plan stays stable when `rt_tables` changes, and a
name stored by hand or by LuCI still reads as its id.
## Curated string fields refuse newlines and carriage returns





One check in the type gate now refuses `\n` and `\r` in every curated string on write (announced
in 3.4.0, #276), replacing the per-field `LINE_RE`/`ONE_LINE_RE` audits, which had disagreed about
`\r`. The only opt-out is `system.notes`, marked `x-uapi-multiline`, which holds several lines on
purpose. Free-text fields such as descriptions that no daemon reads as one line are refused too;
that is the announced breaking part. Per-field `pattern`s keep their word, quote and glob rules.

## `network/routes.table` and `network/rules.lookup` accept a table name on write





## `network/interfaces.ip6prefix` is array-only on write

A space-separated string on write is refused with 422 `invalid_type` (announced since 3.2.0,
removed in v4, #241). Send an array, which is also what the read has returned since 3.2.0. A
one-element array is still stored as a scalar, which netifd, 6rd, map and 464xlat read the same
way, so the stored form does not change.
=======
## One documented `runtime` envelope on every resource

`runtime` is now always present in a resource response and declared in every response schema:
`id` and `runtime` are in the `required` list of all 45 resources, and each schema documents the
block (the four resources that had a hand-written `openapi_runtime` keep it; the rest get the
documented empty-object shape). Read-only collections (item lists like `dhcp/leases`) have no
envelope and are unchanged. (Announced in 3.4.1, #322.)

## `managed` and the adopt flow are removed

Every curated response envelope was `{id, managed, runtime, fields}`; it is now `{id, runtime,
fields}` (announced in 3.4.1, #321). `POST /<resource>/<id>/adopt` is gone (404), the `?managed=`
query filter is gone, and `unmanaged_resource` (409) left the error enum. A section pre-existing
in `/etc/config/`, named or anonymous, is addressed by its name like any other and is writable
directly.

## The special endpoints move under `/uapi/...`

`/tokens` → `/uapi/tokens` (and `/tokens/<id>` → `/uapi/tokens/<id>`), `/metrics` →
`/uapi/metrics`, `/diagnostics` → `/uapi/diagnostics`, `/batch` → `/uapi/batch`,
`/auth/whoami` → `/uapi/whoami` (announced in 3.4.1, #319). Scopes unchanged; the public trio
`/healthz`, `/openapi.json`, `/schema/*` stays at the top level; the old paths answer 404.

## `dhcp/leases6` merges into `dhcp/leases`

`/dhcp/leases6` is removed (announced in 3.4.1, #320). `GET /dhcp/leases?family=v6` returns the
IPv6 leases; the entry id is the MAC for v4 and the IP for v6. The `dhcp:leases6` scope is gone.

## Dead error codes leave the enum

`unsupported_media_type` (415) and `unmanaged_resource` (409) left the `ErrorEnvelope.code` enum
(announced in 3.4.1, #323 and #321). Clients branching on them must drop those branches.

## A write is refused for any stored error the section holds

Like LuCI at save, a write now answers 422 for any error the resulting section holds, not only the
ones the write adds (announced in 3.4.0, #308). `GET /uapi/diagnostics?validate=1` lists them.

## Boolean reads follow the platform's reader

The last `normalize_bool` readers now use `platform_bool` (announced in 3.4.0, #310):
`system.log_remote`, `system/timeservers.*`, `usteer/config` booleans. The word spellings
`on`/`yes`/`enabled` now read `false` there. fw4's `parse_bool` and libvalidate's `:bool:`
(dropbear's auth flags) keep the wider set. Evidence: libuci `66127cd`, ubox `6f78fa4`
(`docs/ucode-quirks.md`, #312).

## A `wireless/interfaces` section with no `mode` reads `null`

wifi-scripts sets up nothing without a `mode`, so the read answers `null` instead of `"ap"`
(announced in 3.4.0, #307); a `null` on write removes the option, and a create/PUT without one
stores none.

## `mwan3/interfaces.family` reads `ipv4` when unset

`mwan3.sh`/`mwan3track` default an unset `family` to `ipv4`, so the read answers `"ipv4"` instead
of `null` (announced in 3.4.0, #306); `family` left the request `required`.

## Curated string fields refuse newlines and carriage returns

One check in the type gate refuses `\n` and `\r` in every curated string on write (announced in
3.4.0, #276); `system.notes` is the only opt-out (`x-uapi-multiline`).

## `network/routes.table` and `network/rules.lookup` accept a table name on write

The request type is now a union of integer and string (announced in 3.4.0, #240); a name resolves
like netifd resolves it and is stored as its id, an unresolvable name answers 422. The read still
answers the id.

## `network/interfaces.ip6prefix` is array-only on write

A string on write answers 422 `invalid_type` (announced since 3.2.0, #241). Send an array.
>>>>>>> 304734a (v4: one documented runtime envelope on every resource (#322))
