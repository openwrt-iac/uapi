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

### Numeric-looking lookups coerce, but `in` does not

`obj[200]` does find the value stored at `"200"`: bracket access, `exists()` and `delete` all stringify the key first. The `in` operator does not, so `200 in obj` is false where `"200" in obj` is true.

### `for (let v in arr)` iterates values, not indices

```ucode
for (let v in [10, 20, 30]) print(v);   // 10 20 30
```

This is the opposite of JS's `for...in`. If you need an index, use a C-style `for (let i = 0; ...)`.

### `loadfile()` inherits the calling VM's parse mode

`uhttpd-mod-ucode` runs the handler in template mode (`{%`). Loading a raw-script `.uc` module from inside it needs explicit `loadfile(path, { raw_mode: true })`. The `load_resource` helper in `src/main.uc` does this for you.

### `type(null)` returns null, not a string

There is no type name for it: `type(null)` is the null value itself, so `type(x) == "null"` never matches. Test `x == null` directly.

### `==` coerces, as in JavaScript

`false == ""` and `0 == ""` are true, while `false == null` and `0 == null` are false. A test for an empty string written `v == ""` therefore also matches `false` and `0`: in `network.interfaces` it let `sourcefilter: false` pass as an empty value. Write `v === ""` when `v` can be a boolean or a number.

### `match()` and `json()` stop at the first NUL

`match("rule\u0000 x", /^[!-~]+$/)` returns `[ "rule" ]`: an anchored pattern checks only the prefix and passes. uci takes C strings and then stores `rule`. `json()` also cuts an object key at its first NUL, so `{"k\u0000x": 1}` parses as `{ "k": 1 }`. `main.uc` therefore refuses the NUL escape in the request text (`values.json_has_nul`) before any handler runs.

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

### uci writes a section type unquoted

`uci_validate_type` takes any printable ASCII except the space, but the export writes `config <type>` without quotes. A type with `"`, `#`, `'`, `;` or `\` therefore commits and reads back as syntax: `config rule#x 's'` re-reads as an anonymous `rule`, and a quote leaves the package unparseable. Measured on OpenWrt 25.12.5. `src/raw.uc` refuses these five.

### File-handle locking uses single-char flags

```ucode
fd.lock("x")    // LOCK_EX
fd.lock("s")    // LOCK_SH
fd.lock("n")    // LOCK_NB suffix, combine: "xn" for non-blocking exclusive
fd.lock("u")    // LOCK_UN
```

Returns `true` on success, `null` on `EWOULDBLOCK` (with `fs.error()` set). See `transaction.uc::_lock_one()`.

### `network.interface.<x>` `renew` re-applies the config the handler already had

netifd gives a proto handler a copy of the interface config taken when the proto state was attached, and `renew` does not refresh it. A renew issued after a uci write therefore re-applies what was already running, and returns success. netifd also tears the interface down and back up for any proto-config change, so editing a wireguard peer destroys a working tunnel before the new peer list has been validated. uapi applies wireguard peers with `wg` directly for both reasons; see `src/lib/wg.uc`.

### Every daemon parses uci booleans differently

Read a boolean the way its owning daemon reads it, or a GET reports the
operator's intent instead of the daemon's behaviour. The sets do not match, and
netifd's is the strict one:

| Reader | true | false | anything else | uapi helper |
|---|---|---|---|---|
| netifd C, via uci's blob converter | `1`, `true` | `0`, `false` | option **dropped**, daemon default applies | `platform_bool` |
| netifd ucode, `parse_bool` in `/lib/netifd/utils.uc` | `1`, `true` | `0`, `false` | undefined, caller default | `platform_bool` |
| fw4, `parse_bool` in `/usr/share/ucode/fw4.uc` | `1`, `on`, `true`, `yes` | `0`, `off`, `false`, `no` | daemon default | `normalize_bool` |
| shell init scripts, `get_bool` in `/lib/functions.sh` | those plus `enabled` | those plus `disabled` | caller default | `shell_bool` |
| raw compare, `[ "$x" != "1" ]` | `1` | everything else | there is no else | `strict_bool` |
| libvalidate `:bool:` via `uci_validate_section` | unverified | unverified | section **dropped**, see below | `normalize_bool` |

