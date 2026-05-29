# Tokens and scopes

uapi authenticates every request (except `/healthz` and `/openapi.json`) with a bearer token. Tokens are created locally on the router, hashed at rest, and authorized against a hierarchical scope tree.

## Creating tokens

Local CLI only. No HTTP login endpoint, no rpcd sessions.

```sh
uapi-token create --name <label> --scope <scope> [--scope <scope>...] [--force]
```

- `--name`: human-readable label. Must be unique. Surfaces in the audit log when this token performs a write.
- `--scope`: at least one. May repeat. Validated against the known scope tree below; use `--force` to bypass (e.g. for forward-compatibility with a future endpoint).
- Output (stdout): the cleartext bearer string, exactly once. Stderr explains it's the only chance to capture it.

The router stores only the salt + `sha256(salt + ":" + bearer)`. The cleartext cannot be recovered.

```sh
uapi-token list             # short summary of all tokens
uapi-token show <name>      # detailed view (scopes, no secret)
uapi-token revoke <name>    # delete a token
```

## Using a token

```
Authorization: Bearer <bearer string>
```

Failures:

- Missing or malformed header: `401 unauthorized`
- Bearer not in the store: `401 invalid_token`
- Valid token but scopes don't cover the request: `403 insufficient_scope`

## Scope syntax

```
<segment>[:<segment>...]:(rw|ro)
```

Two-segment depth max in v1. `rw` implies `ro`. `*` is allowed as any segment for wildcards:

- `*:rw` / `*:ro`: top-level wildcard, matches everything.
- `firewall:*:ro`: mid-tree wildcard, matches every firewall subresource (rules, zones, redirects) but NOT the bare domain.
- `*:rules:ro`: also valid; matches the `rules` subresource of every domain that has one.

At equal depth, an exact segment beats a wildcard segment (`firewall:rules:rw` wins over `firewall:*:ro` for `/firewall/rules`).

## The v1 scope tree

| Scope                        | Covers                                    |
|------------------------------|-------------------------------------------|
| `*:rw` / `*:ro`              | Everything. Use sparingly.                |
| `network:rw`                 | All `/network/...` endpoints              |
| `network:interfaces:rw`      | Just `/network/interfaces`                |
| `network:devices:rw`         | Just `/network/devices`                   |
| `wireless:rw`                | All `/wireless/...` endpoints             |
| `wireless:devices:rw`        | Just `/wireless/devices`                  |
| `wireless:interfaces:rw`     | Just `/wireless/interfaces`               |
| `firewall:rw`                | All `/firewall/...` endpoints             |
| `firewall:zones:rw`          | Just `/firewall/zones`                    |
| `firewall:rules:rw`          | Just `/firewall/rules`                    |
| `firewall:redirects:rw`      | Just `/firewall/redirects`                |
| `dhcp:rw`                    | All `/dhcp/...` endpoints                 |
| `dhcp:hosts:rw`              | Just `/dhcp/hosts`                        |
| `dhcp:leases:ro`             | Just `/dhcp/leases` (read-only resource)  |
| `system:rw`                  | `/system`                                 |
| `raw:rw`                     | `/raw/<any-package>/...` (plus domain)    |
| `raw:<pkg>:rw`               | `/raw/<pkg>/...` only (plus domain)       |

## Deepest-match-wins

When multiple scopes match a request, the one with the longest matching prefix decides. `rw` and `ro` at the same depth: `rw` wins.

Examples (assume the request targets `/firewall/rules/r_01HX...`):

| Token scopes                                 | Result   |
|----------------------------------------------|----------|
| `*:rw`                                       | permits  |
| `firewall:rw`                                | permits  |
| `firewall:rules:rw`                          | permits  |
| `firewall:zones:rw`                          | denies   |
| `*:rw`, `firewall:rules:ro` (PUT)            | **denies** (deepest match is `ro`) |
| `*:rw`, `firewall:rules:ro` (GET)            | permits  |
| `firewall:ro`, `firewall:rules:rw` (PUT)     | permits  (deeper rw wins) |

## Raw access composition

`/raw/<package>/<id>` requires **both** trees to permit, independently:

1. The raw tree: `raw` / `raw:<package>` matches.
2. The domain tree: evaluated against the section's actual type. `firewall.rule` -> `firewall:rules`, `network.interface` -> `network:interfaces`, etc.

So a token with `raw:rw` but `firewall:rules:ro` can read firewall rules via `/raw/firewall/...` but cannot write them. The domain-tree override always wins. This is intentional: granting `raw:rw` should not be a backdoor around carefully-crafted curated scopes.

For packages outside the curated set, the domain check uses `[<package>]`. Granting `*:rw` or that specific package scope covers it.

## Recommended token shapes for common use cases

| Use case                       | Scopes                                  |
|--------------------------------|------------------------------------------|
| Terraform admin                | `*:rw`                                  |
| Terraform per-domain (firewall)| `firewall:rw`                           |
| Monitoring (read-only)         | `*:ro`                                  |
| Long-tail config via `/raw/`   | `*:rw` (or scope to specific packages)  |
