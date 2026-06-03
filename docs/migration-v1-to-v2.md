# Migrating from uapi v1 to v2

v2 is a single, deliberate breaking release. The cost is paid once; the
payoff is a wire surface that is consistent (snake_case across the board),
strictly typed (real JSON integers everywhere), and significantly larger
(rate limit, metrics, idempotency, batch, JSON Patch, dependency-aware
ETags, token expiry / IP scoping / HTTP rotation, conditional GET,
diagnostics).

A given uapi installation now serves exactly one API major - there is no
parallel `/api/v1/` and `/api/v2/` mount in the same binary. Operators who
need to keep a v1 client working keep the `1.2.1` package installed. The
1.2.1 APK is preserved indefinitely on the gh-pages feed; the signed
`v1.2.1` git tag is the canonical v1 contract document.

**The URL prefix changes from `/api/v1/` to `/api/v2/`.** Update every
client-side base URL accordingly. The install hook on a fresh `apk add
uapi` over v1.2.x automatically removes the v1 prefix from uhttpd's
`ucode_prefix` list and adds the v2 one.

## Upgrade path

1. **Read this document end-to-end before installing v2.** Specifically the
   "Field renames", "Strict integer typing", and "Strictness sweep" sections -
   those break the wire.
2. Update your client code (Terraform provider, scripts, dashboards) to the
   v2 expectations. Test against a staging router.
3. `apk upgrade uapi`. The install hook will `uhttpd reload` automatically;
   existing tokens in `/etc/config/uapi` are preserved (the file is a conffile).
4. Verify `GET /api/v2/healthz` returns `{"status":"ok", "version":"2.0.0", ...}`.
   The new URL prefix is `/api/v2/`; the install hook handles the uhttpd
   prefix migration. v1 clients hitting `/api/v1/` get a 404 from uhttpd
   because the old prefix is no longer registered (this is intentional - the
   wire contract changed; the URL should not silently lie about that).

If anything looks wrong in production, `apk downgrade uapi=1.2.1` restores v1
behavior (the v1.2.1 APK stays available on the feed for this exact reason).

## Field renames (Breaking)

The v1.x curated layer accumulated 16 fields in three resources that used
upstream uci's casing instead of snake_case. v2 fixes them.

### `dropbear/instances`

| v1 field           | v2 field             |
|--------------------|----------------------|
| `Port`             | `port`               |
| `PasswordAuth`     | `password_auth`      |
| `RootPasswordAuth` | `root_password_auth` |
| `RootLogin`        | `root_login`         |
| `BannerFile`       | `banner_file`        |
| `Interface`        | `interface`          |
| `GatewayPorts`     | `gateway_ports`      |

### `snmpd/system`

| v1 field        | v2 field         |
|-----------------|------------------|
| `sysLocation`   | `sys_location`   |
| `sysContact`    | `sys_contact`    |
| `sysName`       | `sys_name`       |
| `sysServices`   | `sys_services`   |
| `sysDescr`      | `sys_descr`      |
| `sysObjectID`   | `sys_object_id`  |

### `vnstat/config`

| v1 field               | v2 field                  |
|------------------------|---------------------------|
| `DatabaseDir`          | `database_dir`            |
| `Interface5MinHours`   | `interface_5min_hours`    |
| `MonthRotate`          | `month_rotate`            |

On disk, the uci keys are unchanged (`Port`, `sysLocation`, etc.). The rename
is purely on the wire: `fromUci` exposes snake_case; `toUci` translates back
to the upstream uci key.

### `dhcp/servers` runtime block

| v1 field                          | v2 field                              |
|-----------------------------------|---------------------------------------|
| `runtime.active_leases_v4_total`  | `runtime.active_leases_v4_box_total`  |

The counter is box-wide, not per-server: dnsmasq's `/tmp/dhcp.leases` does
not tag entries by interface, so every dhcp/servers section's runtime block
reports the same total. The new name says so explicitly. The IPv6 counter
(`active_leases_v6_iface`) is genuinely per-interface and was unaffected.

