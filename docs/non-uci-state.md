# Non-uci state: what uapi covers and what it doesn't

uapi's design contract is "uci is the source of truth". Almost every resource translates HTTP REST verbs into `uci_set` / `uci_commit` followed by a daemon reload. That model covers most of OpenWrt's configuration surface, but not all of it. This document inventories the small set of state that lives outside uci, in two categories:

1. **In-scope, non-uci resources.** Things uapi exposes anyway, with deliberately documented deviations from the standard transaction recipe.
2. **Out-of-scope state.** Things uapi explicitly does NOT cover, with the recommended out-of-band path for each.

The bar for adding to category 1 is high. New non-uci resources should justify themselves against three questions: is the underlying daemon's uci surface genuinely missing this? would the right long-term fix be to add a uci option upstream rather than carry workaround state in uapi? does the resource fit a curated CRUD shape, or is it a one-shot action better handled by an operator tool?

## In-scope non-uci resources

| Resource | Source of truth | Lock | Reload | Notes |
|---|---|---|---|---|
| `packages/installed` | apk DB (`apk add`/`del` shell-out) | `with_lock` on global | none | postinst runs as root; package's responsibility to wire its own uci/init scripts |
| `packages/feeds` | `/etc/apk/repositories.d/*.list` + `apk update` | `with_lock` on global | none | url-validated, name-validated |
| `dhcp/leases` | `/tmp/dhcp.leases` (parse) | none (read-only) | n/a | dnsmasq IPv4 leases |
| `dhcp/leases6` | `/tmp/hosts/odhcpd` (parse), fallback `/tmp/odhcpd.leases` | none (read-only) | n/a | odhcpd IPv6 leases |
| `system/password` | `/bin/busybox passwd <user>` (stdin pipe) | `with_lock` on global | none | write-only; audit logs token+user, never the password |
| `system/authorized_keys` | `/etc/dropbear/authorized_keys` (mode 0600) | `with_lock` on global for writes; reads lock-free | none | dropbear re-reads the file per connection |
| `system/cron_jobs` | `/etc/crontabs/root` (mode 0600) | `with_lock` on global for writes; reads lock-free | `cron` | one entry per line; other lines stay byte for byte |

Each entry below expands on its lock semantics, audit shape, the file/process it touches, and why the standard uci-transaction recipe doesn't apply.

Adding a non-uci resource means adding a row above. The bar is high: prefer driving the underlying daemon's uci surface if the option exists, or upstreaming the option to OpenWrt uci if it doesn't, before adding non-uci state to uapi.

### `packages/installed`

- **Source of truth.** The apk database. Reads enumerate via `apk info` (apk-tools 3.x returns nothing for `--installed`); writes shell out to `apk add <name>` and `apk del <name>` via `fs.popen`. A single package's version comes from `apk query --from installed --format json`, because the `<name>-<version>` line of `apk info` cannot be split right for a name that ends in a dash and digits.
- **Index refresh.** `apk add` refreshes a feed index only when its cached copy is older than 4 hours, or missing, as after a reboot (the cache is under `/var/cache/apk`, on tmpfs). Inside that window a feed can rebuild a package in place (`-r2` to `-r3`) and drop the old file, so the cached index names a download that 404s, or it can add a package the cached index does not list. When `apk add` fails, uapi runs `apk update` and tries `apk add` once more, and the second result is the one reported. The retry runs even when `apk update` fails, because it exits with the number of feeds it could not refresh: one unreachable feed makes it fail after it has refreshed all the others. A successful install costs nothing extra. A failure that a refresh cannot fix, such as a bad name, pays for one refresh before it is reported. Read-only apk commands (`apk search`, `apk fetch`, any `--simulate`) never refresh, so they can show a stale index that `apk add` would refresh.
- **Lock.** `transaction.with_lock` on `/var/lock/uapi.lock`. apk has its own DB lock; the uapi flock serialises concurrent uapi requests so they don't race apk-vs-apk and surface as nondeterministic `5xx`s. Contention returns `423 locked` with `Retry-After: 1`.
- **Reload.** None at the uapi layer. Each package's postinst runs as root and is responsible for wiring whatever the package installs (uci defaults, init scripts, etc.).
- **Validation.** Package name must match `^[A-Za-z0-9_+][A-Za-z0-9_+.-]*$`. Names starting with `-` or `.` are rejected to prevent apk-flag injection (`--allow-untrusted`, `--repository=...`); the shell-out also uses `apk add -- <name>` as a defense-in-depth separator.
- **Audit.** On failure, the full apk stderr is logged to syslog under the request id (`uapi-pkg-failure <request_id> action=install name="..." exit=<n> output="..."`). The HTTP response carries only a generic "apk add failed (exit N); see syslog <request_id>" message, so feed URLs with embedded credentials don't leak into client logs.
- **Why not uci.** apk's installed-package set is a runtime database (`/var/lib/apk/...`), not a uci config. The right place to drive it is apk itself.

