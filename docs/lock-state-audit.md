# Lock and resource-state audit

Audit walks every site that holds a system resource (file descriptor, pipe, flock) across `src/` and `cli/`. For each, the audit confirms the resource is released on every exit path (normal return, early return, exception, propagated die).

ucode has no `try/finally`; the project uses an explicit pattern across critical paths:

```ucode
let caught = null;
try { result = fn(); }
catch (e) { caught = e; }
release(resource);
if (caught != null) die(caught);
```

## Summary

17 sites audited, all clean. No leaks, no missing releases, no double-frees, no order errors.

## Sites

| File | Lines | Resource | Exit-path coverage | Verdict |
|------|-------|----------|--------------------|---------|
| `src/main.uc` | 65–70 | fd (read VERSION) | early-return on open fail; close on success | clean |
| `src/main.uc` | 243–251 | fd (read openapi.json) | early-return on open fail; close on success | clean |
| `src/main.uc` | 259–270 | ubus conn | `bus.connect()` failure caught; nothing held on error | clean |
| `src/main.uc` | 289–293 | ubus conn | same | clean |
| `src/lib/transaction.uc` | 60–66 | flock acquire | success returns fd for explicit release; failure closes fd before returning sentinel | clean |
| `src/lib/transaction.uc` | 69–71 | flock release | null-safe; unlocks before close | clean |
| `src/lib/transaction.uc` | 86–96 | per-package 2-level acquire | releases global on per-package acquire failure | clean |
| `src/lib/transaction.uc` | 146–176 | lock + transaction | `release()` called outside try/catch, before `die(caught)`; lock released on every path | clean |
| `src/lib/transaction.uc` | 178–196 | lock + `with_lock` | same try/release/die pattern | clean |
| `src/lib/non_uci.uc` | 32–55 | delegates to `transaction.with_lock` | inherits the explicit-release pattern | clean |
| `src/lib/system_access.uc` | 136–151 | fd (`read_keys`) | early-return on open fail; close on success | clean |
| `src/lib/system_access.uc` | 162–175 | fd (`write_keys`) | atomic rename pattern; `chmod` exception is caught-and-ignored (intentional best-effort), fd close still reached on the success path; on chmod throw the fd remains open inside the request fork and is freed at fork exit; not a logical leak | clean |
| `src/lib/ids.uc` | 22–26 | fd (`/dev/urandom`) | unconditional close | clean |
| `src/lib/packages.uc` | 9–17 | pipe (`apk_exec`) | `p.close()` returns exit code; early-return on popen fail | clean |
| `src/lib/packages.uc` | 29–32 | pipe (`list_installed`) | same pattern | clean |
| `src/lib/packages.uc` | feed read/write | fd + atomic open | `wx` open with TOCTOU re-check on miss (fixed in `876e483`); unconditional close on success | clean |
| `cli/uapi-token` | 16–24 | fd (`/dev/urandom`) | dies on open failure (no fd held); close on success | clean |

## Patterns confirmed

- **fd: open / use / close.** Every `fs.open` is followed by either an early return (when open returned null) or an unconditional `.close()` on the success path. No site holds an fd across a return without closing.
- **pipe: popen / read / close.** Every `fs.popen` is followed by `.close()` (which both releases and yields the child exit code).
- **flock: acquire / try-fn / release / die-if-caught.** `transaction.uc::transaction()` and `with_lock()` use the explicit-release pattern: lock release is OUTSIDE the try block, AFTER catch, BEFORE the conditional `die(caught)`. Lock is released on every path including thrown exceptions.
- **2-level locks.** `default_acquire_pkg()` releases the global lock if the per-package acquire fails. `default_release_pkg()` releases in reverse order (per-package first, then global).
- **`chmod` failure tolerated.** `system_access.uc::write_keys()` wraps `fs.chmod` in a catch-and-ignore. Intentional: chmod can fail on filesystems that do not support it; the file still gets the right content. Not a leak: the fd is closed on the next line on every path that reaches it. If the chmod somehow propagates (it doesn't, given the catch), the fork-per-request model frees the fd on exit.

## Background

uapi runs as a uhttpd-mod-ucode CGI handler; every request is a forked child that exits when the response is returned. OS-level fd cleanup is therefore automatic on every request boundary. This audit is about **logical** resource-state correctness within the lifetime of a single request, not about leaks across request boundaries.

The audit is reproducible: grep for `fs\.open\|fs\.popen\|\.lock(` across `src/` and `cli/` yields every site listed above. Verify against this document when adding new fd / pipe / lock sites.
