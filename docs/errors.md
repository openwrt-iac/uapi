# Errors

## Envelope

Every non-2xx response carries this body shape (Content-Type: `application/json`):

```json
{
  "code": "validation_failed",
  "message": "Field 'ipaddr' is not a valid IPv4 address",
  "request_id": "01HX1234567890ABCDEFGHJKMN",
  "errors": [
    { "field": "ipaddr",  "code": "invalid_format", "message": "must be a valid IPv4 address" },
    { "field": "netmask", "code": "required",       "message": "is required" }
  ]
}
```

- `code` is machine-readable, snake_case, stable within a package major.
- `message` is human-readable English. Don't parse it.
- `request_id` is a ULID echoed in the `X-Request-Id` response header on **every** response, success or error. Pair with the audit log line to trace a request server-side. Clients may supply their own via `X-Request-Id` header or `?request_id=` query param (validated against `^[A-Za-z0-9_-]{8,128}$`; malformed values fall back to a server-generated ULID).
- `errors[]` is only present for `422 validation_failed`. **All** field errors are reported together so the client can fix everything in one round trip.

For DELETE success, the response is `204 No Content` with the `X-Request-Id` header but no body.

## Top-level codes

| HTTP | `code`                          | When                                                         |
|------|----------------------------------|--------------------------------------------------------------|
| 400  | `bad_request`                   | Malformed JSON, wrong shape, body where none expected        |
| 400  | `invalid_cursor`                | Malformed `?cursor=` or one referencing no current item      |
| 401  | `unauthorized`                  | No `Authorization` header                                    |
| 401  | `invalid_token`                 | Token not in store, expired, or source IP not in `allowed_cidrs` |
| 403  | `insufficient_scope`            | Token valid, scopes don't cover this verb/path               |
| 403  | `scope_escalation_blocked`      | `POST /tokens` requested scopes outside the caller's         |
| 403  | `tls_required`                  | Non-localhost client over plain HTTP                         |
| 404  | `not_found`                     | Resource does not exist                                      |
| 405  | `method_not_allowed`            | Verb not supported on this resource                          |
| 409  | `conflict`                      | Duplicate name, dangling cross-reference, etc.               |
| 409  | `unmanaged_resource`            | Tried to write to a section that needs to be adopted first   |
| 409  | `idempotency_key_conflict`      | Same `Idempotency-Key` reused with a different body          |
| 412  | `precondition_failed`           | Stale `If-Match` ETag, or JSON Patch `test` op mismatch      |
| 415  | `unsupported_media_type`        | Body wasn't `application/json` (or `application/json-patch+json` on PATCH) |
| 422  | `validation_failed`             | Body parsed but failed schema or per-field rules             |
| 423  | `locked`                        | Another write transaction holds the global lock; retry       |
| 429  | `too_many_requests`             | Per-token rate limit exceeded                                |
| 500  | `internal_error`                | Bug or unexpected condition                                  |
| 500  | `reload_failed_restored`        | Daemon reload failed; uapi rolled back the uci change        |
| 500  | `reload_failed_unrecovered`     | Reload AND restore failed. Loudest case; manual recovery     |
| 503  | `service_unavailable`           | ubus unreachable, service not running                        |
| 503  | `init_script_missing`           | `/etc/init.d/<svc>` not present for a resource's reload list |

`batch_partial_failure` is special: it appears only in the body of a
`POST /batch` abort response, with the HTTP status taken from the failing
sub-request. The body carries `{code: "batch_partial_failure",
aborted_at_index, error: <sub-envelope>, reverted: true}`.

The reload-failure-restored response carries the init script's exit summary as an extension field:

```json
{
  "code": "reload_failed_restored",
  "message": "Service reload failed; prior configuration has been restored",
  "request_id": "01HX...",
  "reload_error": "network exited with code 1: netifd: interface 'wan' has invalid proto"
}
```

The unrecovered case adds `restore_error` as well.

## Field-level codes

In `errors[].code` (only inside `422 validation_failed`):

| `code`           | Meaning                                                       |
|------------------|---------------------------------------------------------------|
| `required`       | Required field missing                                        |
| `invalid_type`   | Wrong JSON type (string vs. number etc.)                      |
| `invalid_format` | Failed format validator (CIDR, MAC, IP, etc.)                 |
| `out_of_range`   | Numeric or length bound exceeded                              |
| `not_in_enum`    | Value not in the allowed set                                  |
| `conflict`       | References a missing or incompatible resource                 |
| `read_only`      | Field is computed/runtime and can't be set                    |

## Field paths

Dotted notation with bracket indexing: `match.src_zone`, `dns[0]`, `rules[2].target`.

## Response headers

Every response carries:

| Header                       | When                                | Notes                                                                  |
|------------------------------|-------------------------------------|------------------------------------------------------------------------|
| `X-Request-Id`               | always                              | ULID for log correlation.                                              |
| `Content-Type: application/json` | always (except 204 no-content / `/metrics` text) | -                                                                      |
| `Strict-Transport-Security`  | always                              | 1 year, includeSubDomains.                                             |
| `X-Content-Type-Options`     | always                              | `nosniff`.                                                             |
| `Referrer-Policy`            | always                              | `no-referrer` (request_id appears in URLs).                            |
| `Cache-Control`              | always                              | `no-store` (token-scoped data).                                        |
| `ETag`                       | 200/304 on GET, write success       | Quoted hash of this resource's own body (runtime block excluded). Sibling sections do not influence the value. |
| `WWW-Authenticate: Bearer`   | every 401                           | `realm="uapi", error="<code>"` (RFC 7235 + RFC 6750).                  |
| `Retry-After: <seconds>`     | 423 locked, 429 too_many_requests   | Honor with jittered backoff.                                           |
| `Link: <?cursor=...>; rel="next"` | paginated GETs when more items exist | RFC 8288.                                                              |
| `X-Next-Cursor: c_<id>`      | paginated GETs when more items exist | Convenience companion to `Link`.                                       |
| `Idempotent-Replayed: true`  | POST replays via `Idempotency-Key`  | Marker that the response was served from cache rather than re-applied. |
| `X-Reload-Status`            | 2xx on writes                       | `ok` = init script reload exited 0 (NOT a runtime-convergence promise); `no_reload` = the resource has no reload services. See `docs/operations.md` "Success != converged". |
| `X-Reload-Services`          | 2xx on writes when status=ok        | Comma-separated list of init scripts that ran (e.g. `firewall`, `dnsmasq`). |

## Retry-After

`423 locked` includes `Retry-After: 1`; `429 too_many_requests` carries
the rate-limit bucket refill estimate. Wait that many seconds (or use
jittered backoff) and try again. The 423 lock window is the duration of
one atomic transaction (snapshot, validate, stage, commit, reload,
possibly restore) and is typically well under a second.
