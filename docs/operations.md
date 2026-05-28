# Operations

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

## Log line format

```
uapi: <request_id> <token_name|-> <severity> <code> <method> <path> <status> [<duration_ms>ms]
```

- `request_id`: ULID; also returned in the `X-Request-Id` response header. The link between server-side log and client-visible response.
- `token_name`: never the token value. `-` for unauthenticated failures (e.g. missing `Authorization`).
- `severity`: `AUDIT` (writes), `WARN` (4xx auth failures), `ERROR` (5xx).
- `code`: error code on failures, `-` on successful writes.

By default only AUDIT (successful writes) and ERROR/WARN (failures) are logged. Optional knobs in `/etc/config/uapi`:

```
config logging
    option access '1'   # log every request (INFO)
    option debug '1'    # per-ubus-call tracing (DEBUG)
```

Leave these off unless you're debugging. They are noisy and will fill the in-memory ring quickly.

## Metrics

Not in v1. Operators wanting router-level metrics use `node_exporter` (available in the `packages` feed); uapi's request volume is naturally low and not the bottleneck. A `/metrics` endpoint is on the v1.1+ list.

## Healthz

```sh
curl -k https://<router>/api/v1/healthz
# 200 OK on the happy path
# 503 service_unavailable if ubus is unreachable
```

No auth required; TLS-for-non-localhost still applies. Monitors should poll healthz, not a real endpoint, to avoid burning audit-log noise.

## Capacity

uapi runs in-process inside uhttpd via uhttpd-mod-ucode. Each request is a forked CGI child. On low-end MIPS hardware, fork+ucode+ubus is in the tens of milliseconds per request; on modern aarch64/x86_64 it is sub-10ms. The intended workload is Terraform applies plus occasional curl, not high-volume RPC. If you need RPS in the hundreds, front uapi with a caching reverse proxy.

## Backups

The token store at `/etc/config/uapi` is the only uapi-specific state worth backing up beyond what you'd back up for OpenWrt itself (`sysupgrade --create-backup`). Treat it as a secret. The tokens within are hashed (so a leaked backup file doesn't directly expose bearers), but the salts + hashes still allow an offline brute-force on weak inputs; in practice the bearers are 128 random bits so brute force is infeasible, but discipline still wins.
