# Adding a curated resource

This is the workflow we used for every resource in `src/resources/`. Following it should take an hour for a typical config type.

The reference implementations live in `src/resources/`; `firewall.rules.uc` is the most-featured (cross-reference validation, nested `match` block) and `system.uc` is the simplest (singleton, flat fields).

## 1. Pick the uci package and section type

Look at `/etc/config/<package>` on a real router. Find the section type you want to expose. Note the option names, which are lists vs. scalars, which are uci-bools (`"1"`/`"0"`/`"on"`/`"off"`), and which reference other sections.

## 2. Create the resource module

`src/resources/<package>.<plural-type>.uc`. Schemas live inline in the resource module, not in separate JSON Schema files. `schema_properties` is the centrally-enforced type/enum/range/pattern/items table (`handler.check_schema_types` walks it on every write and returns 422 on shape mismatches before `validate()` runs); `validate()` carries the cross-field, cross-section, and format-string logic that pure JSON Schema can't express (e.g. "src_zone must reference an existing zone").

Export the uniform contract:

```ucode
return {
    package: "<package>",              // uci package
    type: "<section-type>",            // uci section type
    reload: ["<service>"],             // ubus services to reload on write
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
    id_for_create:   function(body) { ... return null; },  // runs only when body.id is unset; return a proto-specific name (e.g. wireguard's wg_<rand> short fallback) or null to fall through to ULID
    create_if_missing: true,           // singletons only; opt-in. PATCH creates the uci section if absent instead of returning 404. See "Singletons that may be wiped" below.
    singleton_section_name: "main",    // singletons only; default "main". Override only when the underlying uci convention names the section differently.
    unique_field: "name",              // optional. Value of this field must be unique among same-type sections in this package. See "Cross-section reference fields" below.
};
```

### Section name (`id`) at create time

Every CRUD resource accepts an optional `id` field at create time as of 2.2.0; you do not need to opt in. The framework reads `body.id`, runs section-name validation (charset `^[A-Za-z][A-Za-z0-9_]{0,31}$`, in-package uniqueness across all section types), and uses it as both the uci section name and the response `id`. When the caller omits `id`, the framework falls back to a server-emitted ULID (or the result of your module's `id_for_create` hook if you registered one).

`id_for_create` is the place to inject proto-specific fallbacks. `network/interfaces` uses it to emit a 14-char `wg_<rand>` for `proto=wireguard` because Linux IFNAMSIZ caps netifd's netdev name at 15 chars. Most resources don't need this hook; the default ULID is fine.

If your resource type binds the section name to something kernel- or daemon-constrained beyond the framework's 32-char default cap, tighten in your own `validate()` (per-resource refinement runs after the framework check).

### Singletons that may be wiped (`create_if_missing`)

For resources whose underlying uci package can be deleted by an operator without uapi noticing (typical pattern: an extension package whose conffile is the only source of the section, like the unbound-uci-ext packages uapi 2.1.0 introduced), set `create_if_missing: true` on the resource module. `handler.make_singleton.patch` then creates the uci section on the fly instead of returning 404. The created section's name defaults to `main`; override via `singleton_section_name` if the daemon expects a different convention.

Most singletons (`system`, `dhcp/dnsmasq`, `firewall/defaults`, etc.) should NOT opt in: their config sections ship with the package they wrap, and a missing section there is a real problem worth surfacing as 404 so the operator notices.

### Cross-section reference fields (`unique_field`)

If your resource has a uci option whose VALUE other sections reference (rather than referencing this section by its section id), or whose duplication would break the daemon, declare it with `unique_field`. The framework rejects creates and modifies whose value collides with another section's, returning `422 conflict` with the offending section named in the error message.

Concrete shapes that need this flag:

- `firewall/zones.name`: fw4 keys forwardings, rules, and redirects on this value (`src_zone = "lan"` refers to the zone whose `name` option is `lan`, not its section id).
- `network/devices.name`: netifd uses this as the kernel netdev name; `network/interfaces.device` references it.
- `sqm/queues.interface`: tc cannot disambiguate two queues bound to the same interface.

What does NOT need the flag:

- Resources identified by their section id (`network/interfaces`, `wireless/devices`, etc.). The framework's existing section-id uniqueness check already covers them.
- Fields that are human-readable labels with no semantic meaning to the daemon (`firewall/rules.name`, `firewall/redirects.name`).
- Singletons (the section name is immutable and the resource is not referenced by value).
- Fields that an OpenWrt convention DELIBERATELY allows to repeat across sections. Example: `snmpd.config group` sections share `option group` across multiple `(version, secname)` bindings as part of net-snmp's VACM model; that is not a duplicate to reject. Audit the upstream default config before declaring the flag on a new resource.

The flag is scope-correct: same package, same section type. A `firewall.zone` with `name="lan"` does not conflict with a `firewall.rule` with `name="lan"` because different daemons read different fields. The check runs on `POST`, `PUT`, and `PATCH`; PATCH and PUT exclude the section being modified, so updates that keep the value unchanged still pass.

The flag is string-only. The runtime check guards `type(val) == "string"` so non-string fields are silently skipped today; if your resource has a numeric or list-typed cross-reference key, the helper would need extending. Dynamic-type resources (those that declare `type_predicate` to match a family of section types like `wireguard_<iface>`) cannot declare `unique_field`; the framework will refuse to load such a module so the latent footgun does not ship.

Resources that have their own per-validate uniqueness logic (e.g. `dhcp/servers` checks `interface` inside `validate()`) can keep that logic in place; `unique_field` is opt-in.

### Server-side defaults (`default:`) and clear-on-omit safety (`x-uapi-clear-on-omit:`)

If your `fromUci` synthesizes a value for an absent uci option (via `normalize_bool(section.X, true)`, `section.X ?? "literal"`, or similar), declare the same fallback as `default:` in the field's `schema_properties` entry:

```ucode
auto: { type: "boolean", default: true,
        description: "Bring this interface up at boot" },
```

This is standard OpenAPI 3.1 / JSON Schema 2020-12 documentation. Clients (Redoc, openapi-codegen, Terraform provider) read it to understand which fields the server populates on their behalf. The runtime validator at `handler.uc:_check_value` does NOT apply `default:`; it is purely documentation. fromUci owns server-side defaults; the framework MUST NOT silently fill absent fields from the spec or PATCH-delta semantics break.

Only annotate **unconditional** defaults. Conditional defaults (e.g. `network.interfaces.peerdns` defaults to true only under `proto=dhcp`) stay un-annotated because the literal value misleads under other protos.

For a field that is **caller-owned and safe for an IaC client to clear by omitting it from config**, also add `"x-uapi-clear-on-omit": true`:

```ucode
netmask: { type: ["string", "null"], "x-uapi-clear-on-omit": true,
           description: "IPv4 netmask (static proto)" },
```

A Terraform provider can read this flag and emit explicit JSON null on Update when the operator's config omits the attribute, which clears the uci option. The flag enforces two hard constraints (the framework's `lint-defaults` verifies both):

