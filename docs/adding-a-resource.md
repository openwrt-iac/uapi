# Adding a curated resource

This is the workflow we used for every resource in `src/resources/`. Following it should take an hour for a typical config type.

The reference implementations live in `src/resources/`; `firewall.rules.uc` is the most-featured (cross-reference validation, nested `match` block) and `system.uc` is the simplest (singleton, flat fields).

## 1. Pick the uci package and section type

Look at `/etc/config/<package>` on a real router. Find the section type you want to expose. Note the option names, which are lists vs. scalars, which are uci-bools (`"1"`/`"0"`/`"on"`/`"off"`), and which reference other sections.

## 2. Create the resource module

`src/resources/<package>.<plural-type>.uc`. Export the uniform contract:

```ucode
return {
    package: "<package>",              // uci package
    type: "<section-type>",            // uci section type
    reload: ["<service>"],             // ubus services to reload on write
    depends_on: ["<pkg>:<type>"],      // optional; mix referenced sections into ETag
    fromUci: function(section, conn) { ... }, // uci section dict -> response JSON
    toUci:   function(json) { ... },          // request JSON -> uci option dict
    validate: function(json, conn, id) { ... return []; }, // {field, code, message}[]
    schema_properties: { ... },        // type/enum/min/max/pattern/items; enforced centrally

    // OpenAPI hints (consumed by build/gen_openapi.uc, not by the runtime):
    openapi_required:    ["field1", "field2"],    // emitted as `required: [...]` on the JSON Schema
    openapi_conditional: [                        // emitted as `allOf: [...]`; if/then/required
        { if:   { properties: { proto: { const: "static" } } },
          then: { required: ["ipaddr"] } },
    ],
    openapi_runtime: {                            // replaces the opaque `runtime: {type: object}`
        type: "object",
        properties: { up: { type: "boolean" }, ... },
        description: "Populated from ubus ...",
    },

    // Optional, less common:
    merge_for_patch: function(existing, existing_json, body) { ... },  // nested-object merge
    type_predicate:  function(t) { ... },  // dynamic-type resources (e.g. wireguard_<iface>)
    create_type:     function(body) { ... },
    id_prefix: "x",                    // single char for generated IDs (defaults to type[0])
};
```

`fromUci` and `toUci` form a (lossy) bijection: round-tripping a section
through both should produce the same uci options. `fromUci` may take a
second `conn` arg to read ubus state for the `runtime: {...}` block;
resources that don't need it ignore the extra arg.

`validate` runs on every write inside the per-package flock. It must
return an array of errors (each `{field, code, message}`), one per
problem; the caller translates to a `422` response. Codes come from a
fixed set: `required`, `invalid_type`, `invalid_format`, `out_of_range`,
`not_in_enum`, `conflict`, `read_only`.

`schema_properties` is the source of truth for type/enum/min/max/pattern/items
shape checks - the central `handler.check_schema_types` walks this on every
write and 422s shape mismatches BEFORE `validate()` runs. Per-field
constraints that fit (type, enum, range, pattern, items recursion) belong
here; cross-field / cross-section / format-string logic stays in `validate()`.

`depends_on: ["firewall:zone"]` mixes the hash of every `firewall.zone`
section into this resource's ETag. Use it when a write to the referenced
type should invalidate dependent ETags (`firewall.rules` -> `firewall:zone`,
`sqm.queues` -> `network:interface`, etc.). See `docs/architecture.md`
"ETag derivation" for the full mechanism.

`openapi_required`, `openapi_conditional`, `openapi_runtime` are picked
up by `build/gen_openapi.uc` and produce a richer machine-readable
contract for code generators (Terraform provider, OpenAPI client libs).
The runtime never reads them. Mirror what `validate()` enforces:
unconditional `if (json.X == null) push(errs, {required})` goes in
`openapi_required`; `if (json.proto == "static" && json.ipaddr == null)`
becomes an `openapi_conditional` `if/then/required` block. For resources
that populate a non-empty `runtime: {...}`, define its sub-shape in
`openapi_runtime` so clients can see the keys without reading source.

For cross-reference validation (e.g. "this firewall rule's `src_zone` must be a real zone"), use the `conn` argument. See `firewall.rules.uc`'s `load_zones(conn)` for the pattern.

## 3. JSON conventions

Per CLAUDE.md:

- `snake_case` field names.
- Stable `id` at top level (set by the dispatcher; your `fromUci` provides it from `section['.name']`).
- `managed: bool` at top level. Derive from `!section['.anonymous']`.
- Normalize uci booleans to JSON booleans on the way out; emit `"1"`/`"0"` on the way in.
- Lift single-value uci list options to JSON arrays (a uci list with one element comes through as a string from `cursor.get`; coerce to an array).
- Nest related fields where it improves readability. `firewall.rules` uses `match: {src_zone, dest_zone, src_ip, ...}` rather than a flat top-level. This pays off in the Terraform mapping.
- Runtime/computed fields go under `runtime: {...}`. Currently empty for most resources; populate when ubus exposes useful data.

### Where snake_case stops

uapi mirrors uci option names verbatim, EXCEPT for the v2.0 rename
sweep (`dropbear`, `snmpd`, `vnstat`) and a handful of Terraform-
collision renames in rc4 (`mwan3.interfaces.count` -> `probe_count`,
`firewall.{zones,defaults}.output` -> `output_policy`,
`unbound.server.resource` -> `resource_limits`,
`network.interfaces.runtime.ipv4-address` -> `ipv4_address`).

