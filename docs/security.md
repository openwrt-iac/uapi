# uapi security model

What uapi defends against, what it doesn't, and what the operator should do.

## Threat model

### In scope (defended)

1. **Anonymous remote access.** Every endpoint except `/healthz`,
   `/openapi.json`, and `/schema*` requires a bearer token. There is no
   anonymous read path on user resources.
2. **Plain-HTTP credential leak.** TLS is mandatory for every non-localhost
   request. A non-TLS request from a non-loopback source returns
   `403 tls_required` before auth runs.
3. **Token guessing.** Tokens are 128 random bits (32 hex chars). Server
   stores `sha256(salt || ":" || token)`; the cleartext is shown to the
   operator exactly once at creation. A linear scan through the token store
   on each request is acceptable: tokens are few, hashes are fast, and
   compromising the server's `/etc/config/uapi` exposes only hashes.
4. **Privilege escalation via HTTP token-mint.** `POST /tokens` is gated by
   `uapi:tokens:rw`, AND the requested scopes must be a strict subset of the
   caller's own - escalation returns `403 scope_escalation_blocked`. A
   compromised low-privilege token cannot mint an admin token over the API.
5. **Stolen-token reuse from elsewhere.** Optional `allowed_cidrs` on a
   token pins it to a source CIDR list; requests from outside return
   `401 invalid_token`. Optional `expires_at` makes leaked tokens
   automatically expire.
6. **Audit log tampering during compromise.** Each write emits a syslog
   NOTICE line carrying request_id + token name + path. Forwarding syslog
   to a remote collector (`log_ip` in `/etc/config/system`) is the
   recommended production setup; a local-only log is destroyable by anyone
   who roots the box.
7. **Bypassing scope checks via `/raw/`.** `/raw/<package>/<id>` requires
   BOTH a `raw:*:rw|ro` scope and the matching domain scope independently.
   A token with `raw:rw` but only `firewall:ro` cannot use `/raw/firewall/...`
   to mutate firewall sections.
8. **Shell metacharacter injection.** Every shell-invoked path (apk install,
   init-script reload) validates names against
   `^[A-Za-z0-9_-]+$` (or `^[A-Za-z0-9_+][A-Za-z0-9_+.-]*$` for packages)
   before interpolating, and uses `--` to separate flags from positional
   arguments. Service names from ucitrack are validated before
   interpolating into `/etc/init.d/<svc>`.
9. **Replay attacks on POST under network flakiness.** `Idempotency-Key`
   caches the response for 24 h; a network-blipped retry returns the cached
   response, not a duplicate side effect. Same key with a different body
   returns `409 idempotency_key_conflict` - a request was reused for an
   unrelated payload.
10. **Resource exhaustion via flood.** Per-token rate limit returns
    `429 too_many_requests` with `Retry-After`. Default is 100/s burst 200
    per token; tunable via `/etc/config/uapi`.
11. **Bridge-vlan self-lockout.** Documented in `CLAUDE.md` and surfaced in
    the project memory: writing bridge-vlans on `br-lan` of the management
    bridge bricks the router. Use a throwaway bridge for tests; never POST
    `bridge_vlans` on the management bridge.
12. **uhttpd self-lockout.** `uhttpd/instances` validate refuses any PATCH
    or PUT on the `main` instance that would strip uapi's own `ucode_prefix`
    entry - returning `422 conflict` instead of leaving uapi unreachable.

### Out of scope (not defended)

1. **Local root compromise.** uapi runs inside uhttpd, which runs as root.
   An attacker with root on the box already has uci access; the API is a
   wrapper. We do not defend against in-process attacks once the workload
   ID is admin.
2. **Fine-grained side channels.** The hash compare in auth is
   constant-time (byte-XOR-accumulate via `values.constant_time_equals`)
   and the authorize loop iterates every token regardless of where the
   match occurs, so the dominant timing channel is closed. Pre-match work
   (`type(t.salt) == "string"` checks, hash-function runtime itself) and
   downstream paths (expiry check, CIDR match, scope lookup) are not
   constant-time. A determined attacker with low-latency local access
   could in principle still extract bits, but tokens are 128 random bits
   and the rate limit + audit log make recovery infeasible in practice.
