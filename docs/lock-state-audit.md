# Lock and resource-state audit

This audit lists every site in `src/` and `cli/` that takes a file descriptor, a pipe, an flock, a ubus connection or a uci cursor. For each site it records which paths release the resource (normal return, early return, error, a propagated `die()`) and what happens on a path that does not.

uapi runs fork-per-request (`docs/concurrency.md`). A descriptor that a request does not close ends with the request process. That backstop does not cover a lock that a child process still holds, a lock held across a long operation, or a file left on disk, so those are what the proofs below look at.

ucode has no `try/finally`. The critical paths use this pattern:

```ucode
let caught = null;
try { result = fn(); }
catch (e) { caught = e; }
release(resource);
if (caught != null) die(caught);
```

## Reproducing the audit

```sh
grep -rnE '\.(open|fdopen|popen|opendir|mkstemp|pipe|writefile|lock|connect|cursor)\(|uloop\.|_lock_one\(|acquire\(' src/ cli/
```

The alternatives catch, in order: `fs.open` and `fs_mod.open`, the other `fs` calls that return a handle or write a file, `fd.lock`, `bus.connect` and `ubus_mod.connect`, `uci_mod.cursor`, any use of uloop, and the two lock entry points inside `src/lib/transaction.uc` (`_lock_one(` and the injected `acquire(`).

The earlier command was `grep -rn 'fs\.open\|fs\.popen\|\.lock(' src/ cli/`. It found 36 lines, one of them a comment. It missed every ubus connection, every uci cursor, the two `fs_mod.open` calls of the snapshot and the restore in `src/lib/bus.uc`, and the places where `multi_transaction()`, `transaction()` and `with_lock()` take their locks, because those call `_lock_one()` or `acquire()` and not `.lock(` itself.

The pattern leaves out three things on purpose. `fs.readfile` and `fs.lsdir` return a value and hold nothing. Calls to `transaction()`, `multi_transaction()` and `with_lock()` from other modules take a lock, but they release it through the entry point's own proof, so they are listed by function in [What runs while a lock is held](#what-runs-while-a-lock-is-held) rather than as sites. `system()` and the ubus `defer`, `subscriber` and `listener` calls hold resources too, but nothing in the tree uses them.

`make lint-lock-audit` runs the command above, as written here, and fails when a site is in no row of the table below, when a site is in two rows, when a row holds no site, or when a "covers all N sites" count in this file or in `CLAUDE.md` is not the number of lines the command prints.

## Summary

**This audit covers all 56 sites that the command finds.** It used to cover 16 of the 36 lines that the earlier command found, and nine modules were absent from it: `error_ring`, `idempotency`, `metrics`, `mgmt`, `ratelimit`, `token_store`, `dhcp.leases`, `dhcp.leases6` and `dhcp.servers`.

