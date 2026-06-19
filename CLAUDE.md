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

## HTTP host

- **Runtime:** `uhttpd` + `uhttpd-mod-ucode`. No daemon of our own; our handler runs inside the existing uhttpd process.
- **Instance:** Share the default `main` uhttpd instance with LuCI. Both serve configuration use cases; sharing keeps the footprint minimal and inherits the user's TLS config.
- **Wiring:** A single ucode prefix registration: `list ucode_prefix '/api/v2=/usr/share/uapi/main.uc'`. Installed via `/etc/uci-defaults/99-uapi`.
- **Handler shape:** Template-mode ucode script (entered with `{%`). The script's top level runs once in the uhttpd parent at startup and must define `global.handle_request(env)`. Each request is a forked child that inherits the parent VM via copy-on-write and invokes `handle_request`. `main.uc` performs internal method/path dispatch to per-resource modules.

## Concurrency

- **Fork-per-request CGI model.** `uhttpd-mod-ucode` is not a persistent in-process handler. The parent uhttpd compiles the script and runs its top level once at startup, populating the parent VM scope. Every HTTP request is served by a forked child that inherits the parent VM via copy-on-write, invokes `handle_request(env)`, and exits. Module-level state initialized at startup is visible to every request, but mutations are private to the fork and lost on exit.
- **Empirically validated.** `tests/integration/01_concurrency_model_test.sh` fires 5 concurrent requests against a 1s-sleep probe and observes 5 distinct PIDs, every response showing `count == 1`, with wall time approximately 1 to 2s. Source confirmation at `openwrt/uhttpd/ucode.c`: `ucode_handle_request` calls `ops->create_process(cl, pi, url, ucode_main)`; `ucode_main` ends with `exit(0)`. Keep this test green as a regression sentinel.
- **Two-tier flock model.** uci writes take `flock(LOCK_SH | LOCK_NB)` on `/var/lock/uapi.lock` AND `flock(LOCK_EX | LOCK_NB)` on `/var/lock/uapi.pkg.<package>.lock`. Cross-package writes (`firewall` + `dhcp`) hold compatible SH on the global and each their own EX on their package, so they run in parallel. Same-package writes share the SH on the global but contend on the per-package EX, so they serialise. Non-uci writes (apk install/remove, system/password, system/authorized_keys) take EX on the global, which blocks all in-flight uci writes until done. On `EWOULDBLOCK`, return `423 locked` with `Retry-After: 1` and a message naming the specific lock under contention (`lock_kind: "global"` vs `"package"` + the package name). uci's internal file lock only protects single uci operations, not our multi-step recipe (snapshot, validate, stage, commit, reload, possibly restore), so we own the cross-request critical section explicitly. Same-package fleets under Terraform parallelism will see one 423 per loser; the provider retries with backoff but operators driving large same-package writes should consider `-parallelism=1` for that resource type.
- **Reads are lock-free.** GETs read uci state and never enter the transaction recipe, so concurrent GETs run freely.
- **No in-memory caches across requests.** The token store is re-read from `/etc/config/uapi` on every request (uci read is millisecond-scale and the workload is low-volume; see Auth & ACL). Anything else that looks like a cache must either live in the parent VM at startup (and be treated as read-only by request handlers) or be re-derived per request.
- **Cross-client coordination remains client-side.** Terraform's own state lock (DynamoDB / GCS / etc. backends) handles same-state-file races between separate `terraform apply` runs. Out-of-band changes (LuCI, SSH, two separate Terraform configs) cause drift detected on the next refresh, standard Terraform UX. The server-side flock only serializes our intra-server transaction; we expose no client-facing API lock.
- **Soft design constraint: sync ubus only.** `conn.call()`, never `conn.defer()`. With a fork-per-request model async ubus does not buy any concurrency we don't already have from forking, and sync calls keep the handler linear and the failure paths obvious. Flag any review touching ubus call sites.
- **Optimistic concurrency (ETags / `If-Match`):** shipped in v1.2. Every CRUD `GET` and singleton `GET` returns an `ETag` header computed as a stable hash of the canonical resource body. `PUT`, `PATCH`, and singleton `PATCH` honour `If-Match`: a stale value returns `412 precondition_failed` and aborts the transaction before any uci writes. `If-Match: *` succeeds against any existing resource. Absent `If-Match` preserves last-write-wins behaviour (opt-in concurrency). Multi-resource collections do not currently carry an ETag. **uhttpd carve-out:** uhttpd's CGI env has a hard-coded allowlist of HTTP headers it forwards to the mod-ucode handler (Authorization, Accept-*, Cookie, Host, etc.) and `If-Match` is not in it. To get optimistic concurrency through uhttpd, send the ETag as a `?if_match=<etag>` query parameter instead of (or in addition to) the header; uapi accepts either. Reverse proxies in front of uhttpd that pass the header through still work via the header path.