1. **fromUci shape**: the field's assignment in fromUci's returned dict must be exactly `<jsonkey>: section.<ucikey> ?? null`. No `as_list()` (returns `[]` for null, not null itself), no derivation, no aliasing to another field. The Terraform plugin-framework rejects the apply with "Provider produced inconsistent result after apply" if a plain Optional attribute reads back any value for an absent uci option other than null.

2. **Nullable type**: the `type:` declaration must include `"null"` (e.g. `type: ["string", "null"]`). The provider sends explicit JSON null to clear; a non-nullable type fails the spec itself.

Safe (passes the lint):

```ucode
gateway: { type: ["string", "null"], "x-uapi-clear-on-omit": true,
           description: "IPv4 default gateway (static proto)" },
```

```ucode
// fromUci: gateway: section.gateway ?? null
```

Unsafe (lint fails):

```ucode
// fromUci: dns: as_list(section.dns)      <-- returns []; lint shape violation
// fromUci: ipaddr: ipaddr_first           <-- derived; lint shape violation
```

```ucode
// schema:  dns: { type: "array", "x-uapi-clear-on-omit": true }   <-- non-nullable; lint type violation
```

Conservative scope: only annotate when there is **evidence** a field is leftover-prone (e.g. survives an adopt + proto switch). The initial set in 2.2.3 is `network/interfaces` `netmask` and `gateway`. The originally-considered set in 2.2.2 also included `ipaddr`/`ipaddrs`/`dns`, but those fail the shape/type constraints above and were dropped; see `docs/deprecations.md` and the openwrt-iac/uapi#3 thread for the design discussion on how to handle the aliased/array-typed cases.

A field cannot be both `default:` and `"x-uapi-clear-on-omit": true`. Defaulted fields would cause perpetual non-converging diffs if the provider treats them as clearable (apply clears uci, fromUci re-defaults, next plan diffs again). Either the field has a server-side default (sticky) or the operator fully owns it (clearable); never both.

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

## Curation completeness

When adding or extending a curated resource, the test is: *does this resource expose the options that a typical real configuration of this section actually sets?* If a common real-world setup of this section requires uci options the curated resource does not surface, that is a curation gap; close it. Telling users to drop to `/raw/` for a routine field is a smell.

## Validation should not be stricter than the platform

uapi's `validate()` is for catching client mistakes early (typos, missing required fields, cross-resource references that won't resolve) and for surfacing well-formed `422` errors instead of letting uci fail mid-commit. It is NOT a venue for inventing constraints the underlying uci/netifd/daemon doesn't have.

Concrete recurring temptation: "this bridge has no ports / this firewall rule has no match / this static interface has no ipaddrs, surely that's an error?" Sometimes it is, sometimes the operator is staging an incremental configuration (Terraform's create-before-reference ordering, an empty bridge whose members get added later, an interface that's intentionally up but unconfigured). uapi 2.2.0-rc2 fixed exactly this antipattern in `network.devices` (a `type=bridge` without `ports` was being rejected even though uci/netifd accept it without complaint). Don't add a `validate()` check just because something "feels off"; first check whether uci accepts it. If uci does, uapi should too.

If a real protocol-level constraint applies (e.g. `proto=wireguard` genuinely cannot work without a `private_key`, the kernel will reject it), that's worth catching upfront. If it's just "feels incomplete to me", let the platform decide.

## Things to watch for

- ucode does not hoist function declarations. Define helpers before callers.
- `cursor.get(pkg, sect)` returns the section *type* as a string. The dict requires `cursor.get_all(pkg, sect)`. Our `bus.uci_get` already does the right thing.
- ucode-mod-uci has no `cursor.export`/`cursor.import`. Snapshot/restore is file IO via `bus.uci_export`/`uci_import`.
- Resources are loaded with `{raw_mode: true}` from the template-mode main.uc handler. They should be raw-script (`.uc` files starting with code, not `{%`).

See [`docs/ucode-quirks.md`](ucode-quirks.md) for the full running list of language and runtime gotchas.
