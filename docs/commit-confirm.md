# Commit-confirmed apply

A uapi write is atomic per request (stage, validate, commit, reload, with an
in-band rollback if the reload command fails). That protects against a *failed*
reload. It does not protect against a reload that succeeds yet severs the
operator's only path to the box: a firewall or network change can reload
cleanly (the init script exits 0) and still lock you out, with no one left to
undo it.

Commit-confirmed apply closes that gap. A write can arm a deadline: uapi
snapshots the affected uci packages and commits the change, and unless the
client confirms within the window, the snapshot is restored automatically. The
rollback fires locally and survives a reboot, a process kill, and the
management interface going down.

uapi does not implement the timer or the durable state itself; that would mean a
long-running daemon, which the zero-bloat / no-aux-process principle forbids.
The supervisor lives in a separate package, `apply-confirm`, and uapi integrates
by invoking its CLI. See `apply-confirm`'s own docs for the rollback mechanism.

## Optional, feature-detected

The integration is optional. uapi probes for `/usr/sbin/apply-confirm` per
request:

- Installed: the confirm surface is live.
- Absent: a write that asks to confirm returns `501 confirm_unavailable`, and an
  ordinary write (no confirm) behaves exactly as before. There is no hard
  package dependency; `apk add apply-confirm` is the opt-in.

## Arming a write

Add `?confirm=<seconds>` to any config write (`POST`/`PUT`/`PATCH`/`DELETE` on a
resource, or `POST /batch`). The value is 1..3600. Arming needs no extra scope:
it is a safety modifier on a write the token is already authorized to perform.

```sh
# Arm a 60s rollback on a firewall change.
curl -fsS -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -X PUT 'https://router/api/v2/firewall/rules/<id>?confirm=60' -d @rule.json
```

The query parameter is the portable interface. uapi also reads an
`X-Uapi-Confirm: <seconds>` header, but uhttpd's CGI env strips it via a
hard-coded allowlist (the same reason `If-Match` and `Idempotency-Key` have
`?if_match=` / `?idempotency_key=` fallbacks); the header path only works when a
reverse proxy in front of uhttpd forwards it.

A confirmed write returns **202 Accepted** instead of 200/204. The body is the
normal resource representation plus a `confirm` block, and the token is also in
the `X-Confirm-Token` response header:

```json
{
  "...": "normal resource body",
  "confirm": {
    "token": "ac_1718900000_a1b2c3d4",
    "timeout": 60,
    "deadline": 1718900060,
    "packages": ["firewall"]
  }
}
```

`deadline` is best-effort (`now + timeout`); poll `GET /confirm/<token>` for the
authoritative remaining time.

## Confirming or rolling back

Verify the management path still works, then confirm. If you cannot reach the
box, do nothing: the deadline fires and the change is reverted.

| Method + path            | Action                              | Scope            |
|--------------------------|-------------------------------------|------------------|
| `POST /confirm/<token>`  | ack: keep the change                | `uapi:confirm:rw`|
| `DELETE /confirm/<token>`| roll back now (early/forced)        | `uapi:confirm:rw`|
| `GET /confirm/<token>`   | status (authoritative remaining)    | `uapi:confirm:ro`|
| `GET /confirm`           | list pending windows                | `uapi:confirm:ro`|

A console operator with no network can still force the revert directly:
`apply-confirm rollback`.

## What uapi reloads vs what apply-confirm reloads

uapi owns the forward reload (applying the change) and the in-band rollback (if
that reload fails). apply-confirm owns the out-of-band rollback reload (timeout
or forced) because uapi's process is gone by then. uapi passes its own
authoritative reload set (`resource.reload`, unioned across a batch) to
`apply-confirm stage --service ...`, so a rollback reloads exactly what the
apply reloaded.

## Failure modes

| Condition | Response |
|-----------|----------|
| apply-confirm not installed | `501 confirm_unavailable`; nothing staged |
| another apply already armed (one pending at a time, across uapi/LuCI/shell) | `409 already_armed`; reverted |
| bad timeout | `400 bad_request`; reverted |
| snapshot/state write failed | `503 confirm_stage_failed`; nothing committed |
| apply reload fails while uapi is alive | in-band `reload_failed_restored`, and the now-pointless window is disarmed |
| apply bricks so hard the request never returns | apply-confirm's supervisor auto-reverts at the deadline, surviving reboot |
| ack after the window closed / double ack | `409 confirm_window_closed` |
| forced rollback restored config but a reload failed | `500 rollback_reload_failed` (the config WAS restored) |

## Known limit: the unconfirmed window

While a window is armed, the write's per-package lock has already been released
(uapi forks per request). A *second* normal write to the same package during the
window will commit, and then the pending auto-rollback can clobber it. The
single-pending-apply rule (one armed window globally) bounds the blast radius,
and the Terraform provider serializes its own applies, so this is a non-issue
for the primary consumer. Do not interleave manual writes with an armed window.
