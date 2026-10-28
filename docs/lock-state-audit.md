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

**Partial: 16 of the 36 sites the command above finds.** Every site in the table
below releases correctly on every in-request exit path, and that claim is good. What
is not good is the coverage: this said "17 sites audited" without qualification until
2.5.0, while its own reproduction command returned 36. Nine modules appear nowhere in
the table (`error_ring`, `idempotency`, `metrics`, `mgmt`, `ratelimit`, `token_store`,
`dhcp.leases`, `dhcp.leases6`, `dhcp.servers`), and neither does
`transaction.uc::multi_transaction()`. `mgmt.uc` is the illustration: it landed
in 2.5.0 with an `fs.popen` and this document went on asserting it had audited
everything.

Completing it is tracked in `docs/roadmap.md` under Hardening. Until then, read this
as an audit of the transaction and token paths, not of the tree.

## Sites

| File | Lines | Resource | Why it's correct |
|------|-------|----------|------------------|
| `src/main.uc` | 101-107 | fd (read VERSION) | early-return on open fail; close on success |
| `src/main.uc` | 787-791 | fd (read openapi.json) | same shape |
| `src/main.uc` | 250-257 | ubus conn | `bus.connect()` failure caught; nothing held on error |
| `src/main.uc` | 835-840 | ubus conn | same |
| `src/lib/transaction.uc` | 118-124 | flock acquire | success returns fd for explicit release; failure closes fd before returning sentinel |
| `src/lib/transaction.uc` | 126-128 | flock release | null-safe; unlocks before close |
| `src/lib/transaction.uc` | 147-164 | per-package 2-level acquire | releases the global and the per-package locks it holds when one per-package acquire fails |
| `src/lib/transaction.uc` | 252-313 | lock + transaction | `release()` called outside try/catch, before `die(caught)` |
| `src/lib/transaction.uc` | 428-446 | lock + `with_lock` | same try/release/die shape |
| `src/lib/non_uci.uc` | 23-48 | delegates to `transaction.with_lock` | inherits the explicit-release pattern |
| `src/lib/non_uci.uc` | 71-94 | fd (`replace_private_file`) | atomic-rename pattern (see below) |
| `src/lib/ids.uc` | 21-27 | fd (`/dev/urandom`) | `if (!f) die(...)` before deref; close on success |
| `src/lib/packages.uc` | 9-17 | pipe (`apk_exec`) | `p.close()` returns exit code; early-return on popen fail |
| `src/lib/packages.uc` | 29-32 | pipe (`list_installed`) | same |
| `src/lib/packages.uc` | feed write | fd + `wx` O_EXCL | TOCTOU re-check on `wx` miss (fixed in `876e483`); unconditional close on success |
| `cli/uapi-token` | 20-29 | fd (`/dev/urandom`) | dies on open failure (no fd held); close on success |

## Tricky case: `non_uci.uc::replace_private_file()`

```ucode
let tmp = path + ".uapi.tmp";
try { fs.unlink(tmp); } catch (e) {}
let f = fs.open(tmp, "w");
if (!f) return false;
try { fs.chmod(tmp, 384); } catch (e) {}  // 0600
let written = f.write(content);
let flushed = f.flush();
f.close();
if (written != length(content) || !flushed) {
	try { fs.unlink(tmp); } catch (e) {}
	return false;
}
```

Four exit paths to verify, in order:

1. `fs.open` returns null: early return; no fd held.
2. `fs.chmod` throws: caught and discarded; `f.write` then `f.close` still run in order on the next two lines; fd released. The chmod tolerance is deliberate (some filesystems return EPERM); content correctness is the priority and the file gets the default umask permissions in that case.
3. Normal path: `f.write`, `f.flush` and `f.close` run unconditionally after the chmod try-catch, so the fd is released before the result is judged.
4. Short or failed write: ucode's `close()` drops `fclose`'s result, so a filesystem that runs out of space shows up only as a short count or a failed `flush`. Either one unlinks the temp file and returns false. Until 3.1.0 nothing checked, and an empty temp file was renamed over the original.

Subsequent `fs.rename(tmp, path)` is also wrapped in try/catch; failure cleans up `tmp` and returns false. Atomic-rename property is preserved.

## Patterns confirmed

- **fd: open / use / close.** Every `fs.open` is followed by either an early return (when open returned null) or an unconditional `.close()` on the success path. No site holds an fd across a return without closing.
- **pipe: popen / read / close.** Every `fs.popen` is followed by `.close()` (which both releases and yields the child exit code).
- **flock: acquire / try-fn / release / die-if-caught.** `transaction.uc::transaction()` and `with_lock()` release the lock OUTSIDE the try block, AFTER catch, BEFORE the conditional `die(caught)`.
- **2-level locks.** `default_acquire_pkg()` takes the per-package lock of the write and, for a write that restarts unbound, the one of `unbound`. If one of them fails, it releases the per-package locks that it holds and the global lock. `default_release_pkg()` releases in reverse order (per-package, then global).

## The wireguard peer apply

`wg.uc` shells out to `wg set` after the commit, inside the locked region, to push peer changes to the kernel (see `docs/architecture.md` § Transaction recipe step 7). Two things about it are load-bearing here.

The preshared key is staged at a fixed path, `/var/run/uapi.wg.psk`, rather than a unique one. That is safe only because every uci transaction holds the per-package exclusive lock for `network`, so two peer applies can never be in flight at once. If that lock discipline ever changes, this needs a unique path. Mode `0600` is set before the content is written, following the same order as `replace_private_file` above, and the file is unlinked immediately after the command returns.

`wg show <iface> dump` is read on the reconcile path only. Its second field is the peer's preshared key, so that output must never be logged or surfaced in an error message.

## Scope

This audit is about **logical** resource-state correctness within the lifetime of a single request. The fork-per-request model provides OS-level fd cleanup at fork exit as a backstop, but the audit does not rely on that backstop: every site listed above releases explicitly inside the request.
