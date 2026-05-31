# uapi

Native, lightweight, production-grade HTTP REST API for OpenWrt. Translates standard REST verbs into ubus calls so modern edge routers become first-class targets for Infrastructure-as-Code workflows. Primary design validation: serving as the backend for a custom Terraform provider.

This document captures the v1 design contract. It is comprehensive and authoritative; changes here require the same scrutiny as code changes.

---

## Architectural principles (non-negotiable)

1. **Native integration (direct-to-bus).** Communicate with OpenWrt via ubus through the ucode runtime. No intermediate proxy daemons. No direct `/etc/config/` file manipulation; all writes go through uci's API.
2. **Zero-bloat footprint.** Target is resource-constrained embedded hardware. Runtime overhead, memory, and storage stay negligible. Reject dependencies that don't earn their keep.
3. **Atomic transactions.** A single HTTP write request stages → validates → commits → reloads in one transaction. No partial-failure states, no config drift.

Before adopting any library, daemon, persistence layer, or abstraction, check it against these three. Prefer ucode-native solutions; flag anything requiring a long-running auxiliary process, direct `/etc/config/` writes, or splitting a logical state change across multiple HTTP requests.

---

## Code and documentation style

- **Priorities, in order:** simplicity, maintainability, modularity, readability.
- **No em-dashes.** Applies to code, comments, docs, commit messages, and design notes.
- **Comments are rare.** Default to writing none. Naming and structure should carry the meaning.
- **When a comment is necessary, explain why, not what.** A reader can see what the code does; what they cannot see is the non-obvious constraint, invariant, or workaround that motivated the choice.

---

## HTTP host

- **Runtime:** `uhttpd` + `uhttpd-mod-ucode`. No daemon of our own; our handler runs inside the existing uhttpd process.
- **Instance:** Share the default `main` uhttpd instance with LuCI. Both serve configuration use cases; sharing keeps the footprint minimal and inherits the user's TLS config.
- **Wiring:** A single ucode prefix registration: `list ucode_prefix '/api/v1=/usr/share/uapi/main.uc'`. Installed via `/etc/uci-defaults/99-uapi`.
- **Handler shape:** Template-mode ucode script (entered with `{%`). The script's top level runs once in the uhttpd parent at startup and must define `global.handle_request(env)`. Each request is a forked child that inherits the parent VM via copy-on-write and invokes `handle_request`. `main.uc` performs internal method/path dispatch to per-resource modules.

## Concurrency

- **Fork-per-request CGI model.** `uhttpd-mod-ucode` is not a persistent in-process handler. The parent uhttpd compiles the script and runs its top level once at startup, populating the parent VM scope. Every HTTP request is served by a forked child that inherits the parent VM via copy-on-write, invokes `handle_request(env)`, and exits. Module-level state initialized at startup is visible to every request, but mutations are private to the fork and lost on exit.
- **Empirically validated.** `tests/integration/01_concurrency_model_test.sh` fires 5 concurrent requests against a 1s-sleep probe and observes 5 distinct PIDs, every response showing `count == 1`, with wall time approximately 1 to 2s. Source confirmation at `openwrt/uhttpd/ucode.c`: `ucode_handle_request` calls `ops->create_process(cl, pi, url, ucode_main)`; `ucode_main` ends with `exit(0)`. Keep this test green as a regression sentinel.
- **Writes acquire a global flock.** The atomic transaction recipe takes `flock(LOCK_EX | LOCK_NB)` on `/var/lock/uapi.lock` as step 0. On `EWOULDBLOCK`, return `423 locked` with `Retry-After: 1` immediately; the client retries. uci's internal file lock only protects single uci operations, not our multi-step recipe (snapshot, validate, stage, commit, reload, possibly restore), so we own the cross-request critical section explicitly.
- **Reads are lock-free.** GETs read uci state and never enter the transaction recipe, so concurrent GETs run freely.
- **No in-memory caches across requests.** The token store is re-read from `/etc/config/uapi` on every request (uci read is millisecond-scale and the workload is low-volume; see Auth & ACL). Anything else that looks like a cache must either live in the parent VM at startup (and be treated as read-only by request handlers) or be re-derived per request.
- **Cross-client coordination remains client-side.** Terraform's own state lock (DynamoDB / GCS / etc. backends) handles same-state-file races between separate `terraform apply` runs. Out-of-band changes (LuCI, SSH, two separate Terraform configs) cause drift detected on the next refresh, standard Terraform UX. The server-side flock only serializes our intra-server transaction; we expose no client-facing API lock.
- **Soft design constraint: sync ubus only.** `conn.call()`, never `conn.defer()`. With a fork-per-request model async ubus does not buy any concurrency we don't already have from forking, and sync calls keep the handler linear and the failure paths obvious. Flag any review touching ubus call sites.
- **Optimistic concurrency (ETags):** deferred to v1.1+. Add `If-Match` support later if real demand surfaces.