3. **DoS by sustained legitimate traffic.** The rate limit guards per
   token; the request budget is per uhttpd worker / kernel limits. A
   determined operator who hands out 10,000 tokens at 100/s each can
   saturate the box. Don't.
4. **Compromise of the OpenWrt host network.** If the router's management
   interface is on a hostile network, no application-layer auth helps. Use
   uhttpd's TLS + `allowed_cidrs` + firewall rules to restrict the listen
   surface.

## Scope model

Hierarchical, deepest-match wins. Syntax: `<segment>[:<segment>...]:(rw|ro)`.

- `*:rw` / `*:ro` are top-level wildcards.
- Mid-tree wildcards: `firewall:*:ro` permits ro on every firewall
  subresource but NOT the bare domain. `*:rules:ro` permits ro on the
  `rules` subresource of every domain. At the same depth, an exact segment
  beats a wildcard segment.
- `rw` implies `ro`; granting `firewall:rw` does NOT also require granting
  `firewall:ro`.
- Same-depth conflict (`firewall:rules:rw` + `firewall:rules:ro`):
  `rw` wins.
- No matching scope → deny.

### Scope examples

| Caller scopes                | Allowed                                          | Denied                                       |
|------------------------------|--------------------------------------------------|----------------------------------------------|
| `*:rw`                       | every endpoint                                    | nothing                                      |
| `*:ro`                       | every GET                                         | every write                                  |
| `firewall:rw`                | every firewall endpoint (zones/rules/redirects)   | `network/*`, `dhcp/*`, `system`              |
| `firewall:rules:rw`          | `firewall/rules` CRUD                             | `firewall/zones`, `firewall/redirects`       |
| `firewall:*:ro`              | every GET under firewall subresources             | bare `firewall:rw`, `firewall/*` writes      |
| `firewall:rw` + `network:ro` | firewall CRUD + network read                      | network writes                               |
| `raw:firewall:rw` + `firewall:ro` | none of `/raw/firewall/...` writes (raw needs BOTH) | nothing escalated                            |
| `uapi:tokens:rw`             | mint new tokens whose scopes ⊆ caller's           | mint tokens that escalate                    |

### Audit consequence

The token *name* is logged on every audit line. Tokens should be named for
their owner (`ci-bot`, `terraform-prod`, `alice-laptop`) so the audit log
identifies the responsible party, not a hash.

## Authentication-design exclusions

uapi defends the surface above with bearer tokens deliberately, not by accident. Two design candidates that would seem natural but are explicitly rejected:

- **No rpcd sessions.** The OpenWrt rpcd session model (login endpoint returning a session id, session expiry, ubus `session.*` namespace) is well-trodden by LuCI but adds a runtime store, session-eviction machinery, and a separate failure mode for "session expired vs token revoked." uapi's bearer-token model is simpler at the cost of forcing the operator to mint tokens out of band.
- **No HTTP login endpoint.** Tokens are minted via the `uapi-token` CLI on the router or via `POST /tokens` (which itself requires a token with `uapi:tokens:rw`). There is no bootstrap "POST /login with username+password to get a token" path. The first token is always minted locally; everything after composes from that.

Both could be added without breaking the wire surface (new endpoints are non-breaking). The deliberate exclusion is to keep the security model auditable as "the set of tokens in `/etc/config/uapi`" with no second authentication path to reason about.

## Public endpoints

Three endpoints skip the bearer-token requirement:

- `GET /healthz`: liveness probe; minimal info.
- `GET /openapi.json`: spec discovery.
- `GET /schema/*`: per-resource JSON Schema (codegen input).

All three still pass the TLS check; only the bearer requirement is waived. Plain HTTP from a non-loopback source still returns `403 tls_required` before the public-endpoint short-circuit runs.

## TLS posture

- `uhttpd` serves both HTTP and HTTPS. `tls_check()` permits HTTP only
  when the request is loopback (`127.0.0.1` / `::1` / `::ffff:127.0.0.1`)
  OR the marker file `/etc/uapi.insecure` exists.
- The default uhttpd self-signed cert is NOT adequate for production.
  Operators should provision a real cert via `acme.sh` /
  `luci-app-acme` (`docs/installation.md` covers this).