So `option auto 'no'` on an interface does not disable autostart: netifd drops
the value and uses its own `true`.

**Pick the row, do not pick a default.** This table previously said "`platform_bool`
for netifd-owned fields and `normalize_bool` for the rest", and that "the rest"
produced a bug in roughly forty places at once. The worst was `disabled` on a
wireguard peer: `wireguard.sh` reads it with `config_get_bool`, so
`option disabled 'yes'` means disabled, while `platform_bool` reported enabled and
the next write pushed `disabled='0'` to uci and the peer into the kernel. Find the
reader before choosing, and cite it in a comment when it is not obvious.

The libvalidate row is honestly unknown: ubox is not in the SDK feeds, so the
accepted set could not be read. It matters more than the others, because a value
`validate_data` rejects makes the init script drop the **whole section** rather
than fall back to a default (`dropbear.init` and `sysntpd` both do this). Until
someone reads ubox, `normalize_bool` is the conservative guess for those fields:
`system.log_remote`, `system/timeservers`, and dropbear's auth flags.

Writes still emit `"1"` / `"0"`, which every reader above accepts.

A related trap the table cannot catch: an option that is not a boolean at all.
`system.urandom_seed` is the filesystem path the entropy seed is written to, and
`lldpd`'s `lldp_description` is free text. Both were typed boolean, so a write
replaced the operator's value with `"1"`.

### netifd reads integers and lists through the same converter

uci's `blob.c` is also how netifd reads every INT32 and ARRAY option
(`uci_attr_to_blob` and `uci_array_to_blob`), and neither matches the plain reader:

| Option type | What netifd takes | Example | uapi helper |
|---|---|---|---|
| INT32: interface `metric`, `ip6assign`, `ip6weight`; route `metric`, `mtu`; rule `priority`, `goto`; device `mtu`; bridge-vlan `vlan` | `strtol(v, &end, 0)` with nothing left over: hex after `0x`, octal after `0` | `0x10` is 16, `010` is 8, and `16 ` or `08` drop the option | `netifd_int` |
| ARRAY: `ipaddr`, `ip6addr`, `ip6prefix`, `dns`, device and bridge-vlan `ports` | a list as it is, and a scalar split on spaces and tabs | `option dns '192.0.2.1 192.0.2.2'` is two servers | `as_word_list_or_null` |
| Routing table: route `table`, rule `lookup` | `system_resolve_rt_table`: a number through `strtoul` base 0 above 0, then `default`, `main`, `local`, then a name in `/etc/iproute2/rt_tables`; netifd drops the route or rule when nothing resolves | `main` is 254, `0` drops the route | `rt_table_id`, which reads 0 for what does not resolve |

`as_int` reads decimal only, which is right for a reader that parses base 10 and
wrong for netifd. `netifd_int` reads `""` and a value past int32 as null, where
blob.c gives 0 and a truncated number that differs between 32- and 64-bit targets.
A proto script that loops `for a in ${addresses}` splits a scalar the same way as
an ARRAY option. A shell reader that goes through `config_get`, as `wireguard.sh`
does for a peer's `allowed_ips`, also joins a list with spaces, so it splits a
list entry that holds several words, where `as_word_list_or_null` keeps that
entry whole and validation then refuses it.

The reverse also holds: blob.c drops a `list` given to an attribute that is not an ARRAY, so
6rd, map and 464xlat, which declare `ip6prefix` as a string, lose a listed value. That is why
uapi writes one `ip6prefix` as a scalar and only several as a list.

busybox `ip` reports an id above 255 in `/etc/iproute2/rt_tables` as "database
tables is corrupted", and `ip route show table 4255` answers "invalid argument",
while netifd resolves such a name normally. A test that reads tables through `ip`
needs an id of 255 or less.

### Real `ubus` and `uci` modules are `.so` packages

They live in the default `REQUIRE_SEARCH_PATH` ahead of any project paths. Naming a local lib `ubus.uc` shadows nothing because the `.so` wins. uapi calls its abstraction `bus.uc` to avoid the collision.

## When you find a new one

Add it here. The bar is "this would have saved me a CI round-trip if I had seen it first." The list grows; that's how it pays off.
