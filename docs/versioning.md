# API versioning policy

The URL prefix `/api/v<N>/` tracks the wire-contract major: uapi 4.x serves
under `/api/v4/`, a future v5 would mount at `/api/v5/`. Within a given
installed major, additions are backwards-compatible.

## Package version mirrors API major

Package version follows semver, with the major version aligned to the API major:

- **MAJOR (`(x+1).0.0`)**: breaking on-the-wire change. A given uapi
  installation serves exactly one API major. We do NOT mount `/api/v(x+1)/`
  alongside `/api/v<x>/` in the same binary, because two surfaces cost too much
  on constrained hardware. Operators who need to keep an old client working
  keep the previous package version installed (older APKs remain attached to
  their GitHub Releases at <https://github.com/openwrt-iac/uapi/releases>, and
  the signed git tag is the canonical contract document). Each major has a
  migration document, such as `docs/migration-v3-to-v4.md`.
- **MINOR (`x.(y+1).0`)**: backwards-compatible additions only (see below).
- **PATCH (`x.y.(z+1)`)**: bug fixes only, with no surface change, except a
  tightening that the carve-out under "Breaking changes" allows.

A client tested against `x.y.z` works against every future `x.y'.z'` with `y' >=
y`.

## What a major is for

A major is expensive to *have*, not to fill. Operators pin a package, clients
regenerate,
the migration document gets written, and the feed carries two lines for a while.
That cost
is paid the moment the major exists and barely moves with how much it contains.
So when one
happens, take everything.

**The objective of a major is to raise quality and remove complexity, and it
should break as
much as it needs to in order to do that.** Not only the changes that are
individually
unavoidable: every compatibility shim, mirrored field name, union type kept for
an old
client, over-declared response, and branch that exists solely to keep a previous
contract
working is eligible, and the default answer is to remove it. Simplification is a
sufficient
reason on its own. A compatibility branch nobody can delete is a permanent tax
on every
future change to the code around it, and a major is the only moment the tax can
be repealed.

Two things follow.

**Minors stay strict, and that is the trade.** Being permissive in a major is
what lets a
minor refuse. The carve-outs below are deliberately narrow and their tests are
meant to be
applied literally; when a change does not qualify, the answer is to queue it for
the major
rather than to widen a carve-out. A rule bent once stops being a rule.

**Queued debt has to be written down or it will not be swept.** Anything
deferred with "this
needs a major" belongs in `docs/roadmap.md` under the objectives for the next
major,
with enough detail to act on years later. The failure mode is not shipping a
breaking change; it is arriving at a
major, shipping the three items someone remembered, and paying the whole cost
again for the
rest.

## Non-breaking changes (allowed within a major)

- New endpoints / resources.
- New optional request fields.
- New response fields. Clients must ignore unknown fields.
- New optional query parameters.
- New error codes. Clients branch on HTTP status and treat unknown `code`
  gracefully.
- New scope names.
- New response headers with the prefix `X-Reload-` or `X-Kernel-`, and new
  values of such a header or of `X-Mgmt-Path-Warning`. uapi gives these names
  only to advisory headers, which report what a request did or found after uapi
  completed it. Such a header never changes what the status code means, or
  what a client must send or retry, and it keeps its meaning for the whole
  major. A client can pass each of them on as it is, with no release of its
  own (`docs/errors.md`, "Response headers").
- Field rename with both old and new accepted during a deprecation window: the
  old marked `deprecated: true` in `build/openapi.json`, an entry added to
  `docs/deprecations.md`, and the actual removal scheduled for the next major.
  The deprecation log is the canonical place the operator-facing migration
  lives.

## Breaking changes (require the next major)

- Removing a field that was never deprecated, or removing one ahead of its
  scheduled `docs/deprecations.md` removal target.
- Removing or renaming any endpoint or error code. Rename of a request field
  with a deprecation pair is non-breaking; see above.
