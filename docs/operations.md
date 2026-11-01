# Operations

## "Success" means exit 0, not runtime convergence

A 2xx response to a write means: validate OK, and, when the write changed
uci, uci commit OK and the init script's reload action exited 0. A write
that changed nothing commits and reloads nothing, and says so with
`X-Reload-Status: no_reload`. It does NOT mean the daemon has finished
re-converging.

The most dangerous case is `network/interfaces`: a write that produces a
config netifd later rejects (bad proto, missing dep, conflicting
addresses) can drop the management connection. uapi only sees the init
script's exit code; netifd's runtime convergence happens after, in the
background.

Two signals worth wiring into your automation:

- **`X-Reload-Status`** response header on curated-resource writes: `ok` means the init
  script ran and exited 0, and `no_reload` means that no init script ran. The header is
  intentionally not a "converged" promise. Each writable resource outside `dhcp` has
  a reload service that it always runs, so there `no_reload` means that the write changed
  nothing in uci, such as a PATCH that names no field, or a PUT or a PATCH that sends the values that uci holds.
  A write that commits nothing reloads nothing, since 3.2.0 for a PATCH and since 3.3.0 for a PUT. A `dhcp` write reloads
  dnsmasq, odhcpd and unbound only while procd runs them, so it also answers `no_reload`
  when none of them runs. As for a LuCI save, procd runs such a daemon while it holds a
  config trigger for it, from the start of the service to its stop, whatever the instances
  show, so a write also starts again a daemon that crashed too often. At boot, unbound holds
  no such trigger until 3 s after the last interface event, and a write leaves it as it is.
  `unverified` means that the write kept its commit and that whether its
  daemons take the new config is unknown: an init script was still running
  when uapi stopped waiting for it, or the `dnsmasq --test` check after a
  dhcp write did not finish, see below.
- **`X-Reload-Services`**: comma-separated list of init scripts that
  ran. Useful for audit/log correlation.

unbound and dnsmasq are the exceptions. When unbound runs, a write that
reloads `unbound` or `unbound-uci-ext` waits 2 s for each unbound instance to
keep running. A write to `dhcp/servers`, `dhcp/hosts`, `dhcp/dnsmasq`,
`dhcp/odhcpd`, `system` or the raw `dhcp` and `system` packages reloads
`unbound` while procd runs it, and waits the 2 s too when unbound ran before
the write. While `/etc/init.d/unbound` exists, each of these writes also
takes the lock of `unbound` before it asks procd, whether unbound runs or
not, so a write to `unbound/server`, `unbound/srv` or `unbound/ext`, or
another of these writes, at the same moment answers `423 locked`. A network
or wireless write reloads no unbound and takes no such lock. If an
instance stops, the write answers `500 reload_failed_restored`, and its
`reload_error` reads `unbound stopped after the reload, with exit code 1`. So a
2xx on these writes also means that procd did not report unbound as stopped in
the 2 s after the reload. An instance that `service list` does not show,
because something restarts it or the ubus call fails, does not count, and a
daemon that stops later than 2 s still answers 2xx.

