# Adding a curated resource

This is the workflow we used for every resource in `src/resources/`. Following it should take an hour for a typical config type.

The reference implementations live in `src/resources/`; `firewall.rules.uc` is the most-featured (cross-reference validation, nested `match` block) and `system.uc` is the simplest (singleton, flat fields).

## 1. Pick the uci package and section type

Look at `/etc/config/<package>` on a real router. Find the section type you want to expose. Note the option names, which are lists vs. scalars, which are uci-bools (`"1"`/`"0"`/`"on"`/`"off"`), and which reference other sections.

## 2. Create the resource module

`src/resources/<package>.<plural-type>.uc`. Export the uniform contract:

```ucode
return {
    package: "<package>",         // uci package
    type: "<section-type>",        // uci section type
    reload: ["<service>"],         // ubus services to reload on write
    fromUci: (section) => {...},   // uci section dict -> response JSON
    toUci: (json) => {...},        // request JSON -> uci option dict
    validate: (json, conn) => [],  // returns array of {field, code, message}
    schema_properties: { ... },    // optional; OpenAPI enrichment (enums/formats)
};
```

`fromUci` and `toUci` form a (lossy) bijection: round-tripping a section through both should produce the same uci options.

`validate` runs on every write. It must return an array of errors (each `{field, code, message}`), one per problem; the caller decides whether to translate to a `422` response. The codes come from a fixed set: `required`, `invalid_type`, `invalid_format`, `out_of_range`, `not_in_enum`, `conflict`, `read_only`.

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

`src/main.uc` has a `RESOURCES` registry (CRUD) and a `SINGLETONS` registry (single-section types like `system`). Add a line:

```ucode
"<domain>:<plural-type>": handler.make(load_resource("<package>.<plural-type>.uc")),
```

Use `handler.make_singleton` for singletons, `handler.make_collection` for read-only runtime lists.

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

See `memory/project_ucode_quirks.md` (auto-loaded into Claude Code sessions on this project) for the full running list of gotchas.