## Resource model

Hybrid: two namespaces under `/api/v1/`, with different stability promises.

### Curated (`/api/v1/<domain>/...`)

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
- `unbound/server` (singleton)
- `sqm/queues`
- `snmpd/agents`, `snmpd/com2secs`, `snmpd/groups`, `snmpd/accesses`, `snmpd/system` (singleton)
- `lldpd/config` (singleton)
- `prometheus_node_exporter_lua/config` (singleton)
- `vnstat/config` (singleton), `vnstat/interfaces`
- `packages/installed`, `packages/feeds` (non-uci: shells out to `apk`; see "Packages — non-uci writes" below)

The authoritative current list lives in `build/openapi.json`; when in doubt, regenerate (`make openapi`) and read that.

Each resource is implemented as a ucode module under `/usr/share/uapi/resources/` exporting the uniform contract:

```ucode
return {
    package: "network",            // uci package
    type: "interface",              // uci section type
    reload: ["network"],            // ubus services to reload on write
    schema: { ... },                // validation rules (ucode predicate or JSON Schema)
    fromUci: (section) => {...},    // uci section → response JSON
    toUci: (json) => {...},         // request JSON → uci option dict
    runtime: (id) => {...},         // optional: fetch runtime state via ubus
};
```

Schemas live **inline in the resource module**, not in separate JSON Schema files. ucode predicates are more expressive than pure JSON Schema (e.g., "valid CIDR", "must reference an existing zone") and there's no install/packaging complexity.

### Generic raw passthrough (`/api/v1/raw/<package>/<section_id>`)

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

When adding or extending a curated resource, the test is: *does this resource expose the options that a typical real configuration of this section actually sets?* If a common real-world setup of this section requires uci options the curated resource does not surface, that is a curation gap — close it. Telling users to drop to `/raw/` for a routine field is a smell.

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

### Pre-existing anonymous sections

A router with existing anonymous sections (manual edits, LuCI, other tools) is the common starting state. Posture: **read-only surface with explicit adoption.**

- GET returns existing anonymous sections with a content-derived synthetic ID and `managed: false`.
- PUT/PATCH/DELETE on a `managed: false` section returns `409 unmanaged_resource`.
- `POST .../adopt` renames the section under uapi's ULID scheme and flips it to `managed: true`. After adoption it's writable like any other resource.

### Named sections written by other tools

Sections that already have a `.name` (e.g., LuCI-named `myrule`) are managed normally, using their existing `.name` as the ID. We do not rewrite names we didn't author.

### Default GET behavior

GETs include both managed and unmanaged sections. Clients filter via query params if they want only one (`?managed=true`).

## Atomic transaction recipe

Every write follows this sequence:

0. `flock(LOCK_EX | LOCK_NB)` on `/var/lock/uapi.lock`. On `EWOULDBLOCK`, return `423 locked` with `Retry-After: 1` immediately; no state change. The lock is released in a `finally` after the rest of the recipe.
1. `uci export <package>` → snapshot
2. Validate payload against resource schema → `422` on fail, no commit
3. `uci set` / `uci add` / `uci delete` (staging only, no commit yet)
4. `uci commit <package>`
5. `/etc/init.d/<service> reload` via `fs.popen`, exit code checked. Done directly (not through ubus) because every ubus-mediated reload path on OpenWrt (`ubus call <svc> reload`, `ubus call rc init`, `uci apply`) is fire-and-forget: rpcd's deferred-request callback completes with `UBUS_STATUS_OK` regardless of the init script's actual exit code. Only the kernel-level wait4 on a spawned child gives us back a real success/failure bit.
6. **On reload error (non-zero exit from the init script):** `uci import` snapshot, re-reload to restore prior daemon state, return `500 reload_failed_restored` with the captured stderr/exit-code summary in `reload_error`. If the restore itself fails, return `500 reload_failed_unrecovered` (loud; this is the worst case).
7. **On success:** return `200` with the refreshed resource (uci-configured state).

### What "reloaded" means

Return as soon as the init script's reload action returns. Do **not** poll for async convergence (interface bring-up, DHCP, wifi association can take 10+ seconds). GETs read uci-configured state, which matches Terraform's mental model: desired-config vs. actual-config diff. Runtime fields (under `runtime: {...}`) reflect ubus runtime data and are marked `computed` so Terraform ignores them for drift.

### Honest limitation of "atomic"

Snapshot-and-restore catches the case where the init script's reload action exits non-zero. It does **not** catch the more common silent failure where the init script exits 0 but the daemon's runtime convergence is broken (interface fails to come up, fw4 accepts a config that netifd later rejects, etc.); the init script itself has no way to know. The response code is precise about which path executed; clients should not assume `200 OK` means runtime convergence. A future feature could add a `commit-confirmed` mode (apply, wait, auto-revert unless client acks within N seconds). Not in v1.

## Auth & ACL

- **Bearer tokens, local-only creation.** No rpcd sessions. No HTTP login endpoint.
- **Token store:** sha256+salt hash in `/etc/config/uapi`. Cleartext token shown only once at creation. Re-read on every request (no in-memory cache, per "Concurrency"); newly created tokens take effect immediately, no `uhttpd reload` required.
- **CLI:** `uapi-token create --name <label> --scope <s> [--scope <s>...]`, plus `list` / `show` / `revoke`. Scopes validated against the known tree, `--force` bypasses for forward-compat with unknown future endpoints.
- **Wire format:** `Authorization: Bearer <token>` header.
- **Public endpoints (no auth):** `/healthz` (liveness) and `/openapi.json` (spec discovery). Both still pass the TLS check; only the bearer requirement is waived.

### Scope model

Hierarchical, deepest-match wins. Syntax: `<segment>[:<segment>...]:(rw|ro)`.

- Two-segment depth max for v1: `<domain>:<subresource>:<verb>` for curated, `raw:<package>:<verb>` for raw.
- `*:rw` and `*:ro` are top-level wildcards. Mid-tree wildcards are also supported: `firewall:*:ro` permits ro on every firewall subresource but NOT the bare domain; `*:rules:ro` permits ro on the `rules` subresource of every domain. At the same depth, an exact segment beats a wildcard segment (`firewall:rules:rw` wins over `firewall:*:ro` for path `[firewall, rules]`).
- A `rw` scope implies `ro`; granting `firewall:rw` does not also require granting `firewall:ro`.
- Same-depth conflict (`firewall:rules:rw` + `firewall:rules:ro`): `rw` wins.
- No matching scope → deny.

Matching algorithm: extract resource path from the URL (e.g., `[firewall, rules]`); for each token scope, check whether its segment-path is a prefix of the request's resource path; among matching scopes, the longest prefix wins; apply its verb.

### Raw access composition (safer model)

A request to `/api/v1/raw/<package>/<section_id>` requires **both trees to permit, independently**:

1. The **raw tree** permits the verb (`raw` or `raw:<package>` matches; deepest wins).
2. The **domain tree** permits the verb, evaluated using the section's actual type as the second path segment.

