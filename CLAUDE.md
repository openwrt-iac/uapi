# uapi

Native, lightweight, production-grade HTTP REST API for OpenWrt. Translates standard REST verbs into ubus calls so modern edge routers become first-class targets for Infrastructure-as-Code workflows. Primary design validation: serving as the backend for a custom Terraform provider.

This document captures the v1 design contract. It is comprehensive and authoritative; changes here require the same scrutiny as code changes.

---

## Architectural principles (non-negotiable)

1. **Native integration (direct-to-bus).** Communicate with OpenWrt via ubus through the ucode runtime. No intermediate proxy daemons. No direct `/etc/config/` file manipulation; all writes go through uci's API.
2. **Zero-bloat footprint.** Target is resource-constrained embedded hardware. Runtime overhead, memory, and storage stay negligible. Reject dependencies that don't earn their keep.
3. **Atomic transactions.** A single HTTP write request stages → validates → commits → reloads in one transaction. No partial-failure states, no config drift.

Before adopting any library, daemon, persistence layer, or abstraction, check it against these three. Prefer ucode-native solutions; flag anything requiring a long-running auxiliary process, direct `/etc/config/` writes, or splitting a logical state change across multiple HTTP requests.

**Aim.** Every change should move uapi closer to state-of-the-art for an embedded HTTP control plane: correctness, observability, security posture, test discipline, lock-and-state hygiene, drift detection. Roadmap items in this file are not aspirational backlog; they are the gap between today's posture and that target. Prefer hardening that closes a real gap over a feature that adds wire surface for its own sake.

**Design reference: LuCI.** When a design choice is non-obvious (should this field be required? what should happen on a proto switch? how is this option meant to interact with that one?), read LuCI's source for the same surface before deciding. The OpenWrt SDK feeds carry it at `build/sdk/feeds/luci/`; the form/view code under `modules/luci-mod-*/htdocs/luci-static/resources/view/` and the platform abstractions under `modules/luci-base/htdocs/luci-static/resources/` are the two main entry points. LuCI is the long-baked baseline every OpenWrt operator already lives with; matching its behavior is the safe default. *Deliberately* diverging from it is fine when the divergence is a documented improvement; *accidentally* diverging because we didn't check is the failure mode to avoid.

---

## Code and documentation style

- **Priorities, in order:** simplicity, maintainability, modularity, readability.
- **No em-dashes.** Applies to code, comments, docs, commit messages, and design notes.
- **Comments are rare.** Default to writing none. Naming and structure should carry the meaning.
- **When a comment is necessary, explain why, not what.** A reader can see what the code does; what they cannot see is the non-obvious constraint, invariant, or workaround that motivated the choice.

### Avoid AI slop (HIGH IMPORTANCE)

Slop is plausible-looking ceremony that adds no signal. It is the single most common failure mode for AI-generated patches and the most expensive to remove in review. Treat every line you write or accept as carrying a justification cost. Apply ruthlessly:

- **No narration headers.** No "What this file does" preambles, no `// ---- section ----` banner comments, no multi-paragraph docstrings explaining the obvious. The filename and the first function are the header.
- **No what-comments.** Anything a competent reader can read directly off the code (`// Loop over keys`, `// Check if X is null`, `// Cleanup`) is slop. Delete it.
- **One-call-site helpers are suspect.** A helper that wraps a single-line operation in a function is slop unless naming it adds real meaning. Inline.
- **Defensive code for cases that cannot happen** (given the rest of the code, not the universe) is slop. Either prove the case is reachable and handle it, or delete the guard.
- **Tautological assertions** that always pass given how the data was constructed earlier in the test are slop. Delete or replace with a real check.
- **Ceremonial echoes / printfs** in scripts ("starting X", "finished X") are slop unless the script genuinely needs progress narration for a long-running task.
- **Variables named to give a name to a value used once** are slop unless the name carries non-obvious meaning.
- **Phrases like "we intentionally", "this is by design", "for clarity", "in order to"** are usually slop tells. Read those comments again; most should be deleted.

The bar for every comment, helper, variable, and assertion: **a senior engineer reading this asks "why is this here?" and gets a non-obvious answer.** If the answer is obvious, delete.

