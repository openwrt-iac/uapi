# Operations

## "Success" means exit 0, not runtime convergence

A 2xx response to a write means: snapshot OK, validate OK, uci commit
OK, and the init script's reload action exited 0. It does NOT mean the
daemon has finished re-converging.

The most dangerous case is `network/interfaces`: a write that produces a
config netifd later rejects (bad proto, missing dep, conflicting
addresses) can drop the management connection. uapi only sees the init
script's exit code; netifd's runtime convergence happens after, in the
background.

Two signals worth wiring into your automation:

- **`X-Reload-Status`** response header on curated-resource writes: `ok` means the init
  script ran and exited 0; `no_reload` means the resource has no reload
  services. The header is intentionally not a "converged" promise.
  In practice you will only ever see `ok`: all 43 writable resources declare
  at least one reload service, so `no_reload` describes a resource shape that
  does not currently exist. `system` used to be cited here as the example and
  is not one, since it reloads `system` and `log`.
- **`X-Reload-Services`**: comma-separated list of init scripts that
  ran. Useful for audit/log correlation.

For high-stakes writes (the management interface, firewall defaults,
uhttpd itself) verify convergence out-of-band: poll the `runtime` block
on the resource you just modified, check ubus state, or simply ping the
box and confirm reachability. uapi cannot do this for you; the init
script doesn't know either.

A future `commit-confirmed` mode (apply, wait N seconds, auto-revert
unless client acks) would close the gap but conflicts with the
fork-per-request model. Tracked in `docs/roadmap.md` under "Needs more
reflection".

## NTP

Audit logs and request IDs both encode timestamps. If the router's clock is wrong, those timestamps are wrong, and correlating events across machines breaks.

OpenWrt ships an SNTP client (`sysntpd`) enabled by default. Confirm it is running and has synced:

```sh
/etc/init.d/sysntpd status
date
```

If the router has no internet during boot (or you ship a different time source), point sysntpd at it via `uci set system.ntp.server=...`.

## Persistent syslog

By default `logd` keeps the log ring in memory (default size 16 KiB) and loses it on reboot. For any router serving uapi in production, configure persistent logging:

```sh
uci set system.@system[0].log_file='/var/log/messages'
uci set system.@system[0].log_size='2048'      # KiB; tune to flash health
uci commit system
/etc/init.d/log restart
```

This writes the in-memory ring through to flash, surviving reboots. Mind flash wear: 2-4 MiB is typical; full-time access logging is not appropriate for flash without external storage.

For longer retention, mount a USB stick or remote filesystem and point `log_file` there.

## Forwarding audit logs off-box

uapi emits one syslog line per successful write under the `daemon.notice` priority. Forward to a central collector for tamper-resistant audit trails:

```sh
uci set system.@system[0].log_ip='10.0.0.5'        # syslog collector IP
uci set system.@system[0].log_port='514'
uci set system.@system[0].log_proto='udp'          # or 'tcp' for reliability
uci commit system
/etc/init.d/log restart
```

The receiving collector (rsyslog, syslog-ng, Loki, Splunk, etc.) can filter on the `uapi:` prefix to isolate API audit events.

## Log categories

| Category | syslog severity | Default | Triggers |
|----------|-----------------|---------|----------|
| AUDIT    | NOTICE          | on      | Successful writes (POST/PUT/DELETE 2xx) |
| ERROR    | WARN / ERR      | on      | Auth failures (401/403), all 5xx |
| ACCESS   | INFO            | off     | Every request (non-`/healthz`) |
| DEBUG    | DEBUG           | off     | Per-ubus-call tracing |

`/healthz` is excluded from all categories so monitoring traffic does not drown out the audit trail. Non-auth 4xx responses (404, 405, 409, 422, 423) are not logged: the client receives the error directly and there is no operator-actionable signal in volume.

ACCESS and DEBUG are opt-in via `/etc/config/uapi`:

```
config logging
    option access '0'
    option debug '0'
```

## Log line format

Plain text, fixed field order, syslog-native (chosen over JSON-per-line because `logread` is the primary consumer):

```
uapi: <request_id> <token_name|-> <severity> <code> <method> <path> <status> [<duration_ms>ms]
```