dnsmasq is checked by its config. A write to `dhcp/servers`, `dhcp/hosts`,
`dhcp/dnsmasq`, `dhcp/odhcpd`, the raw `dhcp` package, or a `/batch` that
commits `dhcp`, reloads `dnsmasq` while procd runs it, and then uapi runs the
command of each dnsmasq instance with `--test` on the config that dnsmasq.init
just wrote. If dnsmasq refuses it, the write answers
`500 reload_failed_restored`, and its `reload_error` reads, for example,
`dnsmasq refuses its config cfg01411c: bad IP address at line 33 of /var/etc/dnsmasq.conf.cfg01411c`.
The check covers every instance, one that is not running included, since
procd starts it on that config. So on a router whose dnsmasq config was
refused before the write, a write that does not fix it answers
`500 reload_failed_unrecovered`. A `--test` that cannot run, because fork
fails, fails the write in the same way. A `--test` that does not finish within
10 s is killed, and judges nothing: the write keeps its commit and answers 2xx
with `X-Reload-Status: unverified`, and a raw write a `reload_note`. uapi cannot
tell the time bound from another `SIGKILL`, such as the OOM killer's, so both
read the same. A `conf-file` on a mount that hangs therefore holds the locks
for 10 s per instance, where it held them until uhttpd killed the request with
no answer. A parse of a `conf-dir` with 500k `address=/x/` lines took 0.6 s on
x86. A target that takes longer than 10 s to parse its config, such as a slow
MIPS router with large adblock lists, answers `unverified` on every dhcp write,
and dnsmasq itself is not affected. `--test` parses the config and the files of
`conf-file` and `conf-dir`, and exits. It does not read the files of
`addn-hosts` and `servers-file`, which dnsmasq reads after it starts. A config
that dnsmasq parses but cannot start with, such as `min-port` above
`max-port`, a `dhcp-leasefile` in a missing directory or a port that another
daemon holds, still answers 2xx. No write waits for the daemon to start. Each
write pays one parse of the whole config per instance, which grows with its
size, such as a `conf-dir` of adblock lists, and pays it again on a restore.
A write to `system`, `system/timeservers` or the raw `system` package reloads
dnsmasq too, for the hostname and NTP, but runs no check: a config that dnsmasq
refused before, or a slow parse, must not fail or undo a hostname or NTP
change.
OpenWrt's reload of dnsmasq can restart the daemon, which on a slow machine can
leave it stopped for 5 s, and uapi does not report that restart.

uapi runs the reloads of a write in order and waits for them for 20 s in all,
those of a restore included. A system write reloads up to five services, and
the 20 s cover them all. uapi does not kill a reload that runs longer: it
answers without it, the write keeps its commit and answers 2xx with
`X-Reload-Status: unverified`, and a raw write a `reload_note` such as
`firewall reload was still running when the 20 s that uapi waits for the
reloads of a request ran out, so its result is unknown, and the reloads of
dnsmasq, odhcpd follow it unless it fails`. A `system/cron_jobs` write answers
the header too, and logs the note to syslog as `uapi-cron-reload-unverified`.
The reloads after the one still running start when it ends, unless it fails,
and uapi does not learn how they end, so check the daemon. No stay-up watch or
`dnsmasq --test` check runs after such a reload. Before 3.3.0, uhttpd killed a
request whose reload did not end at its 60 s script timeout and answered 502,
and uci kept the new config with no restore. Killing the reload at a bound does
not help: rc.common's `procd_lock` keeps the lock of the service in the
children of the script, such as fw4, so the next reload of that service waits
until they end. A reload that exits with a code other than 0 within the 20 s
fails the write and restores, as before. A reload that takes longer and then
fails answers 2xx `unverified`, and the failure shows only in the daemon. The
restore gets what is left of the 20 s, so a reload that fails after more than
about 10 s can leave too little time for the reloads of the restore, and the
write then answers `500 reload_failed_unrecovered`. uapi waits for the script
alone, so a process that the script starts and leaves running no longer holds
the write. The lock of the write is released when uapi answers, so the next
write can commit and reload while such a reload still runs. Its reload of the
same service waits for the lock of `procd_lock` within its own 20 s. If the
writes to one service answer `unverified` again and again, a reload of that
service does not end: look for its blocked init script with `ps`.

A write to one package that fails and restores takes at most 20 s of reloads,
2 s of the unbound watch and 10 s of `dnsmasq --test` per dnsmasq instance
after the reloads of the write and again after those of the restore, and up to
5 s of the restore waiting for libuci's flock: 49 s with one dnsmasq instance,
inside uhttpd's default `script_timeout` of 60 s. A `POST /batch` restore adds
up to 5 s of flock wait for each further package that it writes back, and the
`wg set` of a kernel apply or reconcile has no time bound. uapi does not read
`script_timeout`. Set it lower, through `uhttpd/instances` or otherwise, and
uhttpd can kill such a request before its restore or its answer: the client
gets a 502, and uci keeps whatever the write had reached. Keep it at 60 s or
above on a router that uapi manages.