- mutual TLS (mTLS) via `tls_client_cert_file` /
  `tls_require_client_cert` is supported as a defense-in-depth layer on
  top of bearer auth - see `docs/installation.md`.
- The `/etc/uapi.insecure` marker is for closed-network testing only.
  Every request that bypasses TLS via the marker emits a NOTICE-level
  `uapi-insecure-bypass <request_id> <method> <path> status=<n> remote=<addr>`
  syslog line. Monitor for this in production to detect drift.

## Token storage

`/etc/config/uapi` token sections:

```
config token 'ci_bot'
    option salt 'a1b2c3d4...'
    option hash 'e5f6...sha256-of-salt-colon-token'
    list scopes '*:rw'
    option expires_at '1733000000'             # optional
    list allowed_cidrs '10.0.0.0/8'             # optional
    option last_used_at '1732999900'            # tracked
    option last_used_ip '10.0.0.42'             # tracked
```

- Cleartext token is shown exactly once at creation (`uapi-token create`
  CLI or `POST /tokens` HTTP). Never logged.
- Salt is 64 random bits (16 hex chars); hash is `sha256(salt || ":" || token)`.
- `/etc/config/uapi` is a conffile, preserved across upgrades and
  removal.
- last-used tracking is throttled to ~1 write/minute per token via a tmpfs
  sentinel (`/var/run/uapi-token-update/<token-id>`); the wire response
  never depends on the audit write.

The `salt`+`hash` design defends against an offline attacker who reads the
token store. The hash + 16-char salt makes any pre-computed rainbow attack
useless and forces a per-token bruteforce; the token's own 128 bits make
that intractable.

## Rate limit guarantees (and non-guarantees)

- The token bucket is per-token, file-backed at `/tmp/uapi-ratelimit/`.
- Under heavy concurrent load against the same token, two forks may race
  the read-modify-write and one increment may be lost. The worst case is
  one request's worth of bucket drift, bounded by the burst size.
- The rate limit is **not a security control on its own** - it's an
  abuse-mitigation guardrail. A patient attacker can stay under the
  threshold and grind through the API at the steady-state rate. Use
  `allowed_cidrs` (deny by IP) for actual access control.

## Audit shape

One syslog line per write at NOTICE:

```
uapi <request_id> <token_name> AUDIT - <method> <path> <status> [<duration_ms>ms]
```

One syslog line per 401/403/5xx at WARNING/ERROR:

```
uapi <request_id> <token_name|-> WARN <code> <method> <path> <status> [<duration_ms>ms]
uapi <request_id> -             ERROR <code> <method> <path> <status> [<duration_ms>ms]
```

One syslog line per insecure-bypass request at NOTICE:

```
uapi-insecure-bypass <request_id> <method> <path> status=<n> remote=<addr>
```

### Recommendations for hardened deployments

1. **Configure persistent syslog** (`log_file` in `/etc/config/system`).
   The default ringbuffer is volatile.
2. **Forward syslog to a remote collector** (`log_ip`). A locally-only
   audit log is destroyable by anyone who roots the box.
3. **Use NTP.** Audit timestamps are useless if the clock is wrong.
   `/healthz` checks `time_sync: ok` / `degraded` based on uptime > 60s
   AND current epoch > 1700000000 (a sanity floor).
4. **Pin tokens to source CIDRs.** `allowed_cidrs` defends against token
   theft from outside the management network.
5. **Set token expiry.** `expires_in: 90d` on every minted token forces
   rotation. The HTTP rotation endpoint (`POST /tokens`) makes this
   ergonomic from automation.
6. **Use mutual TLS** for service-account workloads (CI, Terraform). It's
   an independent factor on top of bearer auth and prevents a stolen
   bearer from being replayed without the cert.

## What lands in syslog

The audit lines above. The standard error envelope's `message` field is
human-readable English and may name specific failing fields (`"src_zone is
required"`) - never sensitive values.

Specifically NOT logged:
- Cleartext token values.
- Cleartext passwords (the `system/password` endpoint audit-logs the user
  name and request id, never the password).
- TLS certificate or key material.

## Reporting issues

Security issues should not be filed as public GitHub issues. See the project
README for the disclosure path.