Smushed uci names (`dynamicdhcp`, `commonname`, `expandhosts`,
`boguspriv`, `readethers`, `domainneeded`, `leasefile`, `resolvfile`,
`defaultroute`, `clientid`, `reqprefix`, `agentaddress`, `localservice`,
`linklayer`, `zonename`, etc.) are KEPT verbatim. Two reasons:

1. **uci fidelity.** A field named `expandhosts` greps cleanly against
   `/etc/config/dhcp`; renaming to `expand_hosts` would split the
   mental model between the API surface and what an operator sees on
   the router.
2. **The rename cost is real.** Every wire-surface rename takes a
   migration-guide entry, breaks downstream clients, and forces an
   RC cycle. The consistency gain doesn't pay for the disruption when
   the existing name is already canonical to uci.

Two name shapes WILL be renamed:

- **Terraform reserved or HCL block keywords** (the rc4 batch above).
  These don't work as Terraform attributes.
- **Names that mislead** (e.g. `dhcp.servers.runtime.active_leases_v4_total`
  was renamed to `active_leases_v4_box_total` in rc2 because the
  original name suggested per-server semantics for a box-wide counter).

If you're curating a new uci option, default to the uci name. If it
collides with a Terraform/HCL keyword or actively misleads, rename
and document.

### Write-only fields: `<field>` + `has_<field>` convention

Sensitive fields (passphrases, private keys, PSKs) follow a uniform
pattern: the field is **write-only** on the wire, and a read-only
companion `has_<field>: bool` indicates presence on GET responses.

Examples:

- `wireless.interfaces.key` / `has_key`
- `network.wireguard_peers.private_key` / `has_private_key`
- `network.wireguard_peers.preshared_key` / `has_preshared_key`
- `openvpn.instances.key` / `has_key`
- `openvpn.instances.tls_auth` / `has_tls_auth`
- `openvpn.instances.pkcs12` / `has_pkcs12`

Implementation: `fromUci` masks the field (`key: null` or omit) and
sets `has_key: section.key != null && section.key != ""`. `toUci`
passes the field through when present. `merge_for_patch` carries the
old value forward so an unrelated PATCH (e.g. changing `verb` on an
openvpn instance) doesn't wipe the credential when the field is absent
from the request body.

Mark the field `writeOnly: true` and the companion `readOnly: true` in
`schema_properties` so a generator can distinguish them statically.

## 4. Add unit tests

`tests/unit/<package>_<type>_test.uc`. Test `fromUci`, `toUci` (including round-trip), and `validate` for required-missing, enum-violation, and format cases.

For cross-reference validation, use the `bus` stub:

```ucode
let bus = require('bus');
let c = bus.stub({
    uci: { firewall: { z_lan: { '.type': 'zone', name: 'lan' } } }
});
let errs = mod.validate({ ... }, c);
```

## 5. Register the resource

`src/main.uc` has a `RESOURCES` registry (CRUD) and a `SINGLETONS` registry (single-section types like `system`). Both use the two-arg `load_resource` form so the source module is registered into `RESOURCE_SOURCES` (which backs `/schema/<...>`):

```ucode
"<domain>:<plural-type>": handler.make(load_resource("<domain>:<plural-type>", "<package>.<plural-type>.uc")),
```

Use `handler.make_singleton` for singletons, `handler.make_collection`
for read-only runtime lists. Writable resources also automatically
become eligible for `POST /batch` via main.uc's `BARE_RESOURCES` /
`BARE_SINGLETONS` construction loop - no extra step needed. Read-only
collections are excluded from batch (they have no `toUci`).

## 6. Add an integration test

`tests/integration/<NN>_<resource>_test.sh`. Use the install helper:

```sh
. tests/integration/lib/install_uapi.sh
install_uapi
# ADMIN_TOKEN, RO_TOKEN, FW_RO_TOKEN are exported.
# Drive via curl; check status code and key fields in the response body.
```

Cover at least: POST creates, GET reads, validation failure returns 422, DELETE returns 204.

## 7. Regenerate OpenAPI

```sh
make openapi
```

This walks the resource modules and emits `build/openapi.json`. Add an entry for the new resource in `build/gen_openapi.uc`'s `ENDPOINTS` list. The lint job in CI gates against drift, so commit the regenerated `openapi.json` alongside the resource.

## 8. Add a curl example

`examples/curl/<resource>.sh`. One POST + GET + PATCH cycle, ending with a "to delete: ..." reminder.

## 9. Update docs/tokens.md

If the new resource introduces a new scope path (e.g. a new package), add it to the scope tree table.

## Things to watch for

- ucode does not hoist function declarations. Define helpers before callers.
- `cursor.get(pkg, sect)` returns the section *type* as a string. The dict requires `cursor.get_all(pkg, sect)`. Our `bus.uci_get` already does the right thing.
- ucode-mod-uci has no `cursor.export`/`cursor.import`. Snapshot/restore is file IO via `bus.uci_export`/`uci_import`.
- Resources are loaded with `{raw_mode: true}` from the template-mode main.uc handler. They should be raw-script (`.uc` files starting with code, not `{%`).

See [`docs/ucode-quirks.md`](ucode-quirks.md) for the full running list of language and runtime gotchas.