- `request_id`: ULID; also returned in the `X-Request-Id` response header. The link between server-side log and client-visible response.
- `token_name`: never the token value. `-` for unauthenticated failures (e.g. missing `Authorization`).
- `severity`: `AUDIT` (writes), `ACCESS` (every request, if enabled), `WARN` (401/403 auth failures), `ERROR` (5xx).
- `code`: error code on failures, `-` on successful writes.

`/healthz` is excluded from all categories so monitoring traffic does not drown out the audit trail. Non-auth 4xx responses (404, 405, 409, 422, 423) are not logged: the client receives the error directly and there is no operator-actionable signal in volume.

## Sample syslog output

```
# AUDIT: a successful POST that created a firewall rule
uapi[1234]: 01HX1234567890ABCDEFGHJKMN tf-prod AUDIT - POST /api/v3/firewall/rules 200 [42ms]

# ERROR (5xx)
uapi[1234]: 01HX234567890ABCDEFGHJKMNN tf-prod ERROR reload_failed_restored PUT /api/v3/network/interfaces/wan 500 [3120ms]

# WARN (auth failure)
uapi[1234]: 01HX34567890ABCDEFGHJKMNNN - WARN unauthorized GET /api/v3/system 401 [1ms]

# ACCESS (only when option access '1' is set)
uapi[1234]: 01HX4567890ABCDEFGHJKMNNNN tf-readonly ACCESS - GET /api/v3/firewall/rules 200 [8ms]

# DEBUG (only when option debug '1' is set; per ubus.call)
uapi[1234]: uapi-bus call system.info args={}

# Internal error from the top-level exception handler
uapi[1234]: uapi-internal 01HX567890ABCDEFGHJKMNNNNN: Type error: ...

# Insecure-bypass marker triggered
uapi[1234]: uapi-insecure-bypass 01HX67890ABCDEFGHJKMNNNNNN GET /api/v3/system status=200 remote=10.0.2.2
```

By default only AUDIT (successful writes) and ERROR/WARN (failures) are logged. Optional knobs in `/etc/config/uapi`:

```
config logging
    option access '1'   # log every request (INFO)
    option debug '1'    # per-ubus-call tracing (DEBUG)
```

Leave these off unless you're debugging. They are noisy and will fill the in-memory ring quickly.

## Metrics

`GET /api/v3/metrics` returns Prometheus 0.0.4 text. Scope: `uapi:metrics:ro`
(covered by `*:ro`). Counters and histograms are file-backed under
`/tmp/uapi-metrics/` (tmpfs - resets on reboot, which is fine for
operational counters; aggregate longer-term retention server-side).

Series:

| Series | Type | Labels |
|---|---|---|
| `uapi_requests_total` | counter | `method`, `path` (template, e.g. `/firewall/rules/:id`), `status`, `token_id` (`-` if pre-auth) |
| `uapi_request_duration_seconds_bucket` | histogram | `method`, `path`, `le` |
| `uapi_request_duration_seconds_count` | counter | `method`, `path` |
| `uapi_rate_limit_drops_total` | counter | `token_id` |
| `uapi_lock_contention_total` | counter | `lock_type` |
| `uapi_validate_errors_total` | counter | `resource`, `code` |

Path templates are normalized (`/firewall/rules/:id` not the concrete
ULID) to keep label cardinality bounded as clients create/destroy
resources. The `token_id` label is bounded by the operator-configured
token count (typically a small set); pre-auth failures (401 before
authorize completes) carry `token_id="-"` so the series row still
aggregates.

Sample Prometheus scrape config:

```yaml
scrape_configs:
  - job_name: uapi
    scrape_interval: 30s
    metrics_path: /api/v3/metrics
    scheme: https
    authorization:
      type: Bearer
      credentials: <metrics-token>
    static_configs:
      - targets: ['router.example.com']
```

For broader router-level metrics (load, memory, network counters), the
curated `prometheus_node_exporter_lua/config` resource manages
node_exporter's config separately.

## Rate limiting

Per-token token-bucket, file-backed at `/tmp/uapi-ratelimit/<token>.txt`.
Defaults: **100 req/s, burst 200** per token. Tune globally via
`/etc/config/uapi`:

```
config ratelimit
    option rate '500'
    option burst '1000'
```

No reload needed; the config is read on each authed request.

Per-token overrides win over global: `uci set uapi.<token>.rate='10'`,
`uci set uapi.<token>.burst='20'`. Useful for noisy CI tokens that
shouldn't share the global budget.

Exceeded rate returns `429 too_many_requests` with `Retry-After: <seconds>`.
The drop is counted in `uapi_rate_limit_drops_total{token_id}` for
operator visibility. Rate limit is a defense-in-depth abuse guard, not a
security control on its own; use `allowed_cidrs` on the token for actual
source-IP enforcement.

## Diagnostics

`GET /api/v3/diagnostics` returns version, uptime, loaded resources,
current lock holders, and the last 20 error envelopes emitted by the
parent uhttpd VM. Scope: `uapi:diagnostics:ro`.

```json
{
  "version": "2.0.0",
  "uptime_seconds": 123456,
  "resources_loaded": ["firewall:rules", "firewall:zones", "..."],
  "lock_state": {
    "global_held": false,
    "per_package": {}
  },
  "recent_errors": [
    { "ts": 1780510463, "request_id": "01HX...", "code": "validation_failed",
      "status": 422, "method": "POST", "path": "/api/v3/firewall/rules",
      "message": "Request body failed validation" }
  ],
  "request_id": "01HX..."
}
```

### Finding sections a write would reject (`?validate=1`)

`GET /api/v3/diagnostics?validate=1` adds a validation sweep: every section of
every resource the token may read is run through the same path a write takes, and
the ones that would be rejected are reported with the reason.

```json
{
  "invalid_sections": [
    { "resource": "firewall/rules", "id": "sweepbad", "managed": true,
      "errors": [ { "field": "match.proto", "code": "conflict",
                    "message": "firewall4 keeps a port match only on tcp or udp, so this rule would match the whole protocol instead" } ] }
  ],
  "swept_resources": ["firewall:defaults", "firewall:rules", "..."],
  "skipped_for_scope": []
}
```

It answers "which sections on this router will stop being accepted" before an
upgrade, rather than one `422` at a time during a write. Every section it reports
is already broken on the router: the rule above is already matching a whole
protocol rather than a port. The sweep is the first time anyone is told.

Three things worth knowing:

- **Opt-in on purpose.** Each resource walks its own uci package, so a package is
  traversed once per resource that lives in it, six times for `firewall` and
  `network`. The cost therefore scales with the number of sections in the
  configuration, not with a fixed overhead: 45 resources over a stock-sized
  configuration measured about 90 ms, and a router with a large firewall will be
  slower. `/diagnostics` is what a monitoring system polls on an interval, so
  without `?validate=1` the response is unchanged and costs nothing extra.
- **Scoped per resource.** The endpoint needs `uapi:diagnostics:ro`, and each
  resource is included only if the token also permits `:ro` on it, because the
  findings name sections and quote configured values. A token with only
  `uapi:diagnostics:ro` therefore sweeps nothing, which is why
  `skipped_for_scope` exists: an empty `invalid_sections` with a long
  `skipped_for_scope` means "not allowed to look", not "nothing wrong".
- **Read-only and side-effect free**, so it is safe to run against production,
  which is exactly when it is most wanted.

One finding shape differs. If a resource's sweep itself fails, the entry reports
`code: "sweep_failed"` with `id` and `managed` both `null`, because there is no
section to name:

```json
{ "resource": "firewall/rules", "id": null, "managed": null,
  "errors": [ { "field": "", "code": "sweep_failed", "message": "..." } ] }
```

That is deliberately a finding rather than a failed request: a resource that could
not be checked must not be reported as clean.

`dhcp/leases` and `dhcp/leases6` are not swept. They are read-only views of
daemon state with no validation to run.

The `recent_errors` ring is best-effort: writes to `/tmp/uapi-error-ring/`
must never disrupt the actual response, so a disk-full or permission
failure simply produces an empty ring rather than a 5xx on the original
request. The ring caps at 20 entries (oldest dropped first).

Useful for "is anything stuck holding the global lock?" - a non-empty
`per_package` map under steady state would point at a wedged write
transaction.

