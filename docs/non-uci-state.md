# Non-uci state: what uapi covers and what it doesn't

uapi's design contract is "uci is the source of truth". Almost every resource translates HTTP REST verbs into `uci_set` / `uci_commit` followed by a daemon reload. That model covers most of OpenWrt's configuration surface, but not all of it. This document inventories the small set of state that lives outside uci, in two categories:

1. **In-scope, non-uci resources.** Things uapi exposes anyway, with deliberately documented deviations from the standard transaction recipe.
2. **Out-of-scope state.** Things uapi explicitly does NOT cover, with the recommended out-of-band path for each.

The bar for adding to category 1 is high. New non-uci resources should justify themselves against three questions: is the underlying daemon's uci surface genuinely missing this? would the right long-term fix be to add a uci option upstream rather than carry workaround state in uapi? does the resource fit a curated CRUD shape, or is it a one-shot action better handled by an operator tool?

## In-scope non-uci resources

The canonical registry (and the single-line table form) lives in `CLAUDE.md` under "Resource model" → "Non-uci resources". Each entry below expands on its lock semantics, audit shape, the file/process it touches, and why the standard uci-transaction recipe doesn't apply.

### `packages/installed`

- **Source of truth.** The apk database. Reads enumerate via `apk info --installed`; writes shell out to `apk add <name>` and `apk del <name>` via `fs.popen`.
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
- **HTTP shape.** `POST /api/v1/system/password` returns `204`. There is no `GET` (password hashes don't leak through the API at all).
- **Why not uci.** OpenWrt has no uci wrapper for local user credentials. Cloud-init / image-bake (uci-defaults dropping a `passwd -d root` line, etc.) is the alternative for purely offline provisioning.

### `system/authorized_keys`

- **Source of truth.** `/etc/dropbear/authorized_keys` (mode 0600).
- **Lock.** `transaction.with_lock` for writes; reads are lock-free.
- **Mechanism.** Direct file I/O. dropbear re-reads the file on every connection so no reload is needed.
- **Validation.** Server-side parse of each key line as `<type> <base64-blob> [comment]`. Allowed types: `ssh-rsa`, `ssh-ed25519`, `ecdsa-sha2-nistp{256,384,521}`, `sk-ssh-ed25519@openssh.com`, `sk-ecdsa-sha2-nistp256@openssh.com`. Options blocks (`command="..."`, `no-pty`, etc.) before the key type are stripped from the canonical form.
- **Stable id.** Derived from the blob's tail (12 chars, with `+/=` remapped to letters so it fits a URL-safe `^[a-z0-9]{12}$` pattern). Same key always gets the same id, idempotent across re-adds.
- **HTTP shape.** `GET` lists; `POST` adds one; `PUT` replaces wholesale (dedup); `DELETE /<id>` removes one.
- **Why not uci.** OpenWrt has no uci wrapper for SSH authorized keys. LuCI also writes the file directly via its rpcd `fs` plugin.

## Out-of-scope state

The following items are real configuration concerns that uapi deliberately does NOT cover. For each, the recommended out-of-band path is listed. An IaC orchestrator typically wires these once at image-bake time (cloud-init / `/etc/uci-defaults/`) rather than reaching for them on every reconcile.

### Unbound listen-address binding

- **Why excluded.** OpenWrt's `unbound` uci has no clean option for binding the recursive server to a specific address (e.g. loopback-only). The upstream init script emits `interface-automatic: yes` unconditionally when `interface_auto=1`; there is no uci path that produces an `interface: 127.0.0.1` line. uapi's `unbound/server` resource curates every uci option the upstream init script actually consumes, but it deliberately does not invent an option that uci doesn't expose.
- **Recommended path.** Drop your overrides into `/etc/unbound/unbound_srv.conf` (auto-included inside the `server:` clause), or set `manual_conf=1` via `PATCH /api/v1/unbound/server` and write the full `/etc/unbound/unbound.conf` yourself. The `unbound_srv.conf` file ships as a stub from the upstream package precisely for this use.

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

- **Why excluded.** Historical timeseries data is not uci-state. uapi exposes `vnstat/config` and `vnstat/interfaces` for configuring the collector; the database itself stays where vnstat puts it.

## When you find a new gap

If your real-world configuration needs something uapi can't currently express, the first question to ask is: does the underlying OpenWrt package expose this via uci? If yes, the curated resource is undercurated; file an issue. If no, the right fix is usually to upstream a uci option, not to add another non-uci resource to uapi.

If, after weighing those, a new non-uci resource really IS the right answer, it needs to ship together with:

- A row in the CLAUDE.md "Non-uci resources" registry.
- A subsection in this doc describing source-of-truth, lock semantics, audit shape, validation, and the "why not uci" rationale.
- Integration test coverage of the read AND write paths.
- A scope-tree entry (`<domain>:<resource>:rw` / `:ro`).
- An explicit security review of the shell-out / file-write surface.
