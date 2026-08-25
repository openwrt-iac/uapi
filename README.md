# uapi

Native, lightweight, production-grade HTTP REST API for OpenWrt. Translates standard REST verbs (GET, POST, PUT, PATCH, DELETE) into ubus/uci operations so modern edge routers become first-class targets for Infrastructure-as-Code workflows. Primary design validation is serving as the backend for the [`openwrt-iac/uapi` Terraform provider](https://registry.terraform.io/providers/openwrt-iac/uapi), but the API is client-agnostic.

> Not affiliated with the OpenWrt project. uapi started as the work of a single operator solving a specific problem on their own network, shared in the open in the hope it is useful to others with similar needs.

- Direct-to-bus: runs as a uhttpd-mod-ucode handler. No daemon, no `/etc/config/` file mangling.
- Atomic transactions (single AND multi-package via `POST /batch`): snapshot, validate, commit, reload, restore-on-failure in a single request.
- Bearer tokens with hierarchical scopes, expiry, source-IP scoping, HTTP-side rotation (`POST /tokens`).
- 45 curated resources plus a generic `/raw/<package>/<id>` passthrough for the long tail.
- Conditional GET (304), idempotency keys, cursor pagination, per-resource ETags + `If-Match`, JSON Patch (RFC 6902), Prometheus `/metrics`, `/diagnostics`.
- OpenAPI 3.1 spec shipped at `/usr/share/uapi/openapi.json` and served at `/api/v3/openapi.json`.

## Why this approach

Prior REST-for-OpenWrt attempts fell into three buckets, each with a structural reason it stalled. Thin wrappers over rpcd or luci-rpc exposed uci's anonymous-section IDs verbatim, so Terraform could never track a resource across applies, and rpcd sessions are awkward for service accounts. Out-of-process daemons in Python or Go drifted the moment LuCI or sysupgrade touched `/etc/config/`, and blew the footprint budget. Centralized config-push platforms (OpenWISP and friends) own the truth from a server and don't slot into a Terraform pull workflow.

uapi sidesteps all three:

- **Lives inside OpenWrt's runtime.** uhttpd-mod-ucode plus direct ubus calls means uci stays the single source of truth: no shadow state, no drift, no extra daemon to babysit.
- **Stable IDs by construction.** uapi-created sections are ULID-named; pre-existing anonymous sections surface as `managed: false` with an explicit `adopt` flow.
- **Atomic transactions with honest failure codes.** Snapshot, validate, commit, reload, restore-on-fail under per-package flocks. Every outcome is a distinct status (`200`, `412`, `422`, `423`, `429`, `500 reload_failed_restored`, `500 reload_failed_unrecovered`).
- **Bearer tokens with hierarchical scopes.** No login dance, no session timeout. Optional expiry + IP scoping + per-token rate limit. Exactly the primitive a CI pipeline wants.

This works now because the substrate finally caught up: `ucode-mod-ubus`, `uhttpd-mod-ucode`, and apk-based packaging all shipped in the last cycle. Older attempts had to pick between lua, Python, and C; uapi picked the right moment to be small.

Target platform: **OpenWrt 25.12+** (apk-based releases).

## Install

Signed APK feed (recommended):

```sh
# uclient-fetch ships with OpenWrt; curl does not, so it is used here
uclient-fetch -qO /etc/apk/keys/uapi-feed.pub.pem \
    https://openwrt-iac.github.io/feed/uapi-feed.pub.pem
echo 'https://openwrt-iac.github.io/feed/packages/all/uapi/packages.adb' \
    > /etc/apk/repositories.d/uapi.list
apk update && apk add uapi
```

Or a local APK file:

```sh
apk add /tmp/uapi-<version>-r1.apk
apk add uapi        # only if this router should keep tracking the feed
```

The second line is not redundant. Installing from a file pins `/etc/apk/world` to that exact
build, and `apk upgrade` then skips uapi silently; `apk add uapi` restores feed tracking. See
`docs/installation.md` for how to tell which state a box is in.

The package's `uci-defaults` hook adds `list ucode_prefix '/api/v3=/usr/share/uapi/main.uc'` to `/etc/config/uhttpd` (the `main` instance) and restarts uhttpd. After that, `/api/v3/healthz` is reachable on the same ports as LuCI.

## First token

```sh
# On the router (local console or SSH):
uapi-token create --name terraform_prod --scope '*:rw' --expires-in 90d
```

The cleartext bearer is printed exactly once. Save it. The router stores only `salt + sha256(salt:bearer)` going forward. Tokens can also carry `--allowed-cidr` (source-IP pinning) and per-token rate-limit overrides.

After the first admin token exists, subsequent tokens can be minted over the wire:

```sh
curl -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
     -X POST https://<router>/api/v3/tokens \
     -d '{ "name": "ci-bot", "scopes": ["firewall:rw"], "expires_in_seconds": 3600 }'
```

Requested scopes must be a strict subset of the caller's (escalation returns `403 scope_escalation_blocked`).

## First request

```sh
TOKEN=<value-from-above>
curl -H "Authorization: Bearer $TOKEN" https://<router>/api/v3/system
curl -H "Authorization: Bearer $TOKEN" https://<router>/api/v3/auth/whoami
```

## Quick demo: add a firewall rule

```sh
curl -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' \
     -X POST https://<router>/api/v3/firewall/rules \
     -d '{
       "target": "ACCEPT",
       "match": { "src_zone": "wan", "dest_port": ["22"], "proto": ["tcp"] }
     }'
```

The response carries the rule's stable `id` (a ULID with a one-character type prefix like `r_01HX...`). That ID survives reorders and rewrites, so Terraform can track it across applies. The response also carries an `ETag` header (use it in `If-Match` on next mutation for optimistic concurrency).

## Docs

Operator-facing:

- `docs/installation.md`: production install, TLS hardening pointers.
- `docs/tokens.md`: scope tree, CLI reference, HTTP token mint, expiry + IP scoping + per-token rate.
- `docs/errors.md`: error envelope, response codes, field-level error codes, response headers.
- `docs/operations.md`: NTP, persistent syslog, `/metrics`, `/diagnostics`, rate limiting.
- `docs/raw.md`: `/raw/<package>/<id>` semantics and stability disclaimer.
- `docs/resources.md`: curated resource catalog.
- `docs/non-uci-state.md`: resources whose source of truth is not `/etc/config/`.
- `docs/migration-v1-to-v2.md`: v1 -> v2 field renames, strict typing, new endpoints, new errors.
- `examples/curl/`: runnable walkthroughs for a subset of resources, one per distinct shape, including the adopt flow for pre-existing config.
- `build/openapi.json` (also `/api/v3/openapi.json` on a live router): the API contract.

Contributor-facing:

- `CONTRIBUTING.md`: dev environment, dev loop, PR style, codebase tour.
- `docs/architecture.md`: fork-per-request model, lock layout, transaction recipe, ETag derivation, where state lives.
- `docs/concurrency.md`: rules and anti-patterns for adding code that survives the fork-per-request model.
- `docs/ucode-quirks.md`: language and runtime gotchas that have each cost a CI iteration on this project.
- `docs/security.md`: threat model, scope tree, TLS posture, token storage, rate-limit guarantees, audit shape.
- `docs/adding-a-resource.md`: how to write a new curated resource module.
- `docs/packaging.md`: building the APK from source against the OpenWrt SDK.
- `docs/release-process.md`: signed tags, reproducible builds, SBOM, multi-arch verification.
- `docs/roadmap.md`: what shipped, what's next, what's intentionally out of scope.
- `docs/lock-state-audit.md`: every fd-open / lock site, release proven on every exit.
- `CLAUDE.md`: the project's design contract (architectural principles, code style, branch/PR workflow) plus the index to the `docs/` topics.
- `CHANGELOG.md`: per-release notes.

## Versioning

uapi follows [semver](https://semver.org/), with the major version aligned to the API major:

- **MAJOR**: breaking on-the-wire change. The URL prefix bumps to `/api/v<x+1>/` to match the wire contract major (standard HTTP idiom). A given uapi installation serves exactly one API major - we do NOT mount `/api/v(x+1)/` alongside `/api/v<x>/` in the same binary; operators who need to keep an old client working keep the previous package version installed. The install hook handles uhttpd prefix migration automatically on `apk upgrade`.
- **MINOR**: backwards-compatible additions. New endpoints, new optional request/response fields, new error codes, new scopes.
- **PATCH**: bug fixes only. No surface change.

Concretely: a client tested against `2.0.0` keeps working against any future `2.y.z`. Pin a minimum minor if you depend on something introduced in it (`apk add 'uapi>=2.0.0'`). See `docs/versioning.md` ("API versioning policy") for the precise list of what counts as a breaking vs additive change, and `docs/migration-v1-to-v2.md` for the v1 -> v2 migration table.

## License

MIT.