## Resource model

Hybrid: two namespaces under `/api/v2/`, with different stability promises.

### Curated (`/api/v2/<domain>/...`)

Hand-written schemas, domain-friendly field names, semver-stable.

v1.0 endpoints (the original ten):

- `network/interfaces`, `network/devices`
- `wireless/devices`, `wireless/interfaces`
- `firewall/zones`, `firewall/rules`, `firewall/redirects`
- `dhcp/hosts`, `dhcp/leases` (read-only runtime)
- `system` (singleton)

v1.1 added (additive, non-breaking):

- `network/routes`, `network/rules`, `network/bridge_vlans`, `network/wireguard_peers` (dynamic-type over `wireguard_<iface>`)
- `firewall/forwardings`, `firewall/defaults` (singleton)
- `dhcp/servers`, `dhcp/dnsmasq` (singleton), `dhcp/odhcpd` (singleton)
- `system/timeservers`
- `dropbear/instances`
- `uhttpd/instances`, `uhttpd/certs`
- `unbound/server` (singleton), `unbound/srv` (singleton), `unbound/ext` (singleton).
  `unbound/srv` and `unbound/ext` (added in 2.1.0) wrap the
  `unbound-uci-ext` package's two UCIs, exposing the `server:` clause
  and outside-server clauses that the main unbound package leaves out
  of UCI. Install `unbound-uci-ext` from the openwrt-iac feed first.
- `sqm/queues`
- `snmpd/agents`, `snmpd/com2secs`, `snmpd/groups`, `snmpd/accesses`, `snmpd/system` (singleton)
- `lldpd/config` (singleton)
- `prometheus_node_exporter_lua/config` (singleton)
- `vnstat/config` (singleton), `vnstat/interfaces`
- `packages/installed`, `packages/feeds` (non-uci: shells out to `apk`; see "Packages, non-uci writes" below)

The authoritative current list lives in `build/openapi.json`; when in doubt, regenerate (`make openapi`) and read that.

Each resource is implemented as a ucode module under `/usr/share/uapi/resources/` exporting the uniform contract:

```ucode
return {
    package: "network",                    // uci package
    type: "interface",                     // uci section type
    reload: ["network"],                   // ubus services to reload on write
    schema_properties: { ... },            // type/enum/min/max/pattern/items; enforced centrally
    fromUci: function(section, conn) {...},// uci section → response JSON (conn optional, for runtime block)
    toUci:   function(json) {...},         // request JSON → uci option dict
    validate: function(json, conn, id) {...return [];}, // cross-field / cross-section rules
    merge_for_patch: function(existing, existing_json, body) {...}, // optional, nested-object patches
    id_for_create: function(body) {...return null;}, // optional; runs only when body.id is NOT set. Picks a proto-specific or otherwise-derived section name (e.g. network/interfaces emits a wg_<rand> for proto=wireguard). Returns null to fall through to the default ULID. Called with the request body on create; called with the fromUci view on adopt of an anonymous section (read fields that exist in both, e.g. `proto`; treat `name` as request-only). See "Section names are caller-pickable on every CRUD resource" below.
    create_if_missing: true,  // singletons only; opt-in. When set, PATCH on a missing uci section creates one (named "main") instead of returning 404. Used by unbound/srv + unbound/ext (their extension UCI packages can be wiped by an operator). Most singletons stay opt-out so a missing section surfaces as a real problem.
    singleton_section_name: "main",  // singletons only; defaults to "main". Override only when the underlying uci convention names the section differently.
    unique_field: "name",     // optional. The value of this field must be unique among same-type sections in this package (scope: same package, same uci type). Use for fields that other sections reference by value (firewall.zone.name as a cross-reference key for src_zone, network.device.name for the kernel netdev name referenced by network.interfaces.device) or whose duplication breaks the daemon (sqm.queue.interface: only one queue per interface). 2.2.1.
    // Inside schema_properties entries (per-field, not at the resource level):
    //   default: <value>             OpenAPI 3.1 documentation. Declare for every fromUci unconditional fallback (normalize_bool(section.X, V), section.X ?? L). Framework MUST NOT read or apply this; fromUci owns server-side defaults. 2.2.2.
    //   "x-uapi-clear-on-omit": true Caller-owned field safe for an IaC client to clear by sending JSON null on Update. Opt-in; only annotate when there is evidence the field is leftover-prone. Two hard constraints (enforced by lint-defaults): fromUci shape must be `<jsonkey>: section.<ucikey> ?? null` (no `as_list()`/derivation/aliasing; Terraform plain-Optional reads back null only), AND schema `type:` must include `"null"`. MUTUALLY EXCLUSIVE with `default:`. 2.2.2 (introduced), 2.2.3 (criterion tightened).
    // Optional OpenAPI-only hints (consumed by build/gen_openapi.uc, not by the runtime):
    openapi_required:    [...],            // unconditional required fields
    openapi_conditional: [...],            // if/then/required for proto/type discriminators
    openapi_runtime:     { ... },          // typed sub-shape for resources that populate runtime
};
```

Schemas live **inline in the resource module**, not in separate JSON
Schema files. `schema_properties` is the centrally-enforced
type/enum/range/pattern/items table (handler.check_schema_types walks it
on every write and 422s shape mismatches before `validate()` runs);
`validate()` carries the cross-field, cross-section, and format-string
logic that pure JSON Schema can't express (e.g. "src_zone must reference
an existing zone").

### Generic raw passthrough (`/api/v2/raw/<package>/<section_id>`)

Thin abstraction over uci itself for the long tail. Same atomic transaction recipe, same auth/scope model, but payloads follow uci's field names directly. The `raw` path is **not** raw ubus; sending arbitrary ubus calls remains off-limits.

Auto-reload mapping (package → service) is driven by `/etc/config/ucitrack` with a small fallback table. For packages with no known reload service, fall back to `/etc/init.d/<package> reload` if such a script exists; document clearly in the response when no reload occurred.

### Non-uci resources

A small set of curated resources whose source of truth is **not** `/etc/config/`. Each entry deviates from the standard atomic-uci-transaction recipe and is elaborated in `docs/non-uci-state.md`.

| Resource | Source of truth | Lock | Reload | Notes |
|---|---|---|---|---|
| `packages/installed` | apk DB (`apk add`/`del` shell-out) | `with_lock` | none | postinst runs as root |
| `packages/feeds` | `/etc/apk/repositories.d/*.list` + `apk update` | `with_lock` | none | url-validated |
| `dhcp/leases` | `/tmp/dhcp.leases` (parse) | n/a (read-only) | n/a | dnsmasq IPv4 leases |
| `dhcp/leases6` | `/tmp/(hosts/odhcpd|odhcpd.leases)` (parse) | n/a (read-only) | n/a | odhcpd IPv6 leases |
| `system/password` | `/bin/busybox passwd <user>` (stdin pipe) | `with_lock` | none | write-only; audit logs token+user, never the password |
| `system/authorized_keys` | `/etc/dropbear/authorized_keys` (mode 0600) | `with_lock` | none | dropbear re-reads per connection |

