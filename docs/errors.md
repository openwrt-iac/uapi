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

- `code` is machine-readable, snake_case, stable across versions within v1.
- `message` is human-readable English. Don't parse it.
- `request_id` is a ULID echoed in the `X-Request-Id` response header on **every** response, success or error. Pair with the audit log line to trace a request server-side.
- `errors[]` is only present for `422 validation_failed`. **All** field errors are reported together so the client can fix everything in one round trip.

For DELETE success, the response is `204 No Content` with the `X-Request-Id` header but no body.

## Top-level codes

| HTTP | `code`                          | When                                                         |
|------|----------------------------------|--------------------------------------------------------------|
| 400  | `bad_request`                   | Malformed JSON, wrong shape, body where none expected        |
| 401  | `unauthorized`                  | No `Authorization` header                                    |
| 401  | `invalid_token`                 | Token not in store, or store is empty                        |
| 403  | `insufficient_scope`            | Token valid, scopes don't cover this verb/path               |
| 403  | `tls_required`                  | Non-localhost client over plain HTTP                         |
| 404  | `not_found`                     | Resource does not exist                                      |
| 405  | `method_not_allowed`            | Verb not supported on this resource                          |
| 409  | `conflict`                      | Duplicate name, dangling cross-reference, etc.               |
| 409  | `unmanaged_resource`            | Tried to write to a section that needs to be adopted first   |
| 415  | `unsupported_media_type`        | Body wasn't `application/json`                               |
| 422  | `validation_failed`             | Body parsed but failed schema or per-field rules             |
| 423  | `locked`                        | Another write transaction holds the global lock; retry       |
| 500  | `internal_error`                | Bug or unexpected condition                                  |
| 500  | `reload_failed_restored`        | Daemon reload failed; uapi rolled back the uci change        |
| 500  | `reload_failed_unrecovered`     | Reload AND restore failed. Loudest case; manual recovery     |
| 503  | `service_unavailable`           | ubus unreachable, service not running                        |

The reload-failure-restored response carries the original ubus error as an extension field:

```json
{
  "code": "reload_failed_restored",
  "message": "Service reload failed; prior configuration has been restored",
  "request_id": "01HX...",
  "reload_error": "ubus call network reload: netifd: interface 'wan' has invalid proto"
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

## Retry-After

`423 locked` responses include `Retry-After: 1`. Wait that many seconds (or use jittered backoff) and try again. The lock window is the duration of one atomic transaction (snapshot, validate, stage, commit, reload, possibly restore) and is typically well under a second.
