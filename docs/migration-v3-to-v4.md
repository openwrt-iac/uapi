# Migration v3 to v4

What changes between the v3 and v4 majors of the API, and what a client must do. The deprecation
window for each item ran from the 3.x release that announced it, not from v4; the announcing
releases and migration notes are in `docs/deprecations.md`.

## The mount moves to `/api/v4`

One installation serves exactly one API major. The package upgrade flips the prefix from
`/api/v3` to `/api/v4` and strips every older prefix, and a generated client takes the new base
URL from the v4 spec's `servers` block.

## `network/interfaces.ip6prefix` is array-only on write

A space-separated string on write is refused with 422 `invalid_type` (announced since 3.2.0,
removed in v4, #241). Send an array, which is also what the read has returned since 3.2.0. A
one-element array is still stored as a scalar, which netifd, 6rd, map and 464xlat read the same
way, so the stored form does not change.