## Strict integer typing (Breaking)

v1.x silently accepted string-form integers (`"42"`) for fields declared
`type: "integer"`. The toUci layer happily stringified them again on the way
back to uci, but the type check was a lie: a client that sent `"forty-two"`
would also be accepted, with `int("forty-two") = 0` silently dropped into
uci. v2 closes the trap.

| Layer | v1 behavior                                         | v2 behavior                                 |
|-------|------------------------------------------------------|---------------------------------------------|
| Wire  | `"42"` accepted; `42` accepted; `"forty-two"` accepted (silently → 0) | only real integers `42` accepted; everything else → `422 validation_failed` |
| `fromUci` | `int(s)` (returns 0 on garbage)                 | `values.as_int(s)` (returns `null` on garbage; surfaces real ints as JSON numbers) |
| `toUci`   | `"" + n` for any value                           | `"" + n` only for validated integers        |

This affects every field declared with `type: "integer"` in v2's
`schema_properties` - at v2 launch this is ~80 fields across ~20 resources.
The most common-to-touch ones:

- `network/routes`: `metric`, `mtu`, `table`
- `dropbear/instances`: `port`
- `dhcp/servers`: `start`, `limit` (`leasetime` stays a duration string;
  port specs like `firewall/rules.match.dest_port[]` also stay strings to
  preserve range syntax `"22-25"` - check `/schema/<pkg>/<res>` for the
  authoritative type per field)
- `system`: `log_size`, `log_remote_port`

Run your client through a staging router and capture any 422 responses on
PATCH/PUT to find the call sites that need updating.

## Strictness sweep (Breaking, mechanical)

Some v1.x fields had no `schema_properties` entry at all and reached `toUci`
unfiltered. v2's completeness sweep added typed entries for every
fromUci-surfaced field. Bodies that previously slipped past the type check
(silent drops) now return `422 validation_failed`.

If you have wire traffic that was relying on a field being silently dropped
(unlikely but possible), the 422 will tell you which field. The fix is to
either remove the field from the payload or correct its type.

## New endpoints

| Endpoint                          | Scope                        | Notes                                     |
|-----------------------------------|------------------------------|-------------------------------------------|
| `GET /healthz` (extended body)    | (public)                     | Now includes `checks: { ubus, uci, ... }` |
| `GET /schema`                     | (public)                     | Lists all resources                       |
| `GET /schema/<package>`           | (public)                     | Schemas for one package                   |
| `GET /schema/<package>/<res>`     | (public)                     | One resource's `schema_properties`        |
| `GET /auth/whoami`                | (any authed token)           | Current token metadata                    |
| `GET /tokens`                     | `uapi:tokens:ro` / `*:ro`    | List tokens (no secrets surfaced)         |
| `GET /tokens/<id>`                | `uapi:tokens:ro` / `*:ro`    | One token's metadata                      |
| `POST /tokens`                    | `uapi:tokens:rw` / `*:rw`    | Mint a new bearer (returns cleartext once)|
| `DELETE /tokens/<id>`             | `uapi:tokens:rw` / `*:rw`    | Revoke                                    |
| `GET /metrics`                    | `uapi:metrics:ro` / `*:ro`   | Prometheus text                           |
| `GET /diagnostics`                | `uapi:diagnostics:ro` / `*:rw`| Version + lock state + recent errors      |
| `POST /batch`                     | each sub-request scope-checked| Multi-package all-or-nothing              |

## New headers

- **Requests recognized:** `X-Request-Id` (or `?request_id=`),
  `If-None-Match` (or `?if_none_match=`),
  `Idempotency-Key` (or `?idempotency_key=`),
  `Content-Type: application/json-patch+json` (PATCH only, selects RFC 6902).