### `packages/feeds`

- **Source of truth.** Files under `/etc/apk/repositories.d/*.list`.
- **Lock.** Same as `packages/installed`. After every write, `apk update` is invoked so the new feed is immediately available.
- **Reload.** None; `apk update` IS the reload.
- **Validation.** Feed name must match `^[A-Za-z0-9_][A-Za-z0-9_.-]*$` (no leading dot, no leading dash). URL must be `http://` or `https://`. `file://` and other schemes are rejected.
- **Why not uci.** apk reads `/etc/apk/repositories.d/` directly. There is no uci wrapper for it upstream.

### `dhcp/leases` (read-only)

- **Source of truth.** `/tmp/dhcp.leases` (the dnsmasq lease dump).
- **Lock.** None; reads only.
- **Format.** Space-separated lines: `<expires_at> <mac> <ip> <hostname> <duid?>`.
- **Why not uci.** Active leases are runtime state, by definition not in `/etc/config/`.

### `dhcp/leases6` (read-only)

- **Source of truth.** `/tmp/hosts/odhcpd` (preferred) or `/tmp/odhcpd.leases` (older odhcpd versions).
- **Lock.** None; reads only.
- **Format.** Best-effort parser, one entry per assigned address: `<duid> <iaid> <hostname> <expires_at> <interface> <IA_NA|IA_PD> <ip>[/<prefixlen>] [<ip2> ...]`. Lines that don't match this shape are silently skipped. odhcpd's statefile format varies across versions; parser failure on a single line never breaks the read path for the rest.
- **Why not uci.** Same as `dhcp/leases`; runtime state.

### `system/password` (write-only)

