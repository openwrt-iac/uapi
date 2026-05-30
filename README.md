# uapi

Native, lightweight, production-grade HTTP REST API for OpenWrt. Translates standard REST verbs (GET, POST, PUT, PATCH, DELETE) into ubus/uci operations so modern edge routers become first-class targets for Infrastructure-as-Code workflows. Primary design validation is serving as the backend for a custom Terraform provider, but the API is client-agnostic.

- Direct-to-bus: runs as a uhttpd-mod-ucode handler. No daemon, no `/etc/config/` file mangling.
- Atomic transactions: snapshot, validate, commit, reload, restore-on-failure in a single request.
- Hashed bearer tokens with hierarchical scopes (`firewall:rules:rw`, `*:ro`, etc.).
- 10 curated resources plus a generic `/raw/<package>/<id>` passthrough for the long tail.
- OpenAPI 3.1 spec shipped at `/usr/share/uapi/openapi.json` and served at `/api/v1/openapi.json`.

## Why this approach

Prior REST-for-OpenWrt attempts fell into three buckets, each with a structural reason it stalled. Thin wrappers over rpcd or luci-rpc exposed uci's anonymous-section IDs verbatim, so Terraform could never track a resource across applies, and rpcd sessions are awkward for service accounts. Out-of-process daemons in Python or Go drifted the moment LuCI or sysupgrade touched `/etc/config/`, and blew the footprint budget. Centralized config-push platforms (OpenWISP and friends) own the truth from a server and don't slot into a Terraform pull workflow.

uapi sidesteps all three:

- **Lives inside OpenWrt's runtime.** uhttpd-mod-ucode plus direct ubus calls means uci stays the single source of truth: no shadow state, no drift, no extra daemon to babysit.
- **Stable IDs by construction.** uapi-created sections are ULID-named; pre-existing anonymous sections surface as `managed: false` with an explicit `adopt` flow.
- **Atomic transactions with honest failure codes.** Snapshot, validate, commit, reload, restore-on-fail under a global flock. Every outcome is a distinct status (`200`, `422`, `423`, `500 reload_failed_restored`, `500 reload_failed_unrecovered`).
- **Bearer tokens with hierarchical scopes.** No login dance, no session timeout. Exactly the primitive a CI pipeline wants.

This works now because the substrate finally caught up: `ucode-mod-ubus`, `uhttpd-mod-ucode`, and apk-based packaging all shipped in the last cycle. Older attempts had to pick between lua, Python, and C; uapi picked the right moment to be small.

Target platform: **OpenWrt 25.12+** (apk-based releases).

## Install

```sh
# On the router, after dropping the .apk:
apk add /tmp/uapi-<version>-r1.apk
```

The package's `uci-defaults` hook adds `list ucode_prefix '/api/v1=/usr/share/uapi/main.uc'` to `/etc/config/uhttpd` (the `main` instance) and reloads uhttpd. After that, `/api/v1/healthz` is reachable on the same ports as LuCI.

## First token

```sh
# On the router (local console or SSH):
uapi-token create --name terraform-prod --scope '*:rw'
```

The cleartext bearer is printed exactly once. Save it. The router stores only `salt + sha256(salt:bearer)` going forward.

## First request

```sh
# From wherever:
TOKEN=<value-from-above>
curl -H "Authorization: Bearer $TOKEN" https://<router>/api/v1/system
```

## Quick demo: add a firewall rule

```sh
curl -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' \
     -X POST https://<router>/api/v1/firewall/rules \
     -d '{
       "target": "ACCEPT",
       "match": { "src_zone": "wan", "dest_port": ["22"], "proto": ["tcp"] }
     }'
```

The response carries the rule's stable `id` (a ULID with a one-character type prefix like `r_01HX...`). That ID survives reorders and rewrites, so Terraform can track it across applies.

## Docs

- `docs/packaging.md`: building the APK from source against the OpenWrt SDK.
- `docs/installation.md`: production install, TLS hardening pointers.
- `docs/tokens.md`: scope tree, hierarchical overrides, CLI reference.
- `docs/errors.md`: error envelope, response codes, field-level error codes.
- `docs/operations.md`: NTP, persistent syslog, audit log forwarding.
- `docs/raw.md`: `/raw/<package>/<id>` semantics and stability disclaimer.
- `docs/adding-a-resource.md`: how to write a new curated resource module.
- `examples/curl/`: one shell script per resource demonstrating CRUD.
- `CLAUDE.md`: the v1 design contract (everything above the implementation).
- `build/openapi.json` (also `/api/v1/openapi.json` on a live router): the API contract.

## Versioning

uapi follows [semver](https://semver.org/), with the major version aligned to the API major:

- **MAJOR**: breaking change. A new major (e.g. `2.0.0`) means `/api/v2/` mounts alongside `/api/v1/` and both run for at least one OpenWrt release cycle; the on-the-wire contract has changed and clients must migrate.
- **MINOR**: backwards-compatible additions. New endpoints, new optional request/response fields, new error codes, new scopes.
- **PATCH**: bug fixes only. No surface change.

Concretely: a client tested against `1.2.0` keeps working against any future `1.y.z`. Pin a minimum minor if you depend on something introduced in it (`apk add 'uapi>=1.2.0'`). See `CLAUDE.md` "API versioning policy" for the precise list of what counts as a breaking vs additive change.

## License

MIT.