Load-bearing WHY comments stay: historical bug context, hidden constraints, workarounds for upstream behavior, lock-acquire ordering, the kind of thing that would cost the next reader an hour to rediscover. Be honest about which is which.

### Branch + PR workflow

All code changes land via a PR, never via direct push to `main`. Cut a branch (`release/v<version>` for releases, `feat/<topic>` or `fix/<topic>` otherwise), push the branch, open the PR with `gh pr create --base main`, wait for CI to pass on the branch, then merge only when explicitly told. The PR is the reviewable diff; direct-pushing bypasses that gate even when CI passes locally.

Force-with-lease is permitted on the branch (typical use: amending a release commit after review fixes). Force-pushing `main` remains forbidden. Tag-creation discipline is unchanged: signed annotated tag after merge, only when explicitly told to tag.

Applies to every repo under the `openwrt-iac` org, not just uapi.

---

## Where the details live

CLAUDE.md is the every-turn meta document (principles, style, workflow). Topic-specific normative content lives in `docs/`:

| Topic | File | Read when... |
|-------|------|--------------|
| Process model, lock layout, ETags, idempotency, metrics, audit, state inventory | `docs/architecture.md` | Touching the request lifecycle, locks, or anywhere "where state lives" matters. |
| Transaction recipe, batch, snapshot/restore semantics | `docs/architecture.md` § Transaction recipe / Multi-package transactions | Changing the write path or designing a new resource that does anything beyond a single uci write. |
| Fork-per-request rules (what you can/cannot do at module level) | `docs/concurrency.md` | Considering caches, background work, or "obvious" performance optimizations. |
| Resource catalog (curated endpoints by domain), anonymous-section adoption | `docs/resources.md` | Understanding what's exposed, or how unmanaged uci sections become managed. |
| Adding a new curated resource (module shape, annotations, tests, OpenAPI emission, naming conventions) | `docs/adding-a-resource.md` | Adding a resource or extending one. THE go-to file for curation work. |
| Raw passthrough stability + semantics | `docs/raw.md` | Working on `/raw/` or considering using it. |
| Non-uci resources (apk, leases, password, authorized_keys) | `docs/non-uci-state.md` | Adding or modifying a resource whose source of truth isn't `/etc/config/`. |
| Token CLI, HTTP token mint, scope syntax, raw-access composition, rate limits | `docs/tokens.md` | Anything auth-shaped beyond the policy. |
| Threat model and TLS posture | `docs/security.md` | Security review, threat-model questions. |
| Error envelope, top-level + field-level codes, response headers | `docs/errors.md` | Defining a new error code or auditing error shapes. |
| Observability (log categories, format, metrics, diagnostics, healthz, capacity) | `docs/operations.md` | Operator-facing setup, log forwarding, debugging in the field. |
| Test layers, harness, lint suite, CI shape | `docs/testing.md` | Designing tests, expanding lint coverage. |
| APK packaging (file layout, install hook, conffile, build steps) | `docs/packaging.md` | Touching the package contract, release artifacts. |
| Semver mapping, non-breaking vs breaking changes, OpenAPI spec versioning | `docs/versioning.md` | Cutting a release, naming a deprecation, considering whether a change is patch / minor / major. |
| ucode quirks that have cost CI iterations | `docs/ucode-quirks.md` | Designing a new module; before assuming standard language behavior. |
| Release process (signed tags, multi-arch build, feed publication) | `docs/release-process.md` | Cutting a tag or troubleshooting a release workflow. |
| Lock-state audit (every fd-open / lock-acquire site with release proof) | `docs/lock-state-audit.md` | Adding a new code path that acquires a lock or opens a long-held fd. |
| Migration v1 → v2 (rename map, breaking changes) | `docs/migration-v1-to-v2.md` | Supporting operators upgrading across the v2 boundary. |
| Field-level deprecation log | `docs/deprecations.md` | Renaming or removing a wire-surface field. |

## Roadmap

See [docs/roadmap.md](docs/roadmap.md). Shipped, features (additive minor bumps), hardening (no new wire surface), out of scope. Update that file when an item moves between sections.