- **Source of truth.** `/etc/shadow`, via `passwd(1)`.
- **Lock.** `transaction.with_lock`.
- **Mechanism.** Shells out to `/bin/busybox passwd <user>` and pipes `<pw>\n<pw>\n` through stdin (the same recipe LuCI uses for its "Router Password" page).
- **Validation.** `user` must match `^(root|[a-z][a-z0-9_-]*)$`. `password` must be at least 8 characters.
- **Audit.** Successful sets emit `uapi-passwd-set <request_id> user="..."`. Failures emit `uapi-passwd-failure <request_id> user="..." exit=<n>`. The password VALUE is never logged.
- **HTTP shape.** `POST /api/v3/system/password` returns `204`. There is no `GET` (password hashes don't leak through the API at all).
- **Why not uci.** OpenWrt has no uci wrapper for local user credentials. Cloud-init / image-bake (uci-defaults dropping a `passwd -d root` line, etc.) is the alternative for purely offline provisioning.

### `system/authorized_keys`

- **Source of truth.** `/etc/dropbear/authorized_keys` (mode 0600).
- **Lock.** `transaction.with_lock` for writes; reads are lock-free.
- **Mechanism.** Direct file I/O. dropbear re-reads the file on every connection so no reload is needed. A file that exists but cannot be read fails the request with `500`: reading it as empty would let an add or a remove rewrite it with only its own keys, and lock root out of SSH.
- **Validation.** Server-side parse of each key line as `<type> <base64-blob> [comment]`. Allowed types: `ssh-rsa`, `ssh-ed25519`, `ecdsa-sha2-nistp{256,384,521}`, `sk-ssh-ed25519@openssh.com`, `sk-ecdsa-sha2-nistp256@openssh.com`. Options blocks (`command="..."`, `no-pty`, etc.) before the key type are stripped from the canonical form.
- **Stable id.** The first 12 hex characters of the blob's sha256, matching `^[a-f0-9]{12}$`. Same key always gets the same id, idempotent across re-adds.
- **HTTP shape.** `GET` lists; `POST` adds one; `PUT` replaces wholesale (dedup); `DELETE /<id>` removes one.
- **Why not uci.** OpenWrt has no uci wrapper for SSH authorized keys. LuCI also writes the file directly via its rpcd `fs` plugin.

### `system/cron_jobs`

- **Source of truth.** `/etc/crontabs/root`, read by busybox crond. Other users' crontabs are out of scope.
- **Lock.** `transaction.with_lock` for writes. Reads are lock-free.
- **Mechanism.** The write reads the file, adds or removes its own line, and puts the result in place with the same 0600 temp-file-and-rename as `authorized_keys`. Every other line stays byte for byte: entries from packages, comments, and `MAILTO=`, `SHELL=` and `PATH=` lines. An appended entry goes at the end, so an environment line earlier in the file applies to it. A crontab that exists but cannot be read fails the request with `500`, because treating it as empty would let the write replace every line in it.
- **Line continuation.** crond joins a line that ends in `\` with the next one, and drops the backslash, before it looks for `#`. Measured on the device: `touch /tmp/c1 \` followed by `/tmp/c2` ran `touch /tmp/c1 /tmp/c2`, and a comment that ends in `\` hid the entry below it. uapi reads the file in the same groups. A delete removes every physical line of its entry, and an append after a trailing backslash first adds a blank line, which ends the continuation without changing what crond reads for the line before.
- **Reload.** `/etc/init.d/cron reload`. The init script registers each crontab with procd as a watched file, so the reload restarts crond only when the content changed. It is also what starts crond on a stock image: there is no crontab there, and the init script does not start crond while `/etc/crontabs/` is empty. A failed reload puts the old file back and reloads again, and the request answers `reload_failed_restored` or `reload_failed_unrecovered`, as a curated write does. Removing the last entry leaves an empty file, so crond keeps running with nothing to do.
- **Effect.** `runtime.crond_running` asks procd whether crond runs, on every read and after every write, delete included. The reload exit status cannot tell: with an invalid `system.cronloglevel` the init script prints "validation failed", exits 0, and procd stops crond. A write in that state answers 200 with `crond_running: false`. uapi does not know whether a job ran, and does not claim to.
- **Reads list what crond runs.** A line is parsed the way busybox crond reads it on OpenWrt: continuations are joined, `#` ends the line wherever it appears, environment lines and lines short of five fields plus a command are skipped, and field spacing collapses. A line from another writer therefore shows up as crond sees it, which is not always how it looks. Where its schedule is one crond misreads, such as minute `75` or weekday `7`, the entry says so with `runtime.runs_as_written: false`.
- **Validation.** Writes accept only what crond runs as written, and refuse an undeclared body field with `unknown_field`. busybox crond does not refuse a bad field: it logs a parse error and keeps the line with a half-filled schedule, so minute `75` runs every minute and weekday `7` runs every day. The schedule is five fields separated by single spaces, each a list of values, ranges (wrapping ones such as `22-2` included) and `*`, with a `/step` after `*` or a range. Ranges: minute 0-59, hour 0-23, day 1-31, month 1-12 or `jan`-`dec`, weekday 0-6 or `sun`-`sat`. Refused, each for a reason crond gives:
  - `@daily`, `@reboot` and the other special schedules. OpenWrt builds busybox without `FEATURE_CROND_SPECIAL_TIMES`: crond skips a short `@daily` line and misreads a long one.
  - A step on a single value. busybox reads `5/10` as 5 alone, and other crons read it as `5-59/10` or refuse it.
  - `*/N` in the day field. busybox fills `*` for days from day 0, so `*/2` runs on days 2 to 30 where other crons run on days 1 to 31, and it ORs such a day with a restricted weekday where other crons AND them. `1-31/N` means the same everywhere.
  - `#` in the command. crond cuts the line there: `touch /tmp/a#b` runs `touch /tmp/a`.
  - A command that ends in `\`, which joins the next line into it.
  - Control characters in the command, and whitespace at either end, which crond strips.
- **`%`.** busybox crond gives it no special meaning, so it passes through to the shell unchanged.
- **Stable id.** The first 12 hex characters of `sha256("<schedule> <command>")`. A change to either field gives a new id, so an update is a delete plus a create. Identical lines share an id: a read lists them once, and a delete removes them all.
- **HTTP shape.** `GET` lists, `POST` adds one, and `DELETE /<id>` removes one and answers `200` with the removed entry and crond's state after the reload. There is no `PUT` for the whole file, although that is how LuCI edits it (one textarea, saved whole). Packages write to the same file: `acme` adds `0 0 * * * /etc/init.d/acme renew` each time it starts, and `safe-search` and `wg-installer` add their own lines. A client that owned the whole file would delete those lines, and the packages would add them back on their next start.
- **Read exposure.** A read returns every command in full, to any token with `system:cron_jobs:ro` or a scope above it, `*:ro` included. A command can carry a credential, so keep secrets in a 0600 file that the command reads. The command stays readable because a client cannot adopt or compare an entry it cannot see.
- **Audit.** A create emits `uapi-cron-job-add <request_id> id=<id>`, which ties the generic write line to the entry it made. The command is not logged, since commands can carry credentials.
- **Why not uci.** OpenWrt has no uci surface for cron entries. The only cron option in uci is `system.cronloglevel`, and busybox crond reads only crontab files. LuCI writes the file directly too.

## Out-of-scope state

The following items are real configuration concerns that uapi deliberately does NOT cover. For each, the recommended out-of-band path is listed. An IaC orchestrator typically wires these once at image-bake time (cloud-init / `/etc/uci-defaults/`) rather than reaching for them on every reconcile.

### Unbound listen-address binding

- **Why excluded.** OpenWrt's `unbound` uci has no clean option for binding the recursive server to a specific address (e.g. loopback-only). The upstream init script emits `interface-automatic: yes` unconditionally when `interface_auto=1`; there is no uci path that produces an `interface: 127.0.0.1` line. uapi's `unbound/server` resource curates every uci option the upstream init script actually consumes, but it deliberately does not invent an option that uci doesn't expose.
- **Recommended path.** Drop your overrides into `/etc/unbound/unbound_srv.conf` (auto-included inside the `server:` clause), or set `manual_conf=1` via `PATCH /api/v3/unbound/server` and write the full `/etc/unbound/unbound.conf` yourself. The `unbound_srv.conf` file ships as a stub from the upstream package precisely for this use.

### Serial console / inittab

- **Why excluded.** `/etc/inittab` is not uci.
- **Recommended path.** Bake the inittab edit into the image, or scp the desired `/etc/inittab` at first boot.

### Wake-on-LAN packets

- **Why excluded.** WoL is a runtime action (send a magic packet), not state.
- **Recommended path.** Install `etherwake` via `packages/installed` and run it from a script over SSH or via a separate orchestration tool. The MAC + interface map is operator memory.

### Certificate regeneration via `px5g_x509`

- **Why excluded.** `uhttpd/certs` curates the px5g cert-generation PARAMETERS (days, bits, CN, etc.), but the actual one-shot regeneration is an action. uci doesn't model it.
- **Recommended path.** Run `px5g_x509` (or `acme.sh` / `luci-app-acme` for real certs) out-of-band. For production, an ACME workflow keyed off a `cron` or systemd timer is the standard approach.

### FreeBSD `sysctl` tunables from an OPNsense-style migration

- **Why excluded.** They don't map to OpenWrt's Linux kernel.
- **Recommended path.** Identify the Linux equivalent (typically a `sysctl` parameter) and drop it into `/etc/sysctl.d/` at image-bake time.

### RRD / NetFlow history

- **Why excluded.** Historical timeseries data is not uci-state. uapi exposes `vnstat/config` (including its `interfaces` list) for configuring the collector; the database itself stays where vnstat puts it.

## When you find a new gap

If your real-world configuration needs something uapi can't currently express, the first question to ask is: does the underlying OpenWrt package expose this via uci? If yes, the curated resource is undercurated; file an issue. If no, the right fix is usually to upstream a uci option, not to add another non-uci resource to uapi.

If, after weighing those, a new non-uci resource really IS the right answer, it needs to ship together with:

- A row in the registry table at the top of this document.
- A subsection in this doc describing source-of-truth, lock semantics, audit shape, validation, and the "why not uci" rationale.
- Integration test coverage of the read AND write paths.
- A scope-tree entry (`<domain>:<resource>:rw` / `:ro`).
- An explicit security review of the shell-out / file-write surface.