A user who set `firewall:rules:ro` is protected even if they have `raw:rw`; the raw access still goes through firewall's domain-tree check.

### Scope tree

v1.0:
- `network`, `network:interfaces`, `network:devices`
- `wireless`, `wireless:devices`, `wireless:interfaces`
- `firewall`, `firewall:zones`, `firewall:rules`, `firewall:redirects`
- `dhcp`, `dhcp:hosts`, `dhcp:leases`
- `system`
- `raw`, `raw:<package>` (any package name)

v1.1 added:
- `network:routes`, `network:rules`, `network:bridge_vlans`, `network:wireguard_peers`
- `firewall:forwardings`, `firewall:defaults`
- `dhcp:servers`, `dhcp:dnsmasq`, `dhcp:odhcpd`
- `system:timeservers`
- `dropbear`, `dropbear:instances`
- `uhttpd`, `uhttpd:instances`, `uhttpd:certs`
- `unbound`, `unbound:server`
- `sqm`, `sqm:queues`
- `snmpd`, `snmpd:agents`, `snmpd:com2secs`, `snmpd:groups`, `snmpd:accesses`, `snmpd:system`
- `lldpd`, `lldpd:config`
- `prometheus_node_exporter_lua`, `prometheus_node_exporter_lua:config`
- `vnstat`, `vnstat:config`, `vnstat:interfaces`
- `packages`, `packages:installed`, `packages:feeds`

The authoritative source is `src/lib/scope.uc`'s `KNOWN_PATHS`.

### TLS and rate limiting

- **TLS enforced for non-localhost.** Check uhttpd's `HTTPS=on` env var; if the request is not over TLS and the client is not on `127.0.0.1`/`::1`, return `403 tls_required`. This runs **before** auth.
- TLS config inherited from uhttpd. Document that the default self-signed cert is not adequate for production; point operators at `acme.sh` / `luci-app-acme`.
- **Insecure-test bypass.** If the marker file `/etc/uapi.insecure` exists, plain HTTP is accepted from any client. Intended for closed-network testing only; documented as a security hole. Every request that bypasses TLS via the marker emits a syslog `NOTICE` line (`uapi-insecure-bypass <request_id> <method> <path> status=<n> remote=<addr>`) so operators can detect drift.
- **Rate limiting:** not in v1. Operators add a reverse proxy if they need it.

### Audit log

One syslog line per **write** request (token *name*, never value, plus method, path, status, request_id). Reads are not audit-logged (volume).

## Error envelope

Lean custom shape, RFC 7807-inspired but not strictly conformant. `application/json` throughout.

```json
{
  "code": "validation_failed",
  "message": "Field 'ipaddr' is not a valid IPv4 address",
  "request_id": "01HX1234567890ABCDEFGHJKMN",
  "errors": [
    { "field": "ipaddr", "code": "invalid_format", "message": "must be a valid IPv4 address" },
    { "field": "netmask", "code": "required", "message": "is required" }
  ]
}
```

- `code` is machine-readable, snake_case, stable.
- `message` is human-readable English.
- `request_id` is a ULID echoed in body and `X-Request-Id` response header. Header present on every response, success or error.
- `errors[]` only present for `422`. **All** field-level validation errors reported together (not fail-fast); clients fix everything in one round trip.

### Standard top-level codes

| HTTP | `code`                          |
|------|----------------------------------|
| 400  | `bad_request`                    |
| 401  | `unauthorized`                   |
| 401  | `invalid_token`                  |
| 403  | `insufficient_scope`             |
| 403  | `tls_required`                   |
| 404  | `not_found`                      |
| 405  | `method_not_allowed`             |
| 409  | `conflict`                       |
| 409  | `unmanaged_resource`             |
| 415  | `unsupported_media_type`         |
| 422  | `validation_failed`              |
| 423  | `locked`                         |
| 500  | `internal_error`                 |
| 500  | `reload_failed_restored`         |
| 500  | `reload_failed_unrecovered`      |
| 503  | `service_unavailable`            |