A LuCI save or a `uci commit` in a shell takes no uapi lock, so it can commit
to the package while uapi reloads its daemons. When that reload then fails,
the file holds both writes, and the restore would undo the other one too. uapi
leaves the package as that writer left it, reloads nothing for it, and answers
`500 reload_failed_unrecovered`, whose `restore_error` names the package. The
daemon keeps what the failed reload gave it, so check the package and reload
it by hand. In a `POST /batch`, the other packages are restored, and the
services of the packages that the restore wrote back are reloaded. A daemon
that also reads the package that it left is reloaded through them and reads
that package as it is: in a batch of `system` and `dhcp` whose `dhcp` it left,
dnsmasq, odhcpd and unbound reload through `system`.

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
| AUDIT    | NOTICE          | on      | Successful writes (POST/PUT/PATCH/DELETE 2xx) |
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
- `path`: uhttpd's `PATH_INFO`, so the `/api/v3` mount prefix is already stripped. A client's `POST /api/v3/firewall/rules` logs as `/firewall/rules`.

`/healthz` is excluded from all categories so monitoring traffic does not drown out the audit trail. Non-auth 4xx responses (404, 405, 409, 422, 423) are not logged: the client receives the error directly and there is no operator-actionable signal in volume.

## Sample syslog output

```
# AUDIT: a successful POST that created a firewall rule
uapi[1234]: 01HX1234567890ABCDEFGHJKMN tf-prod AUDIT - POST /firewall/rules 200 [42ms]

# ERROR (5xx)
uapi[1234]: 01HX234567890ABCDEFGHJKMNN tf-prod ERROR reload_failed_restored PUT /network/interfaces/wan 500 [3120ms]

# WARN (auth failure)
uapi[1234]: 01HX34567890ABCDEFGHJKMNNN - WARN unauthorized GET /system 401 [1ms]

# ACCESS (only when option access '1' is set)
uapi[1234]: 01HX4567890ABCDEFGHJKMNNNN tf-readonly ACCESS - GET /firewall/rules 200 [8ms]

# DEBUG (only when option debug '1' is set; per ubus.call)
uapi[1234]: uapi-bus call system.info args={}

# Internal error from the top-level exception handler
uapi[1234]: uapi-internal 01HX567890ABCDEFGHJKMNNNNN: Type error: ...

# Insecure-bypass marker triggered
uapi[1234]: uapi-insecure-bypass 01HX67890ABCDEFGHJKMNNNNNN GET /system status=200 remote=10.0.2.2

# A request body that missed the read deadline
uapi[1234]: uapi-body-deadline 01HX7890ABCDEFGHJKMNNNNNNN POST /firewall/rules status=400 remote=10.0.2.2
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
`/var/run/uapi-metrics/` (tmpfs - resets on reboot, which is fine for
operational counters; aggregate longer-term retention server-side).
A package install or upgrade resets them too, and Prometheus reads that
as a counter reset.

Series:

| Series | Type | Labels |
|---|---|---|
| `uapi_requests_total` | counter | `method`, `path` (template, e.g. `/firewall/rules/:id`, or `unmatched`), `status`, `token_id` (`-` if pre-auth, `-retired` for tokens that no longer authenticate) |
| `uapi_request_duration_seconds_bucket` | histogram | `method`, `path`, `le` |
| `uapi_request_duration_seconds_count` | counter | `method`, `path` |
| `uapi_rate_limit_drops_total` | counter | `token_id` (`-retired` as above) |
| `uapi_lock_contention_total` | counter | `lock_type` |
| `uapi_validate_errors_total` | counter | `resource`, `code` |

Path templates are normalized (`/firewall/rules/:id` not the concrete
ULID) to keep label cardinality bounded as clients create/destroy
resources. A path that no route serves records `path="unmatched"`, and a
`/raw` path keeps its package only when `/etc/config` holds it. Pre-auth
failures (401 before authorize completes) carry `token_id="-"` so the
series row still aggregates. A counter file that holds no count, which a
full `/tmp` could leave behind, is left out of a scrape and starts again
at its next increment.

The `token_id` label is not bounded by the operator, because a client can
mint a token per run, as the Terraform provider's ephemeral `uapi_token`
does. A mint and a revoke bound it, over HTTP and with `uapi-token`, under
the lock of the `uapi` package. Each one folds every series of a token
that no longer authenticates (revoked, expired, or deleted from
`/etc/config/uapi` by hand) into the series with the same other labels and
`token_id="-retired"`, which no token can be named. The count is added
there, and the token's file is deleted once the added count is on disk. A
mint, over HTTP and with `uapi-token create`, folds before its commit, so
that a request that uhttpd kills during the fold cannot lose the bearer of a
token that it committed. A revoke folds after its commit. The values of
`token_id` are then the tokens that still authenticated at the last mint or
revoke, `-` and `-retired`, and two kinds that the next mint or revoke
folds: a token that revoked itself, as its revoke is recorded after the
fold, and a token with a request in flight at its revoke. A client that
mints tokens with no expiry and never revokes them keeps every one of them
live, and nothing bounds those.

What a scrape sees at a fold: the token's series is gone, and the
`-retired` series of the same method, path and status has grown by the
token's count. Folds run one at a time under the lock, so none of them
loses an update of `-retired`. A sum over `token_id`, such as
`sum without (token_id) (uapi_requests_total)`, keeps its value across a
fold, with three exceptions:

- A scrape that overlaps a fold can count the token twice, or leave it
  out, and a recording rule that sums before `rate()` reads the second
  case as a counter reset.
- A request of the token that is in flight at its revoke can write the
  token's series again after the fold, and the next fold adds that count
  again, so it is counted twice.
- A kill between the add and the delete counts the token twice at the
  next fold in the same way.

The requests of a token that a scrape saw once or never, which is usual
for a token per run, reach Prometheus through `-retired`, but only once
that series exists. The first fold into a label set creates the `-retired`
series at the token's count, and `rate()` does not count the first value
of a series, so those requests show only in the sum. The cost is with
`rate()`: it reads each later fold as requests at the moment of the fold,
so `sum(rate(uapi_requests_total[5m]))` shows a spike after a mint or a
revoke, and counts a second time the part of a token's requests that its
own series already showed. For a long-lived token that is revoked, that is
most of its history at once. Deleting the series instead would have kept
the requests of a short-lived token out of `rate()`, and made each sum
fall at a revoke, which a recording rule that sums before `rate()` reads
as a counter reset.

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

Per-token token-bucket, file-backed at `/var/run/uapi-ratelimit/<token>.txt`.
A token whose name is longer than 63 characters, which only `uapi-token`
can create, has its bucket under the sha256 of its name instead.
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
the uapi lock files present under `/var/lock`, whether uapi uses each
state directory under `/var/run`, and the last 20 error envelopes. Scope:
`uapi:diagnostics:ro`.

```json
{
  "version": "2.0.0",
  "uptime_seconds": 123456,
  "resources_loaded": ["firewall:rules", "firewall:zones", "..."],
  "lock_state": {
    "global_held": false,
    "per_package": {}
  },
  "state_dirs": {
    "/var/run/uapi-error-ring": true,
    "/var/run/uapi-idempotency": true,
    "/var/run/uapi-metrics": true,
    "/var/run/uapi-ratelimit": true,
    "/var/run/uapi-token-update": true
  },
  "recent_errors": [
    { "ts": 1780510463, "request_id": "01HX...", "code": "validation_failed",
      "status": 422, "method": "POST", "path": "/firewall/rules",
      "message": "Request body failed validation" }
  ],
  "request_id": "01HX..."
}
```

### Finding sections a write would reject (`?validate=1`)

`GET /api/v3/diagnostics?validate=1` adds a validation sweep: every section of
every resource the token may read is run through the same path a write takes, and
the ones that would be rejected are reported with the reason, together with the
ones that hold a value that a write cannot add.

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

One finding is not a break. An interface on a proto that uapi does not model, such as
the `6in4` that LuCI writes, is listed with `proto` and `not_in_enum`, because a PUT of
it is refused: a PUT replaces the section and would delete the options of the tunnel.
The tunnel itself works, and a PATCH that leaves `proto` out is accepted.

A `validate_new()` rule (`docs/adding-a-resource.md`) is not a break either, until the
daemon reads the value. Another writer can store a value that such a rule refuses, and
the sweep lists it whether the daemon reads it yet or not: the section can be disabled,
its mode can leave the field unused, or the radio of an SSID can be disabled. A write is
refused for such a value only when it
adds the error, for example when it changes the field or enables the section. The sweep
lists the section because another writer, such as LuCI, can enable it later. Each error of such
a rule has `live`, which is `false` when the daemon does not read the value yet.

Three things worth knowing:

- **Opt-in on purpose.** Each resource walks its own uci package, so a package is
  traversed once per resource that lives in it, six times for `firewall` and
  `network`. The cost therefore scales with the number of sections in the
  configuration, not with a fixed overhead: 44 resources over a stock-sized
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

The `recent_errors` ring is best-effort: writes to `/var/run/uapi-error-ring/`
must never disrupt the actual response, so a disk-full or permission
failure simply produces an empty ring rather than a 5xx on the original
request. The ring caps at 20 entries (oldest dropped first), and keeps the
first 512 bytes of each message, ending a cut one with `...`: a 400 for a
control character in a body names the key before authentication, so an
unclipped message let any client store a body of any size in RAM.

`lock_state` reports which uapi lock files exist under `/var/lock`, not
which locks are held right now: `flock` is released when the fd closes
and the file itself is never unlinked, so an entry means that package
has been written at least once since the lock directory was last
cleared.

`state_dirs` reports each state directory under `/var/run`, keyed by its
path, as uapi finds it. The read creates and changes nothing.

- `true`: a directory that the effective uid of the request process owns,
  with mode 0700. uapi writes there.
- `false`: the path holds anything else, and uapi does not use it as it
  stands. A directory that uapi narrows to 0700 at its next write there, as
  `docs/architecture.md` § Where state lives describes, reads `false` until
  that write.
- `null`: the path does not exist yet. uapi creates it at its first write
  there.

`true` does not promise free space. On a full tmpfs the rate limiter allows
every request, and the idempotency cache, the metrics and the error ring
keep no new entry. What `false` costs while it lasts:

| Directory | While it reads `false` |
|---|---|
| `/var/run/uapi-ratelimit` | The rate limiter allows every request. |
| `/var/run/uapi-idempotency` | A request with an `Idempotency-Key` replays nothing, so a retry runs again. |
| `/var/run/uapi-metrics` | `/metrics` records no series. |
| `/var/run/uapi-error-ring` | `recent_errors` stays empty. |
| `/var/run/uapi-token-update` | No request stamps `last_used_at`. |

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
`disabled`, `proto`, `ipaddrs` or `netmask`, or deletes it. `network/devices` and
`network/bridge_vlans` are matched by device instead of by interface name, and report
`device=<name>` when a create or a delete names the caller's own device, or a bridge that
device is a port of. That is the after-the-fact
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
(uptime too short to tell), `degraded` if the wall clock is below the
sanity floor of epoch 1700000000 (14 November 2023), otherwise `ok`.

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

## Request body deadline

The body of a request has to arrive in full within 10 s of its start (`docs/security.md`, Public endpoints). Every request that misses the deadline emits a syslog `WARNING` line, on every path, with no body content:

```
uapi-body-deadline <request_id> <method> <path> status=<n> remote=<addr>
```

The status is the answer that the request got: `400` when uapi read the body and it did not arrive in full, or the normal answer of a request that answers without reading its body, such as a 413 or a GET with a declared body. Many such lines from one address are a client that holds the request slots of uhttpd. Without `ucode-mod-io` there is no deadline, and the handler logs one line when uhttpd starts:

```
uapi-body-deadline: ucode-mod-io is not installed, so a request body that does not arrive holds its request until the script timeout of uhttpd
```

## Capacity

uapi runs in-process inside uhttpd via uhttpd-mod-ucode. Each request is a forked CGI child. On low-end MIPS hardware, fork+ucode+ubus is in the tens of milliseconds per request; on modern aarch64/x86_64 it is sub-10ms. The intended workload is Terraform applies plus occasional curl, not high-volume RPC. If you need RPS in the hundreds, front uapi with a caching reverse proxy.

## Backups

The token store at `/etc/config/uapi` is the only uapi-specific state worth backing up beyond what you'd back up for OpenWrt itself (`sysupgrade --create-backup`). Treat it as a secret. The tokens within are hashed (so a leaked backup file doesn't directly expose bearers), but the salts + hashes still allow an offline brute-force on weak inputs; in practice the bearers are 128 random bits so brute force is infeasible, but discipline still wins.
