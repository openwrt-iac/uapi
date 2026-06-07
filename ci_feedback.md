# Feedback on uapi CI

Written after reading `.github/workflows/ci.yml` and the `Makefile` test/lint
targets, with the context that across four RCs the thing surfacing spec issues
was an external Terraform generator (me) rather than your pipeline. The point of
this note is to make CI the strict client so the next contract bug dies in a
GitHub Actions log instead of in someone's codegen.

## First, what is already good

This is well above the median for a project this size, and several pieces are
genuinely best-practice:

- **Release pipeline.** Signed-tag verification against a committed keyring,
  in-VM smoke of the built APK *before* any publish, RC tags excluded from the
  gh-pages feed but kept on GitHub Releases, SDK pin verified by sha256,
  multi-arch byte-identical build verification, SBOM attached. The three-guard
  release gate (job `needs` + ref `if` + per-step `if`) is defense-in-depth done
  right.
- **Real integration.** A QEMU OpenWrt VM running the actual API, with a soak
  test (RSS/fd leak watch) and a perf bench regression gate, not just a mock.
- **Input testing.** Property-fuzz at 1000 iters/resource as its own CI step,
  plus a coverage inventory.
- `lint-emdash`, `lint-syntax`, `lint-reserved`, `lint-refs`, and the
  `openapi-check` drift gate are all real and all run on every PR.

So this is not a "your CI is weak" note. It is a "your CI validates the
implementation thoroughly but barely validates the contract" note.

## 1. [highest value] There is no strict OpenAPI validation of the emitted spec

This is the gap that made an external consumer your conformance suite. Today the
only things guarding `build/openapi.json` are:

- `openapi-check`: drift only. Proves the committed file equals a fresh
  `gen_openapi.uc` run. It does not check the file is *correct*, only that it is
  *current*.
- `lint-refs`: hand-rolled dangling-`$ref` check.
- `lint-reserved`: hand-rolled Terraform-reserved-name check.

Nothing validates the document against the OpenAPI 3.1 meta-schema. That is
exactly why `nullable: true` (a 3.0 keyword, invalid in a declared 3.1.0 doc)
shipped on 45 fields through three RCs: no tool in your pipeline knew it was
wrong. A spec linter would have failed that on the first commit.

**Recommendation:** add a real OpenAPI linter as a step in the existing `lint`
job (no VM, runs in seconds). Any of:

- **Redocly CLI** (`redocly lint`) or **Spectral** (`spectral lint`): both
  validate 3.1 conformance and ship a large default ruleset (operationId
  uniqueness, every operation has a response, every schema property reachable,
  no unused components, examples validate against their schemas, descriptions
  present). Spectral also supports custom rules, so `lint-reserved` could become
  a Spectral rule and live next to the rest.
- **vacuum** (Go, single binary, very fast, OpenAPI-native) if you want zero
  Node in CI.

Adopting one **subsumes `lint-refs`** (dangling refs is a built-in rule) and
catches the entire class of "spec is internally malformed" issues that none of
your bespoke greps cover. Keep `lint-reserved` either as-is or as a custom rule;
it encodes project-specific Terraform knowledge a generic linter will not have.

The bespoke ucode lints were the right instinct under time pressure, but each
one is a single rule reimplemented by hand. A linter is a few hundred rules
maintained by someone else.

## 2. [high value] Nothing checks that live responses match the declared schemas

`openapi-check` proves the spec is *current*. Property-fuzz proves `validate()`
(input) is *total*. But there is no test that the API's actual response bodies
*conform to the schemas the spec promises*. That is the other half, and it is
the half that bit the provider:

- hyphenated `runtime` keys (`ipv4-address`) that the schema described one way
  and `fromUci` emitted another,
- the string-vs-integer era,
- any field `fromUci` emits that the schema does not declare, or declares with
  the wrong type/nullability.

All of these are *output-shape* bugs. Your VM already serves the real API, so
the fixture is in place; the missing step is validating responses against the
contract.

**Recommendation:** add a response-conformance step to the `integration` job.
Two ways, lightest first:

- **schemathesis** (`schemathesis run --checks all <spec-url> --base-url ...`):
  property-based, reads `build/openapi.json`, generates requests, and asserts
  every response conforms to the declared schema and status set. This is
  literally "be the strict client" as a CI tool. It needs a token and a Python
  step, but it would have caught every spec/response mismatch I hit, and it
  doubles as fuzzing the request side from the contract.
- If you want to avoid Python, a small ucode/`jq`-driven validator that GETs
  each curated collection + singleton in the VM and checks the JSON against the
  corresponding `components.schemas` entry (types, required, no undeclared keys
  on a strict pass). Less thorough than schemathesis but closes the 80% case
  and stays in your existing toolchain.

Pair this with a strict "no undeclared response fields" mode and it becomes the
single check that turns "the provider author found it" into "CI found it."

## 3. [medium] Pin the ucode toolchain; `alpine:edge` floats

The `unit` and `lint` jobs run on `alpine:edge` and `apk add ucode`. That pulls
whatever ucode edge currently ships, which is not the ucode version on the
OpenWrt 25.12 target you actually run on. Two failure modes: a ucode change in
edge breaks CI for reasons unrelated to your code (noise), or edge's ucode
masks/diverges from a behavior the shipped ucode has (false confidence). Pin to
the alpine release whose ucode matches the OpenWrt target, or at minimum pin a
specific `alpine:N.M` tag so the toolchain only moves when you bump it
deliberately. You already pin the SDK by sha256 for the build; the test
toolchain deserves the same discipline.

## 4. [low] Smaller items

- **Bench baseline persistence.** The "perf bench + regression gate" uploads
  `bench/run-*.json` as an artifact, but where does the gate get its baseline?
  If the comparison is within-run only, it catches a catastrophic regression but
  not slow drift across commits. If the baseline is committed/tracked, ignore
  this; if it is not, a committed baseline (or a rolling one keyed off main)
  would catch the 5%-per-release creep that within-run comparison misses.
- **Two smoke scripts can drift.** `integration/run.sh` (from-source, every
  push) and `integration/release_apk_smoke.sh` (from-APK, tag only) are separate
  scripts testing overlapping surface. Worth asserting the APK smoke is a strict
  subset of (or shares a library with) the from-source suite, so a check added
  to one does not silently miss the other.
- **Example validity.** If you keep request/response `examples` in the spec or
  under `examples/`, a linter (item 1) validating them against their schemas
  closes a quiet drift source. Right now nothing checks an example still matches
  the schema it illustrates.
- **`workflow_dispatch` validation depth.** Operators can dispatch
  `verify-arch-build` pre-tag, which is great. Consider also letting a dispatch
  run the schemathesis/conformance pass against a candidate so the contract is
  validated before the tag, not just at release.

## The through-line

Your implementation CI is excellent and your release CI is excellent. The thin
spot is the contract: the spec is checked for *currency* and a couple of
hand-picked rules, but not for *validity* (item 1) or for *the implementation
actually honoring it* (item 2). Those two additions are cheap (one lint step,
one integration step) and they retire the dependency on a downstream generator
author noticing. The goal is that the only reason an external consumer ever
files a spec bug is a genuine design disagreement, never a representation defect
your own pipeline could have caught for free on every push.