The `reload_failed_restored` body carries the underlying ubus error as a `reload_error` extension field.

### Field-level codes (within `errors[]`)

| `code`           | Meaning                                                       |
|------------------|---------------------------------------------------------------|
| `required`       | Required field missing                                        |
| `invalid_type`   | Wrong JSON type                                               |
| `invalid_format` | Failed format validator (CIDR, MAC, IP, etc.)                 |
| `out_of_range`   | Numeric or length bound exceeded                              |
| `not_in_enum`    | Value not in allowed set                                      |
| `conflict`       | References missing/incompatible resource                      |
| `read_only`      | Field is computed/runtime and can't be set                    |

### Field paths

Dotted notation with bracket indexing: `match.src_zone`, `dns[0]`, `rules[2].target`.

### Success response shapes

- GET/POST/PUT 2xx: response body **is** the resource. No `{ "data": {...} }` wrapper.
- DELETE success: `204 No Content`, no body. `X-Request-Id` header still set.
- Error responses (including from DELETE): full envelope body.

## Observability

### Log categories

| Category | Severity     | Default | Triggers                                                  |
|----------|--------------|---------|-----------------------------------------------------------|
| AUDIT    | NOTICE       | on      | Successful writes (POST/PUT/DELETE 2xx)                   |
| ERROR    | WARN / ERR   | on      | Auth failures (401/403), all 5xx                          |
| ACCESS   | INFO         | off     | Every request (non-`/healthz`)                            |
| DEBUG    | DEBUG        | off     | Per-ubus-call tracing                                     |

The `/healthz` path is excluded from all categories so monitoring traffic does not drown out the audit trail.

Opt-in knobs in `/etc/config/uapi`:

```
config logging
    option access '0'
    option debug '0'
```

### Format

Plain text, fixed field order, syslog-native:

```
uapi: <request_id> <token_name|-> <severity> <code> <method> <path> <status> [<duration_ms>ms]
```

Plain text over JSON-per-line because `logread` is the primary consumer. Token name is `-` when there isn't one (pre-auth failures); `code` is `-` on audit success.

### Healthz

`GET /api/v1/healthz`:
- No auth required (TLS-for-non-localhost still applies; check order is TLS → auth → handler; healthz only skips auth).
- Minimal info: `{ "status": "ok", "version": "1.0.0" }`.
- `503` with `{ "status": "degraded", "errors": [...] }` if ubus unreachable.
- Not audit-logged.

### Metrics

Not in v1. Operators wanting router-level metrics use `node_exporter`. Easy to add later as a non-breaking change.

### Operator-facing recommendations (docs, not code)

- NTP must work; audit logs depend on correct clocks.
- Configure persistent syslog (`log_file` in `/etc/config/system`) for production deployments.
- Consider forwarding syslog to a central collector (`log_ip`) for tamper-resistant audit trails.

## Testing

### Layers

- **Unit tests** (pure ucode): schema validation, `fromUci`/`toUci`, scope matcher, ID generation, error envelope, transaction snapshot logic. Runs anywhere ucode runs. Sub-5s.
- **Integration tests** (QEMU + official OpenWrt VM image): full transaction recipe against real ubus/uci, auth on the wire, audit log emission, snapshot-restore. ~1–2 min including boot.
- **Contract / Terraform provider tests**: deferred to when the provider exists. Seeded by the in-repo curl example suite and the emitted OpenAPI spec.

### ucode test harness

Thin homegrown harness (`tests/harness.uc`, ~100 lines): `describe` / `it` / `assert_equal` / `assert_throws`, plain text output, exit code 1 on any failure.

### Injectable ubus surface

All ubus/uci calls route through a single injectable surface. In production it's the real `ubus.connect()` / `uci.cursor()`; in unit tests it's a stub returning canned responses. This is the difference between covering 30% and covering the transaction recipe's failure paths (specifically the snapshot-restore rollback, which is hard to trigger naturally).

