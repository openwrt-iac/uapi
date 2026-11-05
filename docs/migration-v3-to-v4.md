# Migration v3 to v4

What changes between the v3 and v4 majors of the API, and what a client must do. The deprecation
window for each item ran from the 3.x release that announced it, not from v4; the announcing
releases and migration notes are in `docs/deprecations.md`.

## The mount moves to `/api/v4`

One installation serves exactly one API major. The package upgrade flips the prefix from
`/api/v3` to `/api/v4` and strips every older prefix, and a generated client takes the new base
URL from the v4 spec's `servers` block.

<<<<<<< HEAD
## `mwan3/interfaces.family` reads `ipv4` when unset



## A `wireless/interfaces` section with no `mode` reads `null`


wifi-scripts sets up nothing for a section without a `mode` (mac80211.sh skips an absent mode as
it skips an unknown one), so the read now answers `null` instead of `"ap"` (announced in 3.4.0,
#307). The write side changes the same way: a `null` mode is accepted and removes the option,
leaving a section that sets up nothing. A create or PUT that sends no mode stores none.

`mwan3.sh` and `mwan3track` both default an unset `family` to `ipv4`, so the read now answers
`"ipv4"` instead of `null` for a section that stores none (announced in 3.4.0, #306). `family` is
no longer in the request schema's `required`: a write may omit it, and a `null` removes the option,
after which the read answers `ipv4` again.

## Curated string fields refuse newlines and carriage returns



One check in the type gate now refuses `\n` and `\r` in every curated string on write (announced
in 3.4.0, #276), replacing the per-field `LINE_RE`/`ONE_LINE_RE` audits, which had disagreed about
`\r`. The only opt-out is `system.notes`, marked `x-uapi-multiline`, which holds several lines on
purpose. Free-text fields such as descriptions that no daemon reads as one line are refused too;
that is the announced breaking part. Per-field `pattern`s keep their word, quote and glob rules.

## `network/routes.table` and `network/rules.lookup` accept a table name on write


## Curated string fields refuse newlines and carriage returns




One check in the type gate now refuses `\n` and `\r` in every curated string on write (announced
in 3.4.0, #276), replacing the per-field `LINE_RE`/`ONE_LINE_RE` audits, which had disagreed about
`\r`. The only opt-out is `system.notes`, marked `x-uapi-multiline`, which holds several lines on
purpose. Free-text fields such as descriptions that no daemon reads as one line are refused too;
that is the announced breaking part. Per-field `pattern`s keep their word, quote and glob rules.

## `network/routes.table` and `network/rules.lookup` accept a table name on write




=======
The request type of both fields is now a union of integer and string (announced in 3.4.0, #240).
A name is resolved exactly as netifd resolves it (number, then `default`/`main`/`local`, then
`/etc/iproute2/rt_tables`) and stored as its id; a name that does not resolve answers 422, as does
an id of 0. The read still answers the id, so a plan stays stable when `rt_tables` changes, and a
name stored by hand or by LuCI still reads as its id.

>>>>>>> 2ca0856 (v4: routes.table and rules.lookup accept a table name on write (#240))
## `network/interfaces.ip6prefix` is array-only on write

A space-separated string on write is refused with 422 `invalid_type` (announced since 3.2.0,
removed in v4, #241). Send an array, which is also what the read has returned since 3.2.0. A
one-element array is still stored as a scalar, which netifd, 6rd, map and 464xlat read the same
way, so the stored form does not change.