Adding a non-uci resource means adding a row here. The bar for additions is high: prefer driving the underlying daemon's uci surface if the option exists, or upstreaming the option to OpenWrt uci if it doesn't, before adding non-uci state to uapi.

### Curation completeness

When adding or extending a curated resource, the test is: *does this resource expose the options that a typical real configuration of this section actually sets?* If a common real-world setup of this section requires uci options the curated resource does not surface, that is a curation gap; close it. Telling users to drop to `/raw/` for a routine field is a smell.

## JSON conventions (curated layer)

- `snake_case` field names (matches uci, matches Terraform conventions).
- Stable `id` always at top level.
- `managed: bool` always at top level (see anonymous-section IDs below).
- Booleans normalized. uci's `"1"`/`"0"`/`"on"`/`"off"` → real JSON `true`/`false`.
- List options (`list dns '8.8.8.8'`) → JSON arrays.
- Nested objects where they aid readability (e.g., firewall rule's match conditions as `match: {src_zone, dest_zone, proto, ...}`).
- Runtime/computed fields under a separate `runtime: {...}` block. Terraform marks these `computed` and ignores them for drift detection.

## Anonymous-section IDs

OpenWrt's uci has named sections (stable) and anonymous sections (auto-assigned `cfgXXXXXX` IDs that change on rewrite). Anonymous IDs are useless for Terraform.

**Solution: uapi-managed sections are always named.** When a client POSTs to create a resource, uapi generates a ULID-style ID (Crockford base32, alphanumeric only, fitting uci's `[A-Za-z0-9_]` name charset) and writes it as the uci section's `.name`. From that point on the section behaves like any other named uci section, and its ID is stable forever.

Optional one-character type prefix for grep-ability (`r_01HX...` for rules, `i_01HX...` for interfaces). No `uapi_` namespace prefix; we're just another writer to uci.

**Section names are caller-pickable on every CRUD resource (2.2.0).** Every `POST /<resource>` accepts an optional `id` field at top level. If supplied it becomes the uci section name AND the response `id` (after validation: uci section-name charset, 32-char default cap, no collision with any existing section in the package). If absent the server emits a server-generated ULID, exactly as it did before 2.2.0. The default fallback is registered on `make()` via the `id_prefix` derived from the section type; resources with proto-specific requirements register a per-module `id_for_create(body)` hook that runs when `body.id` is unset (e.g. `network/interfaces` emits a 14-char `wg_<rand>` for `proto=wireguard` because netifd uses the section name as the kernel netdev name and Linux's IFNAMSIZ caps it at 15 chars; a 28-char ULID would silently break the tunnel, the v2.0.2 forcing case).

The uniform rule replaced the per-resource carve-out we accumulated through 2.1.0. The same `id` input works for the resources where the section name is a first-class semantic handle in OpenWrt (`network/interfaces`, `firewall/zones`, `network/devices`, etc., referenced by other resources by name) and for the ones where the section name is internal bookkeeping (`firewall/rules`, `dhcp/hosts`, etc., where operators rarely care).

The 2.1.0-era `network/interfaces.name` input is still accepted but marked deprecated; clients should migrate to `id` per `docs/deprecations.md`. If both `name` and `id` are supplied on `network/interfaces` they must match; otherwise the request is rejected with `422 conflict`.

### Pre-existing anonymous sections

A router with existing anonymous sections (manual edits, LuCI, other tools) is the common starting state. Posture: **read-only surface with explicit adoption.**

- GET returns existing anonymous sections with a content-derived synthetic ID and `managed: false`.
- PUT/PATCH/DELETE on a `managed: false` section returns `409 unmanaged_resource`.
- `POST .../adopt` on an **anonymous** section renames it under uapi's ULID scheme and flips it to `managed: true`. After adoption it's writable like any other resource.
- `POST .../adopt` on a **named** section (e.g. the box's default `lan` zone) is an idempotent acknowledgement: the section keeps its name and the response carries the existing view (`managed: true`). This is the 2.2.0 behavior change; previously adopt always renamed to ULID, which broke uci cross-references where other sections referenced this one by name (`firewall.zones.lan` referenced by `firewall.rules.src_zone = "lan"`, etc.).

### Named sections written by other tools

Sections that already have a `.name` (e.g., LuCI-named `myrule`) are managed normally, using their existing `.name` as the ID. We do not rewrite names we didn't author.

### Default GET behavior

GETs include both managed and unmanaged sections. Clients filter via query params if they want only one (`?managed=true`).

## Atomic transaction recipe

Every write follows this sequence:

0. **Pre-flight service check.** For each entry in `reload_services`, confirm `/etc/init.d/<svc>` exists (and the service name matches `^[A-Za-z0-9_-]+$`). On miss, return `503 init_script_missing` immediately with the path that wasn't found, before any uci write. This catches "trying to manage a daemon that isn't installed" early; the alternative is stage+commit+reload-fail+restore+reload-fail-again, which is what the snapshot-restore path was NOT designed for.
1. `flock(LOCK_EX | LOCK_NB)` on `/var/lock/uapi.lock`. On `EWOULDBLOCK`, return `423 locked` with `Retry-After: 1` immediately; no state change. The lock is released in a `finally` after the rest of the recipe.
2. `uci export <package>` → snapshot
3. Validate payload against resource schema → `422` on fail, no commit
4. `uci set` / `uci add` / `uci delete` (staging only, no commit yet)
5. `uci commit <package>`
6. `/etc/init.d/<service> reload` via `fs.popen`, exit code checked. Done directly (not through ubus) because every ubus-mediated reload path on OpenWrt (`ubus call <svc> reload`, `ubus call rc init`, `uci apply`) is fire-and-forget: rpcd's deferred-request callback completes with `UBUS_STATUS_OK` regardless of the init script's actual exit code. Only the kernel-level wait4 on a spawned child gives us back a real success/failure bit.
7. **On reload error (non-zero exit from the init script):** `uci import` snapshot, re-reload to restore prior daemon state, return `500 reload_failed_restored` with the captured stderr/exit-code summary in `reload_error`. If the restore itself fails, return `500 reload_failed_unrecovered` (loud; this is the worst case).
8. **On success:** return `200` with the refreshed resource (uci-configured state).

### What "reloaded" means

Return as soon as the init script's reload action returns. Do **not** poll for async convergence (interface bring-up, DHCP, wifi association can take 10+ seconds). GETs read uci-configured state, which matches Terraform's mental model: desired-config vs. actual-config diff. Runtime fields (under `runtime: {...}`) reflect ubus runtime data and are marked `computed` so Terraform ignores them for drift.

### Honest limitation of "atomic"

Snapshot-and-restore catches the case where the init script's reload action exits non-zero. It does **not** catch the more common silent failure where the init script exits 0 but the daemon's runtime convergence is broken (interface fails to come up, fw4 accepts a config that netifd later rejects, etc.); the init script itself has no way to know. The response code is precise about which path executed; clients should not assume `200 OK` means runtime convergence. A future feature could add a `commit-confirmed` mode (apply, wait, auto-revert unless client acks within N seconds). Not in v1.

## Roadmap

See [docs/roadmap.md](docs/roadmap.md). Shipped, features (additive minor bumps), hardening (no new wire surface), out of scope. Update that file when an item moves between sections.