### Load-bearing integration tests (write first)

1. **Serialization confirmation.** Handler sleeps 1s; 3 concurrent curls; total wall time ≈ 3s. Gates the no-flock decision.
2. **Happy-path write.** PUT → 200 → GET reflects new state → audit log line in syslog.
3. **Validation failure.** Bad payload → 422 with field errors → no uci change.
4. **Reload failure rollback.** Construct a config uci accepts but the daemon rejects → 500 `reload_failed_restored` → uci back to prior state.
5. **Auth paths.** Missing/bad token → 401. Insufficient scope → 403. Plain HTTP from remote → 403 `tls_required`.
6. **Adoption flow.** Pre-existing anonymous section → `managed: false` → PUT denied with `unmanaged_resource` → `POST .../adopt` → writable.
7. **APK install smoke test.** Fresh OpenWrt 25.12 → `apk add uapi` → init script wires uhttpd → curl works.

### CI shape

- Every commit/PR: unit suite + lint.
- Every PR + main: unit + integration suite (QEMU).
- Release tag: + APK install smoke test against the candidate APK.

### OpenAPI emission

v1 deliverable. Generated at build time from the inline schemas; shipped as `/usr/share/uapi/openapi.json`. Becomes the contract document and input for future provider codegen.

### Curl example suite

In-repo at `examples/curl/`, one file per resource demonstrating CRUD. Doubles as documentation and seed for provider contract tests.

## APK packaging (OpenWrt 25.12+)

**No daemon of our own.** Package's job is (a) drop files, (b) wire our handler into uhttpd's config, (c) clean up that wiring on removal.

### File layout

```
/usr/share/uapi/
  main.uc                          # entry point uhttpd registers
  raw.uc                            # generic /raw/ handler
  lib/
    auth.uc                         # token + hierarchical scope matcher
    transaction.uc                  # snapshot / commit / reload / restore; also with_lock for non-uci writes
    errors.uc                       # error envelope construction
    ids.uc                          # ULID generation
    ucitrack.uc                     # package → reload-service mapping
    handler.uc                      # resource factory (CRUD/singleton/collection); dynamic-type hooks
    packages.uc                     # non-uci writes: apk install/remove + feeds (under the same flock)
    # plus: scope.uc, values.uc, bus.uc, log.uc, openapi.uc
  resources/
    # see "Curated" above for the full v1.x list (32 modules at v1.1).
    # Authoritative list: build/openapi.json + src/main.uc RESOURCES/SINGLETONS.
  openapi.json                      # generated at build time

/usr/bin/uapi-token                 # CLI (ucode script, #!/usr/bin/ucode)

/etc/config/uapi                    # token store + settings (conffile)

/etc/uci-defaults/99-uapi           # one-shot wiring script, self-deletes
```

### Dependencies

- `uhttpd`
- `uhttpd-mod-ucode`
- `ucode` (explicit for clarity)
- `ucode-mod-ubus`
- `ucode-mod-uci`
- `ucode-mod-fs`
- `ucode-mod-digest`

No conflicts. Coexists with rpcd, LuCI, anything else on uhttpd.

### Install hook (`/etc/uci-defaults/99-uapi`)

1. Check if `uhttpd.main.ucode_prefix` already contains our entry; if so, exit (idempotent).
2. `uci add_list uhttpd.main.ucode_prefix='/api/v1=/usr/share/uapi/main.uc'`
3. `uci commit uhttpd`
4. `/etc/init.d/uhttpd reload`

Wires only to the `main` uhttpd instance. Users with multiple instances who want the API on another instance configure it manually (documented in post-install message).

### Pre-remove hook

1. `uci del_list uhttpd.main.ucode_prefix='/api/v1=/usr/share/uapi/main.uc'`
2. `uci commit uhttpd`
3. `/etc/init.d/uhttpd reload`

Removes the prefix entry **before** the handler file disappears.

### Conffile handling

