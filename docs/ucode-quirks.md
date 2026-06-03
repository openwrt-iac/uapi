# ucode quirks that have bitten this project

A running list of [ucode](https://ucode.mein.io/) and OpenWrt-runtime behaviors that look like JavaScript but aren't. Each one has cost at least one CI iteration to debug. Read this before touching ucode in this repo.

ucode is OpenWrt's native scripting language. It powers `uhttpd-mod-ucode` (which serves uapi) and the build-time `gen_openapi.uc`. Most things work like JavaScript; the surprises are below.

## Language

### No function hoisting AND no late binding

```ucode
function g() { f(); }     // <- ERROR when called: "left-hand side is not a function"
function f() { ... }
```

`g` captures the still-unset binding for `f` at its own declaration site. Define helpers BEFORE callers. For mutual recursion, forward-declare with `let A; let B;` and assign function expressions; `let` bindings are read at call time.

### No `try / finally`, only `try / catch`

Cleanup with the explicit pattern:

```ucode
let caught = null;
try {
    do_work();
} catch (e) {
    caught = e;
}
cleanup_must_run_either_way();
if (caught != null) die(caught);
```

`transaction.uc::transaction()` is the canonical example.

### No destructuring

`let [a, b] = arr;` and `let {x, y} = obj;` do not parse. Write `let a = arr[0]; let b = arr[1];`.

### `die(value)` flattens to string in `e.message`

When caught, `e.message` is a string. Rich exception objects do not survive. Use return-based error signaling (`{ ok: false, kind: "..." }`) instead of throwing custom-typed errors.

### Strings are not indexable

`s[i]` does not return a character. Use `substr(s, i, 1)` or `ord(s, i)`.

### Object literal keys must be strings

`{ "200": "OK" }` is fine; `{ 200: "OK" }` is not. Status codes and similar numeric keys are stringly-typed in this codebase.

### Numeric-looking lookups need string coercion

`obj[200]` does NOT find the value stored at `"200"`. Coerce: `obj["" + status]`.

### `for (let v in arr)` iterates values, not indices

```ucode
for (let v in [10, 20, 30]) print(v);   // 10 20 30
```

This is the opposite of JS's `for...in`. If you need an index, use a C-style `for (let i = 0; ...)`.

### `loadfile()` inherits the calling VM's parse mode

`uhttpd-mod-ucode` runs the handler in template mode (`{%`). Loading a raw-script `.uc` module from inside it needs explicit `loadfile(path, { raw_mode: true })`. The `load_resource` helper in `src/main.uc` does this for you.

### `type(null)` returns the string `"(null)"`

Not `"null"`. Don't rely on the return value being JSON-shaped.

### `const` is real

`const X = ...` is parsed and enforced. Top-level data tables in this repo are mostly `const`.

## OpenWrt runtime integration

### uhttpd CGI Status header needs a reason phrase

`Status: 200 OK` works; `Status: 200` is silently dropped and the response defaults to 200. Always include the reason.

### uhttpd-mod-ucode loads handlers in template mode

The entry script must start with `{%` and define `global.handle_request(env)`. Module-level code runs once at uhttpd startup in the parent VM; each request is a forked child that inherits that VM via copy-on-write.

### `cursor.get(pkg, sect)` returns the section TYPE, not the dict

To get the option dict, use `cursor.get_all(pkg, sect)`. This codebase wraps the call in `bus.uci_get` which does the right thing.

### `cursor.export` / `cursor.import` do not exist in ucode-mod-uci

The snapshot/restore mechanism in `transaction.uc` uses file IO on `/etc/config/<pkg>` plus `cursor.unload(pkg); cursor.load(pkg)`. If you need a snapshot somewhere new, use the existing helpers.

### `ucode-mod-digest` exports `digest.sha256(s)` directly

It returns the hex digest. There is no separate `sha256_hex`.

### `cursor.set(pkg, name, type)` (three args) creates a named section

Prefer this over `cursor.add` + `cursor.rename` when you want a specific name from the start. uapi uses ULID-named sections for everything it creates.

### File-handle locking uses single-char flags

```ucode
fd.lock("x")    // LOCK_EX
fd.lock("s")    // LOCK_SH
fd.lock("n")    // LOCK_NB suffix, combine: "xn" for non-blocking exclusive
fd.lock("u")    // LOCK_UN
```

Returns `true` on success, `null` on `EWOULDBLOCK` (with `fs.error()` set). See `transaction.uc::_lock_one()`.

### Real `ubus` and `uci` modules are `.so` packages

They live in the default `REQUIRE_SEARCH_PATH` ahead of any project paths. Naming a local lib `ubus.uc` shadows nothing because the `.so` wins. uapi calls its abstraction `bus.uc` to avoid the collision.

## When you find a new one

Add it here. The bar is "this would have saved me a CI round-trip if I had seen it first." The list grows; that's how it pays off.