## Management-path warning

The lockout this guards against is the one atomic writes cannot help with: a change that
reloads cleanly and then severs the only path to the box. uapi warns rather than refuses,
because renumbering the management VLAN or moving to an out-of-band path are legitimate
things to do, and because LuCI warns rather than blocking on the same condition.

Two places report it, and they answer different questions.

`GET /diagnostics` carries `management_path`, which names the interface this request
arrived through:

```json
{ "management_path": { "address": "192.168.0.236", "device": "eth1", "interface": "wan" } }
```

That is the pre-flight answer. Ask it before a risky write, or have a wrapper ask it, and
you know which interface not to touch. `interface` is `null` when the request arrives on a
device no uci interface claims, which is honest rather than a guess.

A write to `network/interfaces` gets `X-Mgmt-Path-Warning` when it moves that interface's
`disabled`, `proto`, `ipaddr`, `ipaddrs` or `netmask`, or deletes it. That is the after-the-fact
answer, and it is worth having because most such writes do not actually break the path:
the header tells an operator they are in a risky state while the connection still works.

Its limit, stated plainly: if the write really does strand you, the response never
arrives. This is not a safety net, it is a warning light. The scope is deliberately
LuCI's: those four field names on the inbound interface, and no firewall analysis at all,
because predicting a firewall lockout means modelling fw4 zone and rule ordering, and a
guess dressed as a warning is worse than silence.

The interface is derived from the kernel's own route lookup rather than by comparing the
caller's address against each interface's configured prefixes. An operator reaching the
box from another network sits inside no local prefix, and that is exactly the operator a
write can strand, so containment arithmetic would report "unknown" for the case that
matters most. The route lookup also answers for IPv6, where uapi's own prefix helpers are
IPv4-only.

## Healthz

```sh
curl -k https://<router>/api/v3/healthz
# 200 with body:
# { "status": "ok", "version": "2.0.0",
#   "checks": { "ubus": "ok", "uci": "ok",
#               "lock_dir": "ok", "time_sync": "ok" } }
# 503 with body:
# { "status": "degraded", "version": "...", "checks": {...},
#   "errors": ["ubus: ...", "time_sync: clock not synced (epoch below sanity floor)"] }
```

No auth required; TLS-for-non-localhost still applies. Monitors should
poll healthz (not a real endpoint) to avoid burning audit-log noise.
`time_sync` returns `unknown` for the first 60 seconds after boot
(uptime too short to tell), `degraded` if the wall clock is below 2023,
otherwise `ok`.

### `version` is a stable contract field

The `version` field returned by `/healthz` is the canonical
version-skew probe. It carries the installed uapi package version (same
string as `/usr/share/uapi/VERSION`) and is guaranteed to be present
across every release within and across majors. Clients that need to
detect API-skew before issuing real requests should read it from
`/healthz` rather than parsing it from the URL or assuming it from the
package they installed.

## Insecure-test bypass

For closed-network testing only, creating `/etc/uapi.insecure` lets plain HTTP through from any client (the loopback bypass is always available; this opens it for remote hosts too). Every request that takes the bypass emits a syslog `NOTICE` line:

```
uapi-insecure-bypass <request_id> <method> <path> status=<n> remote=<addr>
```

so it shows up in `logread` and any remote-syslog collector. Delete the marker for production use.

## Capacity

uapi runs in-process inside uhttpd via uhttpd-mod-ucode. Each request is a forked CGI child. On low-end MIPS hardware, fork+ucode+ubus is in the tens of milliseconds per request; on modern aarch64/x86_64 it is sub-10ms. The intended workload is Terraform applies plus occasional curl, not high-volume RPC. If you need RPS in the hundreds, front uapi with a caching reverse proxy.

## Backups

The token store at `/etc/config/uapi` is the only uapi-specific state worth backing up beyond what you'd back up for OpenWrt itself (`sysupgrade --create-backup`). Treat it as a secret. The tokens within are hashed (so a leaked backup file doesn't directly expose bearers), but the salts + hashes still allow an offline brute-force on weak inputs; in practice the bearers are 128 random bits so brute force is infeasible, but discipline still wins.
