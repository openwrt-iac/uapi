# Tokens and scopes

uapi authenticates every request (except `/healthz`, `/openapi.json`, and
`/schema/*`) with a bearer token. Tokens are created on the router (or
over HTTP once a token with `uapi:tokens:rw` exists), hashed at rest, and
authorized against a hierarchical scope tree.

## Creating tokens (CLI)

```sh
uapi-token create --name <label> --scope <scope> [--scope <scope>...] \
                  [--expires-in <N>[smhd]] [--allowed-cidr <CIDR>...] \
                  [--force]
```

- `--name`: human-readable label. Must be unique. Surfaces in the audit log on every authed request.
- `--scope`: at least one. May repeat. Validated against the known scope tree (see below); `--force` bypasses.
- `--expires-in`: optional duration. Suffix is one of `s`/`m`/`h`/`d`. The token returns `401 invalid_token` with `message: "Token expired"` after the deadline passes.
- `--allowed-cidr`: optional source-IP allowlist (IPv4 CIDRs only; may repeat). When set, the token returns `401 invalid_token` with `message: "Source IP not permitted for this token"` from any other source. Bad CIDR shape rejected at mint time.
- Output (stdout): the cleartext bearer string, exactly once. Stderr explains it's the only chance to capture it.

The router stores only the salt + `sha256(salt + ":" + bearer)`. The cleartext cannot be recovered.

```sh
uapi-token list             # short summary: name, scopes, expiry (if set), allowed_cidrs (if set)
uapi-token show <name>      # detailed view (scopes, expiry, cidrs, last_used_at/ip; no secret)
uapi-token revoke <name>    # delete a token
```

## Creating tokens (HTTP)

A token holding `uapi:tokens:rw` (or `*:rw`) can mint other tokens over the
wire:

```sh
curl -H "Authorization: Bearer $ADMIN" -H 'Content-Type: application/json' \
     -X POST https://router/api/v1/tokens \
     -d '{
       "name": "ci-bot",
       "scopes": ["firewall:rules:rw"],
       "expires_in_seconds": 3600,
       "allowed_cidrs": ["10.0.0.0/24"]
     }'
# response: { "bearer": "<cleartext-once>", "name": "ci-bot" }
```

The requested scopes must be a strict subset of the caller's. Escalation
returns `403 scope_escalation_blocked`. The same request with a name
that's already in use returns `409 conflict`.

```sh
curl -H "Authorization: Bearer $ADMIN" https://router/api/v1/tokens
curl -H "Authorization: Bearer $ADMIN" https://router/api/v1/tokens/ci-bot
curl -H "Authorization: Bearer $ADMIN" -X DELETE https://router/api/v1/tokens/ci-bot
```

GET responses never include `salt` or `hash`.

## Inspecting the current token

```sh
curl -H "Authorization: Bearer $TOKEN" https://router/api/v1/auth/whoami
```

Returns `{token_id, scopes, source_ip, expires_at, allowed_cidrs,
last_used_at, last_used_ip}`. No scope check (any authed token can read
its own metadata).

## Using a token

```
Authorization: Bearer <bearer string>
```

Common failure responses:

| HTTP | code                       | Cause                                             | Header          |
|------|----------------------------|---------------------------------------------------|-----------------|
| 401  | `unauthorized`             | missing or malformed Authorization header         | `WWW-Authenticate: Bearer` |
| 401  | `invalid_token`            | bearer not in store, or expired, or wrong source IP | `WWW-Authenticate: Bearer` |
| 403  | `insufficient_scope`       | token's scopes don't cover the request            | -               |
| 403  | `scope_escalation_blocked` | `POST /tokens` requested scopes outside caller's  | -               |
| 429  | `too_many_requests`        | per-token rate limit exceeded                     | `Retry-After: <seconds>` |

## Scope syntax

```
<segment>[:<segment>...]:(rw|ro)
```

Up to three segments (`<domain>:<subresource>:<verb>` for curated,
`raw:<package>:<verb>` for raw). `rw` implies `ro`. `*` is allowed as any
segment for wildcards:

- `*:rw` / `*:ro` - top-level wildcard, matches everything.
- `firewall:*:ro` - mid-tree wildcard, matches every firewall subresource (rules, zones, redirects, forwardings, defaults) but NOT the bare domain.
- `*:rules:ro` - also valid; matches the `rules` subresource of every domain that has one.