- `/etc/config/uapi` is marked as a conffile (`Package/uapi/conffiles`). Token store is precious user state; never overwrite on upgrade.
- Ship the file with a commented-out example token block to help operators understand the structure.
- Files under `/usr/share/uapi/` are package-owned, freely overwritten on upgrade.

### Post-install message

```
uapi installed. To start using it:
  1. Create a token:    uapi-token create --name <label> --scope '*:rw'
  2. Verify it works:   curl -H "Authorization: Bearer <token>" https://<router>/api/v1/system
  3. See docs at:       /usr/share/uapi/openapi.json
```

No default token shipped; would be a security hole.

### Versioning

Package version follows semver, with the major version aligned to the API major:

- **MAJOR (`(x+1).0.0`)**: breaking on-the-wire change. `/api/v(x+1)/` mounts alongside `/api/v<x>/` and both run for at least one OpenWrt release cycle (see "API versioning policy" below). Clients have a deprecation window to migrate.
- **MINOR (`x.(y+1).0`)**: backwards-compatible additions only (the list of allowed changes is in "API versioning policy" below).
- **PATCH (`x.y.(z+1)`)**: bug fixes only. No surface change.

A client tested against `x.y.z` works against every future `x.y'.z'` with `y' >= y`. `1.0.0` is the v1 launch.

### Distribution

- v1 launch: project-owned OpenWrt feed (single `apk` repo URL users add).
- Later: submit to official `packages` feed once stable. Don't block v1 on this.

## API versioning policy

`/api/v1/` is the stable contract.

**Non-breaking (allowed within v1):**
- New endpoints / resources
- New optional request fields
- New response fields (clients must ignore unknown fields)
- New optional query parameters
- New error codes (clients branch on HTTP status, treat unknown `code` gracefully)
- New scope names

**Breaking (requires v2):**
- Removing or renaming any endpoint, field, or error code
- Changing a field's JSON type or semantic meaning
- Making a previously-optional request field required
- Tightening validation to reject previously-accepted payloads

When v2 lands, `/api/v1/` and `/api/v2/` register with uhttpd simultaneously and run side-by-side for at least one major OpenWrt release cycle. v1 removal is announced in advance via release notes and the post-install message.

### `/raw/` stability

URL structure, verbs, auth/scope behavior, and error envelope are v1-stable. Payload shape follows uci, which is OpenWrt's moving target; if OpenWrt changes the `firewall` package schema, `/raw/firewall/...` payloads change with it. Documented loudly so users don't expect curated-level stability from raw.

### OpenAPI spec versioning

The emitted `openapi.json` carries the same version as the API it describes (`info.version: "1.0.0"` for uapi v1.0.0). The spec is the source of truth for what's in v1's contract at any given release.

---

## v1.1+ roadmap

These are explicitly out-of-scope for v1.0 and require either substantive new code or an architectural change that conflicts with one of the three non-negotiable principles. Listed so v1 ships honestly about what it does not do.

- **ETags / `If-Match` optimistic concurrency.** A future revision can compute a stable hash of the canonical resource shape and surface it as `ETag`, with `If-Match` rejecting stale writes. Substantive feature, fits the architecture cleanly, just not in v1.
- **`commit-confirmed`-style timed rollback** (apply, wait, auto-revert unless the client acks within N seconds). Conflicts with the fork-per-request model (no place for a background timer); would require a small procd-managed sidecar.
- **`/metrics` endpoint** (Prometheus-style). Counters and histograms need cross-fork shared state; a uci-backed counter or a tiny procd-managed registry is the realistic path.
- **Per-token rate limiting.** Same shared-state problem as `/metrics`. Operators today should front the API with a reverse proxy if they need this.
- **HTTP token creation endpoint** (for a future LuCI plugin managing uapi tokens). Deliberately CLI-only in v1; an HTTP path needs an admin-scope design that avoids handing remote attackers a token-mint endpoint on compromise.
- **Localization of error `message` strings.** English-only in v1; codes are stable and translatable client-side.