- Changing a field's JSON type or semantic meaning.

  **Carve-out.** When the declared type could not represent the field's real
  state, correcting it can ship in a minor with a CHANGELOG entry naming this
  carve-out, the branch it relies on, and the affected values. Two branches
  qualify, and each needs evidence rather than an argument.

  **(a) No value of it was ever a correct answer.** 2.5.0's
  `system.urandom_seed` and `lldpd.lldp_description`, both typed boolean while
  holding a filesystem path and free text respectively: `true` was unreachable
  as a truthful answer, and every write replaced the operator's value with
  `"1"`.

  **(b) The server violated its own declared type for a reachable
  configuration**, so no generated client could rely on the field even though
  individual reads conformed. 2.5.0's `dhcp/hosts.tag`, declared `["string",
  "null"]` while a section storing `list tag` returned an array. That is the
  ordinary uci spelling for more than one tag and what LuCI writes, so the
  schema was wrong for a configuration operators actually have. A scalar `option
  tag 'red'` did read back correctly under the old type, which is exactly why
  branch (a) does not cover it.

  Branch (b) exists because the original wording of this carve-out was narrower
  than its own opening clause: it demanded that no value ever be correct, which
  is a strictly smaller set than "the declared type could not represent the
  field's real state". `tag` fell in the gap and shipped anyway, and
  [#126](https://github.com/openwrt-iac/uapi/issues/126) is what surfaced that
  the rule and the release disagreed.

  **A correction under either branch can land silently, so the CHANGELOG entry
  has to say how loudly it fails.** The type gate rejects a wrong JSON type, but
  only if the client sends one. A client whose configuration language coerces
  booleans to strings never does: HCL, most YAML-to-JSON paths with an unquoted
  `true`, and shell interpolation all turn `true` into `"true"`, which is a
  valid string and is accepted. 2.5.0's `lldp_description` takes it and
  advertises the literal text `true`; `urandom_seed` takes it and stays off,
  because its reader only acts on a value starting with `/`. Boolean-to-string
  is the coercion-prone direction. String-to-array is not, which is why
  `dhcp/hosts.tag` fails loudly for every client. Say which case the field is
  in, and if it is the silent one, say what to grep for instead of an error.

  Neither branch covers widening a type for convenience, nor a field where every
  reachable configuration produced a conforming read. Branch (b) requires naming
  the uci configuration under which the old server broke its own schema. If you
  cannot name one, the change waits for the major.
- Making a previously-optional request field required.
- Tightening validation to reject previously-accepted payloads. (Carve-out: when
  the previously-accepted payload produced broken state no caller can rely on,
  tightening can ship as a patch with an explicit CHANGELOG entry naming the
  carve-out. 2.2.1's cross-section uniqueness check is the precedent.)

  **Security carve-out.** A security fix can refuse, in a minor, a payload that
  an earlier release accepted, when its CHANGELOG entry names this carve-out,
  says which payloads it now refuses, and says why. Unlike the carve-out above,
  it also covers a payload whose state a caller could rely on. 3.2.0's check of
  the IPv6 prefix length in a token's `allowed_cidrs` is the precedent.

## `/raw/` stability

URL structure, verbs, auth/scope behavior, and error envelope are stable within
a package major. Payload shape follows uci, which is OpenWrt's moving target. If
OpenWrt changes the `firewall` package schema, `/raw/firewall/...` payloads
change with it. Documented loudly so users don't expect curated-level stability
from raw. See `docs/raw.md` for the full stability disclaimer.

## OpenAPI spec versioning

The emitted `openapi.json` carries the same version as the API it describes
(`info.version: "2.3.0"` for uapi v2.3.0). The spec is the source of truth for
what's in the contract at any given release.

## Field annotations

Property schemas under `components.schemas.*.properties` carry two non-standard
annotations beyond the OpenAPI baseline shape:

- **`default`**: the value `fromUci` synthesizes when the underlying uci option
  is absent. Standard OpenAPI 3.1 / JSON Schema 2020-12 keyword. The framework
  does NOT apply this default to incoming requests; it is documentation of the
  server-side fallback so IaC clients can keep the field sticky
  (Optional+Computed) instead of mistakenly treating it as caller-owned.
- **`x-uapi-clear-on-omit`** (vendor extension, boolean): when present and
  `true`, the field is caller-owned and clearing it converges. The flag is
  mutually exclusive with `default:` (a defaulted-and-clearable field produces
  perpetual non-converging diffs). Note what the flag does *not* mean: the
  server accepts explicit JSON null for any modeled field and clears the
  underlying uci option, flagged or not, which is what makes a read-modify-write
  work at all when the read answered null. The flag marks where clearing is
  *safe*, not where it is *possible*, and its value is that a defaulted field is
  never marked, so a client that treats flagged fields as clearable cannot enter
  the diff loop above.

Both annotations are enforced by `make lint-defaults`. See
`docs/adding-a-resource.md` for the authoring rules.

Source-only markers, stripped from both halves by `build/gen_openapi.uc`, so
they are not in the OpenAPI document (`lint-openapi-shape` fails the build if
one leaks into the spec). `GET /schema/<package>/<resource>` serves them as the
module declares them:

- **`x-uapi-read-nullable`**: a read can answer null for this property, so both
  halves widen `type` and `enum` with null, because a read-modify-write sends
  the read view back as the next request. `validate()` refuses the null where a
  write needs the value.
- **`x-uapi-write`**: keywords the request half declares instead of the response
  half, for a value a read can return but a write refuses (a stored `mtu` below
  68, a route `table` of 0). The handler checks them against the fields that a
  request names, other than a value that the request sends back as the read
  gives it, and `tests/unit/write_overlay_test.uc` ties each keyword to a
  refusal of a request past it. An `enum` there is the whole request bound,
  since each of its values meets the `pattern` of the property, so the request
  half leaves that pattern out.
- **`x-uapi-read`**: keywords the response half declares instead of the
  request half, for a form that a write takes and a read never gives (a route
  `table` name, which a write stores as its id). The type gate judges a request
  by the module schema, which keeps the form, and
  `tests/unit/write_overlay_test.uc` reads each fixture case against the
  keywords.
- **`x-uapi-multiline`**: the type gate takes a newline and a carriage return in
  this string, such as `system.notes`, and refuses them in every other curated
  string (#276).

`x-uapi-write-string` marked a write form kept while a read answered an array,
as `ip6prefix` from 3.2.0 until v4, which removed it together with the last
write form it marked (#241, #329).

## What the request and response halves guarantee

A generated client can rely on two properties of the split, both enforced by
`lint-openapi-shape`
rather than left to the generator's habits.

**A `<Name>Request` exists exactly when the resource can be written.** Read-only
endpoints get a
response schema and no request schema, so a client may treat a missing request
half as "not
writable, or removed". That inference is what makes a removed resource fail
codegen loudly
instead of generating something that no longer exists.

**For a curated resource, the response half contains every field of the request
half.** The
request half is the response's property map minus the response-only entries
(`runtime`,
`managed`) and anything marked `readOnly`, so the containment is structural
rather than a
coincidence of the current field set. A client may therefore derive writability
by membership:
a field present in the response and absent from the request is server-derived,
which is how
`network/interfaces.ipaddr` reads as computed with no special case.

A request type can be wider than the response type of the same field where a
write takes a form that a read never gives. Since v4, `network/routes.table`
and `network/rules.lookup` take a table name, which a write stores as its id,
and a read answers the id. Until v4, `network/interfaces.ip6prefix` was the
case since 3.2.0, for a write form being phased out: a read was always an
array, and a write still took the space-separated string that the 3.1 spec
declared. v4 removed it. A type in
`<Name>Patch` is also wider where it takes a null that a read does not return,
because a null removes the field. The merge-patch body below says which fields.

A request can also be narrower than the response, since 3.2.0, where a read
returns a value that the request schema does not take. Two kinds of value
qualify:

- a value that the daemon refuses or cannot use, such as a stored `mtu` below
  68, a route `table` of 0, or the `listen_port` -1 that a read gives for a
  stored number outside 0 to 65535,
- a value that LuCI or the daemon takes and uapi does not write, such as a
  `network/interfaces.proto` that uapi does not model, the list that uci holds
  for a `wireless/interfaces` text option, or a `mwan3/interfaces.probe_count`
  above the 10 that a write takes.

The response declares what a read can return, and the request declares what a
write can send, so a read-modify-write of such a value fails against the request
schema. A value of the first kind is an error of the section: a rule of
`validate()` or `validate_new()` refuses it, so it blocks every other write of
the section, a PATCH that leaves the field out included, and the validation
sweep lists it. A value of the second kind is no error: the server refuses a
write that changes the field to it, and takes a write that sends back the value
that the section holds, as a PUT of the read does. A PUT still answers 422 for
a value that needs an option that uapi does not model, because a PUT removes
that option: a `network/interfaces.proto` that uapi does not model, or the
`HELPER` target that LuCI writes on a firewall rule with its `set_helper`. A
client that checks a body against the `*Request` schema before it sends it must
leave such a field out. A module declares the difference with `x-uapi-write`,
which the handler checks against the fields that a request names, and
`tests/unit/write_overlay_test.uc` checks each such keyword.

`network/interfaces.proto` is the exception. The server refuses a request that
names a proto that uapi does not model with 422 `not_in_enum`, also when it
sends the stored proto, because a PUT would delete the options that the handler
of that proto reads. So a PUT of the read of such an interface fails, and only
a PATCH that leaves `proto` out can change it and keep its proto.

The response half of a curated resource declares no `pattern`, since 3.2.0. A
pattern says what a
write may send, and a read returns a value as uci holds it. uci, LuCI or an
older uapi can store
a value that breaks the pattern, such as a `clientid` with dashes, so a pattern
in the response
would be a promise that a GET breaks. The request half keeps every pattern, the
sweep of `/uapi/diagnostics?validate=1` lists a stored value that breaks one,
and each write of its section answers 422 while it holds one.

The merge-patch body of a PATCH requires nothing, since 3.2.0. The server
merges that body into the stored section and type-checks the result, as the
sweep checks a read. It checks the required fields on the result too, so a body
can leave out a field that a create requires.

- The `application/json` body of a PATCH is `<Name>Patch`, on a CRUD resource
  and on a
  singleton. It has the properties of `<Name>Request` with the same types,
  enums, patterns and
  bounds, and it takes null as the list below says. It has no `required` and no
  conditionals.
- A nested object, such as the `match` of `firewall/redirects`, has no
  `required` either. The
  server merges it into the stored object.
- `<Name>Patch` has no defaults. A merge-patch body has none, and a client that
  fills defaults
  would overwrite stored values on every PATCH.
- `<Name>Patch` leaves descriptions and examples to `<Name>Request`, because the
  document ships
  on the router. A deprecated field keeps its description, which says why.
- A singleton has no POST or PUT, so no operation references its
  `<Name>Request`. That schema
  stays in the document for a client that names it, and it does not change.
  Before 3.2.0 it was
  the PATCH body of the singleton, so a regenerated client finds that body under
  `<Name>Patch`.
- The `application/json-patch+json` body is `JsonPatch`.

The merge-patch body of a PATCH takes null on a field where the server removes
the field for a
null, since 3.2.0. RFC 7396 removes a member with null. The server skips a null
in its type
check, the merge sets the field to null, and `toUci` leaves the option out, so
the write removes
it. A read then gives what it gives for an unset option, often the default. On a
nested object
such as `match`, a null removes that member only. An array does not take null
items, because a
merge patch replaces an array whole. These fields keep the type of
`<Name>Request`, because a
null does not remove them:

- `id`. A PATCH ignores it.
- A write-only secret, such as `wireless/interfaces.key`. A null keeps the
  stored secret.
- A field that `<Name>Request` requires, such as `network/interfaces.proto` or
  the `match` of `firewall/redirects`. The merged section needs it, so the
  server refuses its null with 422. Some of these fields take null in
  `<Name>Request`, because a read can return null for them, such as
  `firewall/rules.target`. The merge-patch body takes that null too.
- A field that the module names in `openapi_patch_non_null`, because
  `validate()` refuses its null although `<Name>Request` does not require it.

This changes no `<Name>Request` and no `<Name>Response`.

Before 3.2.0 the merge-patch body was an `allOf` of the Request, which refuses
null on most
fields. So a strict client refused partial bodies and removals that the server
accepts.

The two operation-shaped pairs, `BatchRequest` and `TokenCreateRequest`, are
hand-written rather
than generated from a resource module, and are legitimately request-only in
places: a token
create sends scopes and gets back a token. They are outside the rule, and
outside the lint.