At equal depth, an exact segment beats a wildcard segment
(`firewall:rules:rw` wins over `firewall:*:ro` for `/firewall/rules`).

## Scope tree

The authoritative source is `src/lib/scope.uc` `KNOWN_PATHS`.

| Domain | Subresources |
|---|---|
| `*` | any |
| `network` | `interfaces`, `devices`, `routes`, `rules`, `bridge_vlans`, `wireguard_peers` |
| `wireless` | `devices`, `interfaces` |
| `firewall` | `zones`, `rules`, `redirects`, `forwardings`, `defaults` |
| `dhcp` | `hosts`, `leases`, `leases6`, `servers`, `dnsmasq`, `odhcpd` |
| `system` | (singleton), `timeservers`, `password`, `authorized_keys` |
| `dropbear` | `instances` |
| `uhttpd` | `instances`, `certs` |
| `unbound` | `server` |
| `sqm` | `queues` |
| `snmpd` | `agents`, `com2secs`, `groups`, `accesses`, `system` |
| `lldpd` | `config` |
| `prometheus_node_exporter_lua` | `config` |
| `vnstat` | `config`, `interfaces` |
| `packages` | `installed`, `feeds` |
| `uapi` | `tokens`, `metrics`, `diagnostics` |
| `raw` | `<any-package>` (composes with the curated domain tree) |

## Deepest-match-wins

When multiple scopes match a request, the one with the longest matching
prefix decides. `rw` and `ro` at the same depth: `rw` wins.

Examples (assume the request targets `/firewall/rules/r_01HX...`):

| Token scopes                                 | Result   |
|----------------------------------------------|----------|
| `*:rw`                                       | permits  |
| `firewall:rw`                                | permits  |
| `firewall:rules:rw`                          | permits  |
| `firewall:zones:rw`                          | denies   |
| `*:rw`, `firewall:rules:ro` (PUT)            | **denies** (deepest match is `ro`) |
| `*:rw`, `firewall:rules:ro` (GET)            | permits  |
| `firewall:ro`, `firewall:rules:rw` (PUT)     | permits (deeper `rw` wins) |

## Raw access composition

`/raw/<package>/<id>` requires **both** trees to permit, independently:

1. The raw tree: `raw` / `raw:<package>` matches.
2. The domain tree: evaluated against the section's actual type. `firewall.rule` -> `firewall:rules`, `network.interface` -> `network:interfaces`, etc.

A token with `raw:rw` but only `firewall:rules:ro` can read firewall rules
via `/raw/firewall/...` but cannot write them. The domain-tree override
always wins. This is intentional: granting `raw:rw` should not be a
backdoor around carefully-crafted curated scopes.

For packages outside the curated set, the domain check uses
`[<package>]`. Granting `*:rw` or that specific package scope covers it.

## Per-token rate limit

Tokens may carry uci options `option rate '<N>'` and `option burst '<N>'`
on their section in `/etc/config/uapi` to override the global rate-limit
default (100 req/s, burst 200). Per-token override beats global; absent
options inherit. The `uapi-token` CLI does not yet expose these as flags -
edit the uci section or set them in the `POST /tokens` body (not yet
plumbed through; planned for v2.x).

## Recommended token shapes

| Use case                                 | Scopes                                                        | Flags                            |
|------------------------------------------|---------------------------------------------------------------|----------------------------------|
| Terraform admin                          | `*:rw`                                                        | `--expires-in 90d`               |
| Terraform per-domain                     | `firewall:rw`                                                 | `--expires-in 90d`               |
| Read-only dashboard                      | `*:ro`                                                        | `--allowed-cidr <office>`        |
| Monitoring (Prometheus scrape)           | `uapi:metrics:ro`, `uapi:diagnostics:ro`                      | `--allowed-cidr <prom-host>/32`  |
| Short-lived CI job                       | `firewall:rules:rw`, `network:routes:rw`                      | `--expires-in 1h --allowed-cidr <ci>` |
| Operator that mints other tokens         | `uapi:tokens:rw`, plus the scopes it needs to delegate        | `--expires-in 30d`               |
| Long-tail via `/raw/`                    | `*:rw` (or `raw:rw` + the specific domain scopes)             | -                                |
