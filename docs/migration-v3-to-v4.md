# Migration v3 to v4

What changes between the v3 and v4 majors of the API, and what a client must do. The deprecation
window for each item ran from the 3.x release that announced it, not from v4; the announcing
releases and migration notes are in `docs/deprecations.md`.

## The mount moves to `/api/v4`

One installation serves exactly one API major. The package upgrade flips the prefix from
`/api/v3` to `/api/v4` and strips every older prefix, and a generated client takes the new base
URL from the v4 spec's `servers` block.

## The special endpoints move under `/uapi/...`

The authenticated special endpoints now live under the domain their scopes already named
(announced in 3.4.1, #319): `/tokens` becomes `/uapi/tokens` (and `/tokens/<id>` becomes
`/uapi/tokens/<id>`), `/metrics` becomes `/uapi/metrics`, `/diagnostics` becomes
`/uapi/diagnostics`, `/batch` becomes `/uapi/batch`, and `/auth/whoami` becomes `/uapi/whoami`. The
scopes are unchanged (`uapi:tokens`, `uapi:metrics`, `uapi:diagnostics`). The unauthenticated trio
stays at the top level: `/healthz`, `/openapi.json`, `/schema/*`. The old top-level paths answer
404. The Prometheus `path` label of the moved endpoints changes with them (e.g.
`path="/uapi/tokens"`).

## `dhcp/leases6` merges into `dhcp/leases`

The `/dhcp/leases6` endpoint is removed (announced in 3.4.1, #320). `GET /dhcp/leases` still
returns the IPv4 leases, and `GET /dhcp/leases?family=v6` returns the IPv6 ones from odhcpd's
statefile. The entry id is the MAC for v4 entries and the IP for v6 ones, so
`GET /dhcp/leases/<ip>?family=v6` looks a v6 entry up. The `dhcp:leases6` scope is gone with the
endpoint.

## `managed` and the adopt flow are removed

Every curated response envelope was `{id, managed, runtime, fields}`; it is now `{id, runtime,
fields}` (announced in 3.4.1, #321). `POST /<resource>/<id>/adopt` is gone (it answers 404), the
`?managed=` query filter is gone, and the `unmanaged_resource` (409) error code left the enum with
them. A section pre-existing in `/etc/config/`, named or anonymous, is addressed by its name like
any other and is writable directly.

## One documented `runtime` envelope on every resource

`runtime` is now always present in a resource response and declared in every response schema:
`id` and `runtime` are in the `required` list of every CRUD and singleton resource, and each schema
documents the block (the four resources that had a hand-written `openapi_runtime` keep it; the rest
get the documented empty-object shape). Read-only collections (item lists like `dhcp/leases`) have
no envelope and are unchanged (announced in 3.4.1, #322).

## `unsupported_media_type` and `unmanaged_resource` leave the error enum

The `ErrorEnvelope.code` enum no longer lists `unsupported_media_type` (415) or
`unmanaged_resource` (409), both dead (announced in 3.4.1, #323 and #321). The first was reserved
and never emitted (uapi never rejects a body on `Content-Type`); the second left with the
`managed` field and the adopt flow. Clients branching on either code must drop that branch.

## A write is refused for any stored error the section holds

Like LuCI, which validates every visible field of a form at save, a write now answers 422 for any
error the resulting section holds, not only the ones the write adds (announced in 3.4.0, #308).
Before v4 a write that left a stored value alone answered 200, so a broken section could still be
disabled; now the fix comes first, or goes through `/raw`. On 3.x, `GET /diagnostics?validate=1`
already lists these stored errors, which makes it the pre-flight check before the upgrade. In v4
the same sweep is `GET /uapi/diagnostics?validate=1`.

## Boolean reads follow the reader of their daemon

The readers whose daemon goes through libvalidate's `:bool:` or `config_get_bool` now read the
ten spellings of that reader (announced in 3.4.0, #310): `system.log_remote`,
`system/timeservers` (`enabled`, `enable_server`, `use_dhcp`), the `usteer/config` booleans
(`syslog`, `ipv6`, `assoc_steering`) and the `dropbear/instances` flags (`password_auth`,
`root_password_auth`, `root_login`, `gateway_ports`). `enabled` now reads `true` and `disabled`
reads `false` there, where v3 answered the default. Two defaults follow the daemon too: an absent
`log_remote` reads `true`, as log.init takes it (`log_remote:bool:1`), and an absent usteer
`syslog` reads `false`, as usteer's `set_config` resets it. A section whose read changes gets a new
ETag once at the upgrade, so a write that sends an `If-Match` from before it answers 412: read the
section again first. fw4's `parse_bool` keeps its eight spellings. Evidence: ubox `6f78fa4`,
pinned in `docs/ucode-quirks.md` (#312).

## A `wireless/interfaces` section with no `mode` reads `null`

wifi-scripts sets up nothing for a section without a `mode` (mac80211.sh skips an absent mode as
it skips an unknown one), so the read now answers `null` instead of `"ap"` (announced in 3.4.0,
#307). The write side changes the same way: a `null` mode is accepted and removes the option,
leaving a section that sets up nothing. A create or PUT that sends no mode stores none.

## `mwan3/interfaces.family` reads `ipv4` when unset

`mwan3.sh` and `mwan3track` both default an unset `family` to `ipv4`, so the read now answers
`"ipv4"` instead of `null` for a section that stores none (announced in 3.4.0, #306). `family` is
no longer in the request schema's `required`: a write may omit it, and a `null` removes the option,
after which the read answers `ipv4` again.

## Curated string fields refuse newlines and carriage returns

One check in the type gate now refuses `\n` and `\r` in every curated string on write (announced
in 3.4.0, #276), so the refusal no longer depends on the per-field `LINE_RE`/`ONE_LINE_RE`
patterns, which had disagreed about `\r`. The only opt-out is `system.notes`, marked
`x-uapi-multiline`, which holds several lines on purpose. Free-text fields such as descriptions
that no daemon reads as one line are refused too; that is the announced breaking part. Per-field
`pattern`s keep their word, quote and glob rules.

## `network/routes.table` and `network/rules.lookup` accept a table name on write

The request type of both fields is now a union of integer and string (announced in 3.4.0, #240).
A name is resolved exactly as netifd resolves it (number, then `default`/`main`/`local`, then
`/etc/iproute2/rt_tables`) and stored as its id. A name that does not resolve answers 422
`invalid_format`, and an id of 0 answers 422 `out_of_range`. The read still answers the id, so a
plan stays stable when `rt_tables` changes, and a name stored by hand or by LuCI still reads as its
id.

## `network/interfaces.ip6prefix` is array-only on write

A space-separated string on write is refused with 422 `invalid_type` (announced since 3.2.0,
removed in v4, #241). Send an array, which is also what the read has returned since 3.2.0. A
one-element array is still stored as a scalar, which netifd, 6rd, map and 464xlat read the same
way, so the stored form does not change.