Every descriptor, pipe and lock below is released on every in-request exit path. What the audit did find is listed under [Open findings](#open-findings): a request that uhttpd kills can stop between its commit and its reload, the restore rewrites the package file in place and does not check that its data reached the disk, concurrent idempotency stores share one temp file name, the uci cursor shares its delta directory with the `uci` command, some files outlive the token or key they belong to, a request with no token can add metric files, and `uapi-token` takes no uapi lock.

## Sites

| File | Lines | Resource | Release proof |
|------|-------|----------|---------------|
| `src/main.uc` | 103-109 | fd, `/usr/share/uapi/VERSION`, at module load in the uhttpd parent | A failed open returns `"unknown"` and holds nothing. Otherwise the fd is closed before the return. |
| `src/main.uc` | 145-155 | ubus connection and uci cursor, at module load in the uhttpd parent | A failed connect is caught and the defaults are used. The connection is never disconnected, and a ucode ubus connection keeps a reference to itself, so it outlives the last script reference. It is closed by the `ucv_gc()` that uhttpd's ucode plugin runs once after it loads the handler, before the first fork. The handler loads before uhttpd calls `uloop_init()`, so the socket is never in uhttpd's event loop. |
| `src/main.uc` | 252-269 | ubus connection and uci cursor, `/healthz` | A failed connect is caught and reported as degraded. Otherwise the connection lives until the request process exits, which closes the socket. Nothing else shares it. |
| `src/main.uc` | 277-284 | fd, `/proc/uptime`, `/healthz` | A failed open skips the uptime. Otherwise the fd is closed right after one line is read. |
| `src/main.uc` | 694-701 | fd, `/proc/uptime`, `/diagnostics` | Same shape. |
| `src/main.uc` | 789-802 | fd, `/usr/share/uapi/openapi.json` | A failed open answers 404. Otherwise the fd is closed before the response is built. |
| `src/main.uc` | 859-864 | ubus connection and uci cursor, one per request | A failed connect answers 503 and holds nothing. Otherwise both live until the request process exits. The cursor holds no file between calls, because libuci opens and closes the package file inside each load and commit. Staged changes stay in the cursor's memory until a commit or a revert, which libuci starts with a save into the delta directory, so a request that dies before its commit or its revert leaves nothing staged. See the delta-directory finding below for the commit and revert paths. |
| `src/lib/bus.uc` | 15-21 | ubus connection and uci cursor, created by `bus.connect` | A failed connect dies before any handle exists. The returned object owns both for the rest of the request. |
| `src/lib/bus.uc` | 91-97 | fd, `/etc/config/<pkg>` read for the snapshot | A failed open returns an empty snapshot, which a restore would write over the package. The pre-flight checked moments before that the file exists. Otherwise the fd is closed before the return. The read takes no libuci lock, which is safe because libuci replaces the file with a rename, so the read sees either the old file or the new one. |
| `src/lib/bus.uc` | 98-106 | fd, `/etc/config/<pkg>` written by the restore | A failed open dies, and the restore wrapper in `_finalize_after_reload()` turns that into `reload_failed_unrecovered`. Otherwise the fd is closed before the reload. The write truncates the file in place and is not checked, see [Open findings](#open-findings). |
| `src/lib/transaction.uc` | 49-63 | pipe, `/etc/init.d/<svc> reload` | A failed popen returns a message. Otherwise `p.close()` always runs after the read and yields the exit code. `read("all")` returns at end of file, so a reload whose descendants keep the pipe's write end open holds the write, and its locks, until they close it. Only uhttpd's script timeout bounds that. |
| `src/lib/transaction.uc` | 118-124 | lock fd, `_lock_one()` | A failed open returns `{ unavailable }` and holds nothing. A refused `LOCK_NB` closes the fd and returns null. Otherwise the fd goes to the caller, who releases it with `_release_one()`. |
| `src/lib/transaction.uc` | 126-128 | lock release, `_release_one()` | Null-safe. `LOCK_UN` before the close is what makes the release complete: the lock files are opened without `O_CLOEXEC`, so every child started under the lock holds a copy of the descriptor, and an flock belongs to the open file description. A close alone would leave the lock held for as long as any child, or a daemon a child started, keeps its copy. `LOCK_UN` releases it for every copy. |
| `src/lib/transaction.uc` | 132-134 | global EX, `default_acquire()` | Returns the `_lock_one()` result unchanged. `default_release()` releases it with `_release_one()`. |
| `src/lib/transaction.uc` | 150-167 | global SH and per-package EX, `default_acquire_pkg()` | Takes the global SH, then the EX of the package and of each package in `also`, in sorted order. When one fails it releases the per-package locks it already holds and the global one, then returns the contention or the unavailable path. `default_release_pkg()` releases the per-package locks, then the global one. |
| `src/lib/transaction.uc` | 255-316 | lock taken by `transaction()` | The pre-flight checks run before the lock, so their early returns hold nothing. Each contention or unavailable result returns before the try. Inside the try run the unload, the snapshot, `fn`, the revert or the commit, the reload, the stay-up watch, the kernel apply and the restore. `release(lock)` runs after the catch and before `die(caught)`. A throw after the commit would skip the restore, but nothing on that path throws today: the watch and the kernel apply catch their ubus errors, and `_finalize_after_reload()` catches the restore's. |
| `src/lib/transaction.uc` | 324-429 | global SH and per-package EX, `multi_transaction()` | Validation and the missing-config check return before any lock. The per-package EX are taken in sorted order, the stay-up daemons included, and each failure releases what is held before it returns. The try covers the snapshots, `fn`, the revert or the commits, the apply and the restore. The release loop runs after the catch and before `die(caught)`. |
| `src/lib/transaction.uc` | 431-449 | global EX, `with_lock()` | A contention or unavailable result returns before the try. `release(lock)` runs after the catch and before `die(caught)`. |
| `src/lib/non_uci.uc` | 71-94 | fd and temp file, `replace_private_file()` | See [the tricky case](#tricky-case-non_ucireplace_private_file) below. Every exit path closes the fd, and every failure path unlinks the temp file. |
| `src/lib/ids.uc` | 21-27 | fd, `/dev/urandom` | A failed open dies before any fd exists. Otherwise the fd is closed right after the read. |
| `src/lib/packages.uc` | 10-18 | pipe, `apk <args>` | A failed popen returns an error result. Otherwise `p.close()` always runs and yields the exit code. Under the global EX for add, del and update, and under no lock for the reads. |
| `src/lib/packages.uc` | 25-45 | pipe, `apk info` | A failed popen returns `[]`. Otherwise the pipe is closed right after the read. No lock. |
| `src/lib/packages.uc` | 156-171 | fd per feed file | A failed open gives an empty URL. Otherwise the fd is closed after one line. No lock. |
| `src/lib/packages.uc` | 173-186 | fd, one feed file | A failed open answers 404. Otherwise the fd is closed after one line. No lock. |
| `src/lib/packages.uc` | 210-238 | fd, a new feed file, `wx` | Under the global EX. `O_EXCL` refuses a file another writer created after the `stat`, and a failed open answers 409 or 500. Otherwise the fd is closed before the write is judged. A short write or a failed flush unlinks the file and answers 500 before `apk update` runs, so a retry does not find the file. |
| `src/lib/mgmt.uc` | 20-28 | pipe, `ip route get <addr>` | A failed popen returns null. Otherwise the pipe is closed after one line, and `ip` has exited or exits once it writes that line. A single write resolves this before its transaction. Inside `/batch` it runs under the batch's locks, because each sub-request runs inside `fn`. |
| `src/lib/idempotency.uc` | 59-68 | file, the sweep marker | `fs.writefile` opens, writes and closes in one call. A failed write leaves the old marker, so the next store sweeps again. |
| `src/lib/idempotency.uc` | 70-96 | fd, a cache entry | A directory that is not this process's own is a miss. A failed open is a miss. Otherwise the fd is closed before the JSON parse. |
| `src/lib/idempotency.uc` | 98-119 | fd and temp file, a cache entry | A directory that is not this process's own stores nothing. The temp file is created 0600 in a directory with mode 0700, because an entry can carry a secret. The fd is closed before the rename. A size on disk short of the entry, which is how a full `/tmp` shows, or a failed rename unlinks the temp file and leaves no entry. At most once an hour, a store also unlinks the entries older than the TTL. |
| `src/lib/token_store.uc` | 23-31 | fd, `/dev/urandom` | A failed open dies before any fd exists. Otherwise the fd is closed right after the read. |
| `src/lib/token_store.uc` | 97-105 | fd, creating `/etc/config/uapi` | Closed right after the open. Only `create()` calls it, inside its transaction, and `transaction()` has already refused a missing `/etc/config/uapi` by then, so the branch that creates the file does not run over HTTP. |
| `src/lib/token_store.uc` | 225-251 | fd, the last-used marker, then a `uapi` transaction | The marker is opened, written empty and closed before the transaction. The transaction then releases its lock through `transaction()`. The marker is written first, so a 423 on the transaction still throttles the next minute. |
| `src/lib/metrics.uc` | 68-75 | fd, one counter | A failed open reads as 0. Otherwise the fd is closed after one line. |
| `src/lib/metrics.uc` | 77-89 | fd and temp file, one counter | A failed open returns false. Otherwise the fd is closed before the rename, and a failed rename unlinks the temp file and returns false. Two writers of one counter share the temp file, and each writes a single line, so the first line stays a whole count and only increments are lost, which the module accepts. |
| `src/lib/error_ring.uc` | 14-23 | fd, the ring | A failed open reads as `[]`. Otherwise the fd is closed before the parse. |
| `src/lib/error_ring.uc` | 25-43 | fd and temp file, the ring | The whole body is in a try that swallows everything. The temp file is named after the pid of the request process, so two appends at once write separate files, and the later rename wins. A failed open returns. Otherwise the fd is closed before the rename, and a failed rename unlinks the temp file. |
| `src/lib/ratelimit.uc` | 14-31 | fd, one bucket | A failed open is no state. Otherwise the fd is closed before the parse. |
| `src/lib/ratelimit.uc` | 33-45 | fd and temp file, one bucket | A failed open returns false. Otherwise the fd is closed before the rename, and a failed rename unlinks the temp file, as in the error ring and the metrics. |
| `src/lib/system_access.uc` | 48-56 | pipe, `busybox passwd`, write end | Under the global EX. A failed popen answers 500. Otherwise both writes run and `p.close()` yields the exit code. A `passwd` that exits early makes the writes fail with `EPIPE` rather than kill the request, because uhttpd ignores `SIGPIPE` and the request process inherits that. |
| `src/lib/wg.uc` | 34-40 | pipe, `wg` and `ip` commands | A failed popen returns an error result. Otherwise `p.close()` always runs after the read. Runs under the transaction's lock for `network`. |
| `src/lib/wg.uc` | 120-137 | fd and file, `/var/run/uapi.wg.psk` | See [the wireguard peer apply](#the-wireguard-peer-apply). The fd is closed before the write is judged. A short write or a failed flush unlinks the file and returns null, which fails the apply. Otherwise `set_peer()` unlinks the file once `wg` returns. |
| `src/resources/dhcp.leases.uc` | 24-30 | fd, `/tmp/dhcp.leases` | A failed open reads as no leases. Otherwise the fd is closed before the parse. No lock. |
| `src/resources/dhcp.leases6.uc` | 59-65 | fd, the odhcpd lease file | A failed open returns null, and the caller tries the other path. Otherwise the fd is closed before the parse. No lock. |
| `src/resources/dhcp.servers.uc` | 10-16 | fd, a lease file | A failed open reads as empty. Otherwise the fd is closed before the count. No lock. |
| `cli/uapi-token` | 20-29 | fd, `/dev/urandom` | A failed open dies before any fd exists. Otherwise the fd is closed right after the read. |
| `cli/uapi-token` | 86-92 | fd, creating `/etc/config/uapi` | A failed open dies. Otherwise the fd is closed right after the open. |
| `cli/uapi-token` | 94-146 | uci cursor, `create` | Freed when the command exits. The commit takes no uapi lock, so it does not serialize with a write of the HTTP path to `/etc/config/uapi`. See the open findings. |
| `cli/uapi-token` | 148-157 | uci cursor, `list` | Read only. Freed when the command exits. |
| `cli/uapi-token` | 159-178 | uci cursor, `show` | Read only. Freed when the command exits. |
| `cli/uapi-token` | 189-204 | uci cursor, `revoke` | Same as `create`. |

## What runs while a lock is held

Every uapi lock is taken with `LOCK_NB`, so no request waits for one. A request that finds it taken answers 423 at once. libuci's own flocks on a package file block, so a load or a commit waits while LuCI or a shell holds them. How long a lock is held is set by what runs under it:

| Entry point | Locks | Callers | Held across |
|-------------|-------|---------|-------------|
| `transaction()` | global SH, EX of the package, EX of `unbound` for a write that restarts it | `handler.uc` create, replace, patch, remove, adopt and the singleton patch. `raw.uc` create, replace, patch and remove. `token_store.uc` create, remove and `update_last_used()`, which a GET reaches. | `fn` with its ubus reads, the commit, `/etc/init.d/<svc> reload` for each service, the stay-up watch, `wg set` and `ip route` for wireguard peers. After a failed reload or apply: the restore, a second reload, a second watch and the kernel reconcile. |
| `multi_transaction()` | global SH, EX of each package of the batch and of `unbound` when the batch restarts it | `main.uc` `/batch` | Every sub-request, including the `ip route get` of a management-path guard, then one commit, reload, watch and apply for the whole set, and the same restore. |
| `with_lock()` | global EX | `packages.uc` install, remove, feed create, feed remove. `system_access.uc` password, key add, key replace, key remove. `crontab.uc` add and remove. | `apk add`, then `apk update` and `apk add` again when the first add fails. `apk del`. A feed write or unlink followed by `apk update`. `busybox passwd`. A rewrite of `authorized_keys`. A crontab rewrite, `/etc/init.d/cron reload`, and on failure the old crontab and a second reload. |

Two of these hold a lock longer than the write itself takes.

- **The stay-up watch sleeps under the lock.** A reload of `unbound` or `unbound-uci-ext` with a running daemon polls `service list` every 100 ms for up to 2 s (the `sleep()` in `default_watch()`), still holding the global SH and the EX locks. The restore runs the watch again. While it waits, every non-uci write answers 423. The watch needs the lock, because another writer's restart of unbound would read as a stop.
- **The apk paths hold the global EX across network I/O.** `apk add`, `apk update` and the retry fetch from the feeds, and uapi sets no timeout of its own. Every uci write answers 423 until apk returns. Only uhttpd's script timeout (60 s unless configured) ends the request, and apk then keeps the lock through its copy of the descriptor until it exits, see the next section.

## When the request process is killed

uhttpd sends `SIGKILL` to the request process when the client closes the connection before the response, and when its script timeout expires (60 s unless `script_timeout` is set). A Terraform interrupt or a client-side timeout does the first. No release code runs, so this is where the sites rely on process exit:

- **The request's own descriptors, ubus connection and uci cursor** close at exit. That is safe, because nothing else holds them, unless the kill comes inside a commit or a revert, after libuci saved the request's changes into the delta directory.
- **A lock** is released at exit only when no other process holds a copy of its descriptor. The lock files are opened without `O_CLOEXEC`, so a child that runs under the lock (an init script, `apk`, `passwd`, `wg`, `ip`) holds one. The lock then stays taken until that child exits. For `apk` and for a reload this keeps the serialization while the child still works, which is the useful side. A daemon that such a child starts outside procd, and that keeps inherited descriptors, holds the lock until it exits.
- **Temp files** are not removed by an exit. A request killed between the open and the rename leaves `<file>.uapi.tmp` beside `/etc/crontabs/root` or `/etc/dropbear/authorized_keys`, which crond and dropbear do not read and the next write unlinks first, `/var/run/uapi.wg.psk` (mode 0600, unlinked by the next peer write that stages a key), a `.tmp` file in `/tmp/uapi-metrics`, `/tmp/uapi-ratelimit` or `/tmp/uapi-idempotency`, which the next write of the same name replaces and no reader opens, and `ring.json.<pid>` in `/tmp/uapi-error-ring`, which only a later request with the same pid replaces, so each such kill can leave one copy of the ring until reboot. A kill inside libuci's commit leaves `/etc/config/.<pkg>.uci-XXXXXX` on flash, which libuci never lists and nothing removes.
- **The transaction itself** is not safe, see the first open finding.

## Open findings

These are recorded here, not fixed. A finding leaves this list when it is fixed, and the CHANGELOG entry of the fix describes it.

- **A killed request stops the recipe where it is.** `transaction.uc::run_inner()` commits, then reloads, checks and restores, all in the request process. If uhttpd kills that process during the reload, uci keeps the new config, no stay-up check or restore runs, and the client gets no answer. Scenario: a client times out or is interrupted during `PUT /network/interfaces/wan` and closes its connection while `/etc/init.d/network reload` runs, and a reload that then fails leaves the box on whatever the daemon could make of the new config, with no `reload_failed_restored` and no restore. The same holds for `multi_transaction()` and for the crontab apply in `crontab.uc`.
- **The restore writes the package file in place.** `bus.uc`'s `uci_import` opens `/etc/config/<pkg>` with `"w"`, which truncates it, then writes the snapshot without checking the result, and takes no libuci lock on the file. A kill between the truncation and the write leaves the package empty on flash, and so can a power cut before the data is written back, as nothing calls `fsync`. A write that the overlay cannot hold leaves it truncated, and the restore still reloads it and answers `reload_failed_restored`. A LuCI or shell `uci commit` of the same package during the restore can read the half-written file, because libuci's flock on that file is not taken. `replace_private_file()` already has the shape this needs: a temp file in the same directory, a checked flush, then a rename.
- **Concurrent idempotency stores share one temp file.** `idempotency.uc::store()` writes the entry of a token and key through one fixed name, `<hash>.json.tmp`. Two stores of the same token and key at the same moment open the same file, each truncating it, and write through their own offsets into one inode. When the shorter entry lands last, the file holds it followed by the tail of the longer one, which is not JSON, and the entry then reads as a miss. The error ring had the same shape and lost every recent error to it.
- **The uci cursor shares its delta directory with the `uci` command.** `bus.uc::connect()` creates the cursor with libuci's defaults, so it reads and writes staged changes in `/tmp/.uci`, where a shell `uci set` stages them. A read then reports a value that is staged and not committed. A commit by uapi commits it. The revert after a refused write, in `run_inner()` and `multi_transaction()`, deletes every staged change of that package, the shell's included. Scenario: an operator runs `uci set firewall.@defaults[0].input=DROP` and has not committed. `GET /firewall/defaults` reports `DROP` while `/etc/config/firewall` and fw4 hold `ACCEPT`, and a refused firewall write then deletes the staged change. LuCI is not affected, because rpcd keeps a delta directory per session.
- **Files that outlive their token or key.** Two directories grow until reboot, which is RAM on tmpfs, as the rate-limit buckets did before revocation reaped them. `metrics.uc` keeps one counter file per label set, `uapi_requests_total` and `uapi_rate_limit_drops_total` carry `token_id`, and a revoke removes none of them, so each ephemeral token that the provider mints per run adds a file per method, path and status it used. `token_store.uc::update_last_used()` leaves one marker per token name in `/var/run/uapi-token-update/`.
- **A request with no token can add metric files.** `/tmp/uapi-metrics` also grows with requests that carry no token, until reboot.
- **`uapi-token` takes no uapi lock.** A write of the CLI and a write of the HTTP path to `/etc/config/uapi` at the same moment can lose one of them, a revoke included.

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

1. `fs.open` returns null: early return. No fd held.
2. `fs.chmod` fails: it returns null rather than throwing, and the `try` is only a guard. `f.write` and `f.close` still run on the next lines, so the fd is released. The tolerance is deliberate (some filesystems return EPERM): content correctness is the priority, and the file then gets the default umask permissions.
3. Normal path: `f.write`, `f.flush` and `f.close` run unconditionally after the chmod, so the fd is released before the result is judged.
4. Short or failed write: ucode's `close()` drops `fclose`'s result, so a filesystem that runs out of space shows up only as a short count or a failed `flush`. Either one unlinks the temp file and returns false. Until 3.1.0 nothing checked, and an empty temp file was renamed over the original.

The following `fs.rename(tmp, path)` is checked: a failure unlinks `tmp` and returns false. The rename keeps the replacement atomic.

## Patterns confirmed

- **fd: open / use / close.** Every `fs.open` is followed by an early return (when the open returned null) or an unconditional `.close()` on the success path. No site holds an fd across a return without closing it, except the ubus connections and uci cursors, which live for the request by design.
- **pipe: popen / read / close.** Every `fs.popen` is followed by `.close()`, which both releases the pipe and yields the child's exit code.
- **flock: acquire / try-fn / release / die-if-caught.** `transaction()`, `multi_transaction()` and `with_lock()` release OUTSIDE the try block, AFTER the catch, BEFORE the conditional `die(caught)`.
- **2-level locks.** `default_acquire_pkg()` and `multi_transaction()` take the global SH, then each per-package EX in sorted order. A failure part way releases the per-package locks already held and the global one. The release runs in reverse order (per-package, then global).
- **Temp file then rename.** `replace_private_file()`, `ratelimit.uc`, the error ring and the metrics check the rename and unlink the temp file when it fails. The idempotency cache checks the size on disk and the rename, and unlinks the temp file when either fails.

## The wireguard peer apply

`wg.uc` shells out to `wg set` after the commit, inside the locked region, to push peer changes to the kernel (see `docs/architecture.md` § Transaction recipe step 7). Two things about it are load-bearing here.

The preshared key is staged at a fixed path, `/var/run/uapi.wg.psk`, rather than a unique one. That is safe only because every uci transaction holds the per-package exclusive lock for `network`, so two peer applies can never be in flight at once. If that lock discipline ever changes, this needs a unique path. Mode `0600` is set before the content is written, following the same order as `replace_private_file` above, and the file is unlinked immediately after the command returns. The write is checked as in `replace_private_file`. `wg` reads an empty key file as no key, so a failed write unlinks the file and fails the apply, and the transaction restores.

`wg show <iface> dump` is read on the reconcile path only. Its second field is the peer's preshared key, so that output must never be logged or surfaced in an error message.

## Scope

This audit is about **logical** resource-state correctness. Every site releases explicitly inside the request on every path the request itself takes. The fork-per-request model closes what remains at exit, and [When the request process is killed](#when-the-request-process-is-killed) says where that backstop is enough and where it is not.
