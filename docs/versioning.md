# API versioning policy

The URL prefix `/api/v<N>/` tracks the wire-contract major: uapi 3.x serves under `/api/v3/`, a future v4 would mount at `/api/v4/`. Within a given installed major, additions are backwards-compatible.

## Package version mirrors API major

Package version follows semver, with the major version aligned to the API major:

- **MAJOR (`(x+1).0.0`)**: breaking on-the-wire change. A given uapi installation serves exactly one API major; we do NOT mount `/api/v(x+1)/` alongside `/api/v<x>/` in the same binary. Operators who need to keep an old client working keep the previous package version installed (older APKs remain attached to their GitHub Releases at <https://github.com/openwrt-iac/uapi/releases>, and the signed git tag is the canonical contract document).
- **MINOR (`x.(y+1).0`)**: backwards-compatible additions only (see below).
- **PATCH (`x.y.(z+1)`)**: bug fixes only. No surface change.

A client tested against `x.y.z` works against every future `x.y'.z'` with `y' >= y`.

## What a major is for

A major is expensive to *have*, not to fill. Operators pin a package, clients regenerate,
the migration document gets written, and the feed carries two lines for a while. That cost
is paid the moment the major exists and barely moves with how much it contains. So when one
happens, take everything.

**The objective of a major is to raise quality and remove complexity, and it should break as
much as it needs to in order to do that.** Not only the changes that are individually
unavoidable: every compatibility shim, mirrored field name, union type kept for an old
client, over-declared response, and branch that exists solely to keep a previous contract
working is eligible, and the default answer is to remove it. Simplification is a sufficient
reason on its own. A compatibility branch nobody can delete is a permanent tax on every
future change to the code around it, and a major is the only moment the tax can be repealed.

Two things follow.

**Minors stay strict, and that is the trade.** Being permissive in a major is what lets a
minor refuse. The carve-outs above are deliberately narrow and their tests are meant to be
applied literally; when a change does not qualify, the answer is to queue it for the major
rather than to widen a carve-out. A rule bent once stops being a rule.

**Queued debt has to be written down or it will not be swept.** Anything deferred with "this
needs a major" belongs in `docs/roadmap.md` under the objectives for the next major,
with enough detail to act on years later. The failure mode is not shipping a breaking change; it is arriving at a
major, shipping the three items someone remembered, and paying the whole cost again for the
rest.

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
- Changing a field's JSON type or semantic meaning.

  **Carve-out.** When the declared type could not represent the field's real state, correcting it can ship in a minor with a CHANGELOG entry naming this carve-out, the branch it relies on, and the affected values. Two branches qualify, and each needs evidence rather than an argument.

  **(a) No value of it was ever a correct answer.** 2.5.0's `system.urandom_seed` and `lldpd.lldp_description`, both typed boolean while holding a filesystem path and free text respectively: `true` was unreachable as a truthful answer, and every write replaced the operator's value with `"1"`.

  **(b) The server violated its own declared type for a reachable configuration**, so no generated client could rely on the field even though individual reads conformed. 2.5.0's `dhcp/hosts.tag`, declared `["string", "null"]` while a section storing `list tag` returned an array. That is the ordinary uci spelling for more than one tag and what LuCI writes, so the schema was wrong for a configuration operators actually have. A scalar `option tag 'red'` did read back correctly under the old type, which is exactly why branch (a) does not cover it.

  Branch (b) exists because the original wording of this carve-out was narrower than its own opening clause: it demanded that no value ever be correct, which is a strictly smaller set than "the declared type could not represent the field's real state". `tag` fell in the gap and shipped anyway, and [#126](https://github.com/openwrt-iac/uapi/issues/126) is what surfaced that the rule and the release disagreed.

  **A correction under either branch can land silently, so the CHANGELOG entry has to say how loudly it fails.** The type gate rejects a wrong JSON type, but only if the client sends one. A client whose configuration language coerces booleans to strings never does: HCL, most YAML-to-JSON paths with an unquoted `true`, and shell interpolation all turn `true` into `"true"`, which is a valid string and is accepted. 2.5.0's `lldp_description` takes it and advertises the literal text `true`; `urandom_seed` takes it and stays off, because its reader only acts on a value starting with `/`. Boolean-to-string is the coercion-prone direction. String-to-array is not, which is why `dhcp/hosts.tag` fails loudly for every client. Say which case the field is in, and if it is the silent one, say what to grep for instead of an error.

  Neither branch covers widening a type for convenience, nor a field where every reachable configuration produced a conforming read. Branch (b) requires naming the uci configuration under which the old server broke its own schema. If you cannot name one, the change waits for the major.
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

## What the request and response halves guarantee

A generated client can rely on two properties of the split, both enforced by `lint-openapi-shape`
rather than left to the generator's habits.

**A `<Name>Request` exists exactly when the resource can be written.** Read-only endpoints get a
response schema and no request schema, so a client may treat a missing request half as "not
writable, or removed". That inference is what makes a removed resource fail codegen loudly
instead of generating something that no longer exists.

**For a curated resource, the response half contains every field of the request half.** The
request half is the response's property map minus the response-only entries (`runtime`,
`managed`) and anything marked `readOnly`, so the containment is structural rather than a
coincidence of the current field set. A client may therefore derive writability by membership:
a field present in the response and absent from the request is server-derived, which is how
`network/interfaces.ipaddr` reads as computed with no special case.

The two operation-shaped pairs, `BatchRequest` and `TokenCreateRequest`, are hand-written rather
than generated from a resource module, and are legitimately request-only in places: a token
create sends scopes and gets back a token. They are outside the rule, and outside the lint.