- **Responses emitted:** `Link: <...>; rel="next"`, `X-Next-Cursor`,
  `WWW-Authenticate: Bearer realm="uapi"` (on 401), `Retry-After` (on 429),
  `Idempotent-Replayed: true` (on idempotency cache hits).

## New error codes

| HTTP | code                          | When                                            |
|------|-------------------------------|-------------------------------------------------|
| 400  | `invalid_cursor`              | malformed `?cursor=`                            |
| 403  | `scope_escalation_blocked`    | `POST /tokens` requested scopes beyond caller's |
| 409  | `idempotency_key_conflict`    | same key, different body                        |
| 429  | `too_many_requests`           | rate limit (default 100/s burst 200)            |
| 4xx  | `batch_partial_failure` (body)| `/batch` aborted; whole batch reverted          |

Clients should already branch on HTTP status and treat unknown `code` values
gracefully (per the v1 error envelope spec); new codes need no client work
unless you want specific UX.

## New scopes

`uapi`, `uapi:tokens`, `uapi:metrics`, `uapi:diagnostics`. Wildcard `*:rw`
continues to cover all of them; existing admin tokens require no change.

## Rate limit defaults

100 req/sec, burst 200, per-token. Returns `429 too_many_requests` with
`Retry-After`. Operators expecting more traffic add:

```
config ratelimit
    option rate '500'
    option burst '1000'
```

to `/etc/config/uapi`. No reload needed - the config is read on every authed
request.

## Token expiry, IP scoping, and HTTP rotation

If you were rotating tokens via `uapi-token revoke` + `uapi-token create`,
you can now do it over HTTP:

```sh
curl -H "Authorization: Bearer $OLD" -X POST https://router/api/v2/tokens \
  -d '{ "name": "ci-rotated", "scopes": ["firewall:rw"], "expires_in_seconds": 86400 }'
# response: { "bearer": "<cleartext>", "name": "ci-rotated" }
```

The requested scopes must be a strict subset of the caller's. `expires_at`
(epoch seconds) and `allowed_cidrs` are optional extensions to the same
`uapi-token create` CLI.

After expiry the token returns `401 invalid_token` with
`message: "Token expired"`. Subsequent calls with a fresh bearer work
immediately - the token store is re-read on every request.

## Idempotency and conditional GET

Two safe additions for Terraform-style and dashboard-style clients:

- **POST retries are no longer dangerous.** Send `Idempotency-Key: <client-uuid>`
  with each POST; if the network blips and you retry the same payload, you
  get the original response back instead of a duplicate resource. uhttpd's
  CGI env strips the header by default, so pass `?idempotency_key=<id>` as
  fallback.
- **GET polling is cheaper.** Send `If-None-Match: "<previous-etag>"`; you'll
  get a `304 Not Modified` with no body when nothing changed. Same uhttpd
  fallback as If-Match: `?if_none_match=<etag>`.

## Dependency-aware ETags

A real change for cache-invalidation: the ETag on a `firewall/rules` GET now
mixes in a hash of every `firewall:zone` in the config. Changing a zone
invalidates the rule's ETag, so a Terraform refresh that uses If-Match for
optimistic concurrency now correctly notices cross-resource drift.

Declared dependencies at v2.0 launch:

- `firewall.rules`, `firewall.redirects`, `firewall.forwardings` → `firewall:zone`
- `sqm.queues`, `network.routes`, `dhcp.servers`, `network.wireguard_peers` → `network:interface`
- `network.bridge_vlans` → `network:device`

If your client was already correctly handling 412 on If-Match writes, this is
strictly more accurate - no behavior change required.

## Things that did NOT change

- The atomic-transaction recipe (snapshot → validate → commit → reload →
  restore on failure).
- The error envelope shape (`code`, `message`, `request_id`, optional `errors[]`).
- The bearer-token + scope-tree authn/authz model (scopes are additive; new
  ones added, no existing ones renamed or removed).
- The `/api/v2/` URL prefix.
- The fork-per-request CGI execution model.
- The "no daemon of our own" architectural principle.
