# Lock and resource-state audit

Audit walks every site that holds a system resource (file descriptor, pipe, flock) across `src/` and `cli/`. For each, the audit confirms the resource is released on every exit path within a single request: normal return, early return, exception, propagated die.

ucode has no `try/finally`; the project uses an explicit pattern across critical paths:

```ucode
let caught = null;
try { result = fn(); }
catch (e) { caught = e; }
release(resource);
if (caught != null) die(caught);
```

Reproducing the audit: `grep -rn 'fs\.open\|fs\.popen\|\.lock(' src/ cli/` yields the canonical list.

## Summary

**Partial: 17 of the 36 sites the command above finds.** Every site in the table
below releases correctly on every in-request exit path, and that claim is good. What
is not good is the coverage: this said "17 sites audited" without qualification until
2.5.0, while its own reproduction command returned 36. Nine modules appear nowhere in
the table (`error_ring`, `idempotency`, `metrics`, `mgmt`, `ratelimit`, `token_store`,
`dhcp.leases`, `dhcp.leases6`, `dhcp.servers`), and roughly seven of the line ranges
below have drifted from the code they name. `mgmt.uc` is the illustration: it landed
in 2.5.0 with an `fs.popen` and this document went on asserting it had audited
everything.

Completing it is tracked in `docs/roadmap.md` under Hardening. Until then, read this
as an audit of the transaction and token paths, not of the tree.

## Sites

| File | Lines | Resource | Why it's correct |
|------|-------|----------|------------------|
| `src/main.uc` | 65-70 | fd (read VERSION) | early-return on open fail; close on success |
| `src/main.uc` | 243-251 | fd (read openapi.json) | same shape |
| `src/main.uc` | 259-270 | ubus conn | `bus.connect()` failure caught; nothing held on error |
| `src/main.uc` | 289-293 | ubus conn | same |
| `src/lib/transaction.uc` | 60-66 | flock acquire | success returns fd for explicit release; failure closes fd before returning sentinel |
| `src/lib/transaction.uc` | 69-71 | flock release | null-safe; unlocks before close |
| `src/lib/transaction.uc` | 86-96 | per-package 2-level acquire | releases global on per-package acquire failure |
| `src/lib/transaction.uc` | 146-176 | lock + transaction | `release()` called outside try/catch, before `die(caught)` |
| `src/lib/transaction.uc` | 178-196 | lock + `with_lock` | same try/release/die shape |
| `src/lib/non_uci.uc` | 22-48 | delegates to `transaction.with_lock` | inherits the explicit-release pattern |
| `src/lib/system_access.uc` | 136-151 | fd (`read_keys`) | early-return on open fail; close on success |
| `src/lib/system_access.uc` | 162-175 | fd (`write_keys`) | atomic-rename pattern (see below) |
| `src/lib/ids.uc` | 22-27 | fd (`/dev/urandom`) | `if (!f) die(...)` before deref; close on success |
| `src/lib/packages.uc` | 9-17 | pipe (`apk_exec`) | `p.close()` returns exit code; early-return on popen fail |
| `src/lib/packages.uc` | 29-32 | pipe (`list_installed`) | same |
| `src/lib/packages.uc` | feed write | fd + `wx` O_EXCL | TOCTOU re-check on `wx` miss (fixed in `876e483`); unconditional close on success |
| `cli/uapi-token` | 16-24 | fd (`/dev/urandom`) | dies on open failure (no fd held); close on success |

## Tricky case: `system_access.uc::write_keys()`

```ucode
let tmp = KEYS_PATH + ".uapi.tmp";
try { fs.unlink(tmp); } catch (e) {}
let f = fs.open(tmp, "w");
if (!f) return false;
try { fs.chmod(tmp, 384); } catch (e) {}  // 0600
f.write(content);
f.close();
```

Three exit paths to verify, in order:

1. `fs.open` returns null: early return; no fd held.
2. `fs.chmod` throws: caught and discarded; `f.write` then `f.close` still run in order on the next two lines; fd released. The chmod tolerance is deliberate (some filesystems return EPERM); content correctness is the priority and the file gets the default umask permissions in that case.
3. Normal path: `f.write` + `f.close` run unconditionally on the line after the chmod try-catch.

Subsequent `fs.rename(tmp, KEYS_PATH)` is also wrapped in try/catch; failure cleans up `tmp` and returns false. Atomic-rename property is preserved.

## Patterns confirmed

- **fd: open / use / close.** Every `fs.open` is followed by either an early return (when open returned null) or an unconditional `.close()` on the success path. No site holds an fd across a return without closing.
- **pipe: popen / read / close.** Every `fs.popen` is followed by `.close()` (which both releases and yields the child exit code).
- **flock: acquire / try-fn / release / die-if-caught.** `transaction.uc::transaction()` and `with_lock()` release the lock OUTSIDE the try block, AFTER catch, BEFORE the conditional `die(caught)`.
- **2-level locks.** `default_acquire_pkg()` releases the global lock if the per-package acquire fails. `default_release_pkg()` releases in reverse order (per-package, then global).

## The wireguard peer apply

`wg.uc` shells out to `wg set` after the commit, inside the locked region, to push peer changes to the kernel (see `docs/architecture.md` § Transaction recipe step 7). Two things about it are load-bearing here.

The preshared key is staged at a fixed path, `/var/run/uapi.wg.psk`, rather than a unique one. That is safe only because every uci transaction holds the per-package exclusive lock for `network`, so two peer applies can never be in flight at once. If that lock discipline ever changes, this needs a unique path. Mode `0600` is set before the content is written, following the same order as the authorized-keys writer above, and the file is unlinked immediately after the command returns.

`wg show <iface> dump` is read on the reconcile path only. Its second field is the peer's preshared key, so that output must never be logged or surfaced in an error message.

## Scope

This audit is about **logical** resource-state correctness within the lifetime of a single request. The fork-per-request model provides OS-level fd cleanup at fork exit as a backstop, but the audit does not rely on that backstop: every site listed above releases explicitly inside the request.
