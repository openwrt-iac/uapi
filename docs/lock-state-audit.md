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
grep -rnE '\.(open|fdopen|popen|opendir|mkstemp|pipe|writefile|lock|connect|cursor)\(|uloop\.|_lock_one\(|acquire[a-z_]*\(' src/ cli/
```

The alternatives catch, in order: `fs.open` and `fs_mod.open`, the other `fs` calls that return a handle or write a file, `fd.lock`, `bus.connect` and `ubus_mod.connect`, `uci_mod.cursor`, any use of uloop, and the lock entry points of `src/lib/transaction.uc`: `_lock_one(`, the injected `acquire(`, `default_acquire_pkg(`, and `acquire_pkg_waiting(`, which `uapi-token` calls.

The earlier command was `grep -rn 'fs\.open\|fs\.popen\|\.lock(' src/ cli/`. It found 36 lines, one of them a comment. It missed every ubus connection, every uci cursor, the two `fs_mod.open` calls of the snapshot and the restore in `src/lib/bus.uc`, and the places where `multi_transaction()`, `transaction()` and `with_lock()` take their locks, because those call `_lock_one()` or `acquire()` and not `.lock(` itself.

The pattern leaves out three things on purpose. `fs.readfile` and `fs.lsdir` return a value and hold nothing. Calls to `transaction()`, `multi_transaction()` and `with_lock()` from other modules take a lock, but they release it through the entry point's own proof, so they are listed by function in [What runs while a lock is held](#what-runs-while-a-lock-is-held) rather than as sites. `system()` and the ubus `defer`, `subscriber` and `listener` calls hold resources too, but nothing in the tree uses them.

`make lint-lock-audit` runs the command above, as written here, and fails when a site is in no row of the table below, when a site is in two rows, when a row holds no site, or when a "covers all N sites" count in this file or in `CLAUDE.md` is not the number of lines the command prints.

## Summary

**This audit covers all 59 sites that the command finds.** It used to cover 16 of the 36 lines that the earlier command found, and nine modules were absent from it: `error_ring`, `idempotency`, `metrics`, `mgmt`, `ratelimit`, `token_store`, `dhcp.leases`, `dhcp.leases6` and `dhcp.servers`.

Every descriptor, pipe and lock below is released on every in-request exit path. What the audit did find is listed under [Open findings](#open-findings): a request that uhttpd kills can stop between its commit and its reload.

## Sites

| File | Lines | Resource | Release proof |
|------|-------|----------|---------------|
| `src/main.uc` | 103-109 | fd, `/usr/share/uapi/VERSION`, at module load in the uhttpd parent | A failed open returns `"unknown"` and holds nothing. Otherwise the fd is closed before the return. |
| `src/main.uc` | 145-155 | ubus connection and uci cursor, at module load in the uhttpd parent | A failed connect is caught and the defaults are used. The connection is never disconnected, and a ucode ubus connection keeps a reference to itself, so it outlives the last script reference. It is closed by the `ucv_gc()` that uhttpd's ucode plugin runs once after it loads the handler, before the first fork. The handler loads before uhttpd calls `uloop_init()`, so the socket is never in uhttpd's event loop. |
| `src/main.uc` | 252-269 | ubus connection and uci cursor, `/healthz` | A failed connect is caught and reported as degraded. Otherwise the connection lives until the request process exits, which closes the socket. Nothing else shares it. |
| `src/main.uc` | 277-284 | fd, `/proc/uptime`, `/healthz` | A failed open skips the uptime. Otherwise the fd is closed right after one line is read. |
| `src/main.uc` | 679-686 | fd, `/proc/uptime`, `/diagnostics` | Same shape. |
| `src/main.uc` | 774-787 | fd, `/usr/share/uapi/openapi.json` | A failed open answers 404. Otherwise the fd is closed before the response is built. |
| `src/main.uc` | 844-849 | ubus connection and uci cursor, one per request | A failed connect answers 503 and holds nothing. Otherwise both live until the request process exits. The cursor holds no file between calls, because libuci opens and closes the package file inside each load and commit. It loads each package by its path, so libuci reads no delta file for it and writes none: the writes of a request live in the cursor's copy and in the list that the commit replays, and a request that dies before its commit leaves nothing staged. |
| `src/lib/bus.uc` | 32-74 | lock fd on `/etc/config/<pkg>` and temp file `.<pkg>.uapi-restore` beside the file that the package names, the restore | A missing package or a failed open dies before any fd exists. Every later path reaches the `LOCK_UN` and the close before the `die()`. The lock is the flock that libuci takes on the package file. A load holds `LOCK_SH` on it while it parses, and a commit holds `LOCK_EX` while it reads the file again, writes its temp file and syncs it. The restore tries `LOCK_EX` with `LOCK_NB` every 50 ms for 5 s, then gives up with a message that names the file, so a stuck holder cannot keep it until uhttpd kills the request. A failed create leaves no temp file, and a file that reads back short, a failed chmod and a failed rename each unlink it. The `die()` reaches `_finalize_after_reload()`, which answers `reload_failed_unrecovered` with the message. The restore starts no child, so no copy of the lock fd outlives it. The lock orders nothing after it is released. libuci releases it before its own rename, and the flock is on the file that the rename replaces, so a commit that held the lock, or waited on it with the old file open, can rename its file over the restored one, as between two libuci commits. |
| `src/lib/bus.uc` | 76-84 | ubus connection and uci cursor, created by `bus.connect` | A failed connect dies before any handle exists. The returned object owns both for the rest of the request. |
| `src/lib/bus.uc` | 203-209 | fd, `/etc/config/<pkg>` read for the snapshot | A failed open returns an empty snapshot, which a restore would write over the package. The pre-flight checked moments before that the file exists. Otherwise the fd is closed before the return. The read takes no libuci lock, which is safe because libuci and the restore replace the file with a rename, so the read sees either the old file or the new one. |
| `src/lib/transaction.uc` | 49-63 | pipe, `/etc/init.d/<svc> reload` | A failed popen returns a message. Otherwise `p.close()` always runs after the read and yields the exit code. `read("all")` returns at end of file, so a reload whose descendants keep the pipe's write end open holds the write, and its locks, until they close it. Only uhttpd's script timeout bounds that. |
| `src/lib/transaction.uc` | 124-130 | lock fd, `_lock_one()` | A failed open returns `{ unavailable }` and holds nothing. A refused `LOCK_NB` closes the fd and returns null. Otherwise the fd goes to the caller, who releases it with `_release_one()`, which closes it. The mode is `w+e`, and `e` sets `O_CLOEXEC`, so no child started under the lock gets a copy of the descriptor. An flock belongs to the open file description, so the close, or the exit of a killed request, is then what releases it. The test "a request killed under its locks" in `tests/unit/transaction_test.uc` proves the exit: a ucode process takes the global and package locks of `multi_transaction()`, starts a `sleep` inside `fn` and is killed there with `SIGKILL`, and the test then takes both locks while the `sleep` still runs. Without `e` the `sleep` holds them. |
| `src/lib/transaction.uc` | 138-140 | global EX, `default_acquire()` | Returns the `_lock_one()` result unchanged. `default_release()` releases it with `_release_one()`. |
| `src/lib/transaction.uc` | 157-174 | global SH and per-package EX, `default_acquire_pkg()` | Takes the global SH, then the EX of the package and of each package in `also`, in sorted order. When one fails it releases the per-package locks it already holds and the global one, then returns the contention or the unavailable path. `default_release_pkg()` releases the per-package locks, then the global one. |
| `src/lib/transaction.uc` | 185-191 | global SH and per-package EX, `acquire_pkg_waiting()` | Calls `default_acquire_pkg()` every 100 ms until it gets the locks, the lock file cannot be opened, or `wait_ms` has passed, and returns its last result. A failed attempt holds nothing, as the row above shows, so only the last result can hold locks, and the caller releases them with `default_release_pkg()`. |
| `src/lib/transaction.uc` | 284-345 | lock taken by `transaction()` | The pre-flight checks run before the lock, so their early returns hold nothing. Each contention or unavailable result returns before the try. Inside the try run the unload, the snapshot, `fn`, the revert or the commit, the reload, the stay-up watch, the kernel apply and the restore. A commit that wrote nothing skips the reload, the watch and the apply, and a commit whose replay no longer applies returns a conflict before them. A commit that fails drops the copy of the package that the cursor holds, so nothing after it reads the writes that the file does not hold. `release(lock)` runs after the catch and before `die(caught)`. A throw after the commit would skip the restore, but nothing on that path throws today: the watch and the kernel apply catch their ubus errors, the reload of a token mint or revoke, which reaps the token state in tmpfs, catches its own, and `_finalize_after_reload()` catches the restore's. |
| `src/lib/transaction.uc` | 362-494 | global SH and per-package EX, `multi_transaction()` | Validation and the missing-config check return before any lock. The per-package EX are taken in sorted order, the stay-up daemons included, and each failure releases what is held before it returns. The try covers the snapshots, `fn`, the revert or the commits, the apply and the restore. The restore reverts each package that the batch did not commit before it writes back the ones that it did, so that the cursor holds no write that uci did not store. After a failed commit it runs no reload and no reconcile, because neither the reload nor the kernel apply ran yet. The release loop runs after the catch and before `die(caught)`. |
| `src/lib/transaction.uc` | 496-514 | global EX, `with_lock()` | A contention or unavailable result returns before the try. `release(lock)` runs after the catch and before `die(caught)`. |
| `src/lib/non_uci.uc` | 71-94 | fd and temp file, `replace_private_file()` | See [the tricky case](#tricky-case-non_ucireplace_private_file) below. Every exit path closes the fd, and every failure path unlinks the temp file. |
| `src/lib/ids.uc` | 21-27 | fd, `/dev/urandom` | A failed open dies before any fd exists. Otherwise the fd is closed right after the read. |
| `src/lib/packages.uc` | 10-18 | pipe, `apk <args>` | A failed popen returns an error result. Otherwise `p.close()` always runs and yields the exit code. Under the global EX for add, del and update, and under no lock for the reads. |
| `src/lib/packages.uc` | 25-45 | pipe, `apk info` | A failed popen returns `[]`. Otherwise the pipe is closed right after the read. No lock. |
| `src/lib/packages.uc` | 156-171 | fd per feed file | A failed open gives an empty URL. Otherwise the fd is closed after one line. No lock. |
| `src/lib/packages.uc` | 173-186 | fd, one feed file | A failed open answers 404. Otherwise the fd is closed after one line. No lock. |
| `src/lib/packages.uc` | 210-238 | fd, a new feed file, `wx` | Under the global EX. `O_EXCL` refuses a file another writer created after the `stat`, and a failed open answers 409 or 500. Otherwise the fd is closed before the write is judged. A size on disk short of the URL line unlinks the file and answers 500 before `apk update` runs, so a retry does not find the file. |
| `src/lib/mgmt.uc` | 20-28 | pipe, `ip route get <addr>` | A failed popen returns null. Otherwise the pipe is closed after one line, and `ip` has exited or exits once it writes that line. A single write resolves this before its transaction. Inside `/batch` it runs under the batch's locks, because each sub-request runs inside `fn`. |
| `src/lib/state_dir.uc` | 20-29 | fd and temp file, `replace()`, which the idempotency cache, the metrics, the rate limiter and the error ring write through | Each caller writes only into a directory that `state_dir.owned()` accepts: a directory owned by the effective uid of the process, that neither the group nor others can write, narrowed to 0700, and not one that it cannot narrow. A failed open returns false and holds nothing. The temp name is unlinked first, because `open()` gives its mode only to a file that it creates, so the file is created 0600. The fd is closed before the size on disk is compared with the text, which is how a full tmpfs shows. A short file or a failed rename unlinks the temp file and returns false, and the file that it would replace stays whole. |
| `src/lib/idempotency.uc` | 58-84 | fd, a cache entry | A directory that `state_dir.owned()` does not accept is a miss, and a store into it stores nothing and returns false. A failed open is a miss. Otherwise the fd is closed before the JSON parse. A store writes through `state_dir.replace()` under a temp name of its own request process, `<hash>.json.<pid>`, so two stores of one key at the same moment each write a whole file, and the later rename wins. At most once an hour, a store also unlinks the files older than the TTL, a temp file that a killed request left included, and writes its sweep marker `.swept` through `state_dir.replace()`. A failed write of the marker leaves the old one, so the next store sweeps again. |
| `src/lib/token_store.uc` | 24-32 | fd, `/dev/urandom` | A failed open dies before any fd exists. Otherwise the fd is closed right after the read. |
| `src/lib/token_store.uc` | 242-270 | fd, the last-used marker, then a `uapi` transaction | A directory that `state_dir.owned()` does not accept skips the update, marker and transaction both, because without its marker every authenticated request would write `/etc/config/uapi`. The marker is unlinked and created 0600, as `open()` gives its mode only to a file that it creates, and closed before the transaction. The transaction then releases its lock through `transaction()`. The marker is written first, so a 423 on the transaction still throttles the next minute. A mint or a revoke removes the marker of each token that no longer authenticates, see `token_store.reap_state`, which unlinks no marker in a directory that `state_dir.owned()` does not accept. |
| `src/lib/metrics.uc` | 74-80 | fd, one counter | A directory that `state_dir.owned()` does not accept counts nothing: an increment reads and writes no file and returns false, a scrape shows no series, and a fold of retired tokens reads and unlinks nothing. A failed open reads as no count. Otherwise the fd is closed after one line. An increment writes through `state_dir.replace()` under `<file>.tmp`, which two writers of one counter share, so concurrent increments can be lost, which the module accepts. The size check keeps the counter a whole count. |
| `src/lib/error_ring.uc` | 15-25 | fd, the ring | A directory that `state_dir.owned()` does not accept reads as `[]` and takes no append. A failed open reads as `[]`. Otherwise the fd is closed before the parse. An append writes through `state_dir.replace()` under a temp name of its own request process, `ring.json.<pid>`, so two appends at once write separate files, and the later rename wins. The whole append is in a try that swallows everything. |
| `src/lib/ratelimit.uc` | 15-32 | fd, one bucket | A directory that `state_dir.owned()` does not accept allows every request: a check reads and writes no file, and a reap unlinks nothing. Under `/var/run` only root can cause that, and refusing instead would answer 429 to every token. A failed open is no state, which is a full bucket, so the limit applies again once the bucket is written. Otherwise the fd is closed before the parse. A check writes through `state_dir.replace()` under `<token>.txt.tmp`, which two checks of one token share, so one of them can lose its write, as for the metrics. |
| `src/lib/system_access.uc` | 48-56 | pipe, `busybox passwd`, write end | Under the global EX. A failed popen answers 500. Otherwise both writes run and `p.close()` yields the exit code. A `passwd` that exits early makes the writes fail with `EPIPE` rather than kill the request, because uhttpd ignores `SIGPIPE` and the request process inherits that. |
| `src/lib/wg.uc` | 34-40 | pipe, `wg` and `ip` commands | A failed popen returns an error result. Otherwise `p.close()` always runs after the read. Runs under the transaction's lock for `network`. |
| `src/lib/wg.uc` | 120-136 | fd and file, `/var/run/uapi.wg.psk` | See [the wireguard peer apply](#the-wireguard-peer-apply). The fd is closed before the write is judged. A size on disk short of the key line unlinks the file and returns null, and `apply_peer()` then fails before it changes anything in the kernel. Otherwise `apply_peer()` unlinks the file once `wg` returns. |
| `src/resources/dhcp.leases.uc` | 24-30 | fd, `/tmp/dhcp.leases` | A failed open reads as no leases. Otherwise the fd is closed before the parse. No lock. |
| `src/resources/dhcp.leases6.uc` | 59-65 | fd, the odhcpd lease file | A failed open returns null, and the caller tries the other path. Otherwise the fd is closed before the parse. No lock. |
| `src/resources/dhcp.servers.uc` | 10-16 | fd, a lease file | A failed open reads as empty. Otherwise the fd is closed before the count. No lock. |
| `cli/uapi-token` | 22-31 | fd, `/dev/urandom` | A failed open dies before any fd exists. Otherwise the fd is closed right after the read. |
| `cli/uapi-token` | 96-108 | global SH and EX of `uapi`, `with_uapi_lock()` | Takes the locks that an HTTP write of the `uapi` package takes, through `acquire_pkg_waiting()`, waiting up to 10 s. A file that cannot be opened dies, holding nothing. Locks still held after 10 s print which one and exit 75, holding nothing. Otherwise `fn` runs and `default_release_pkg()` releases them. A `die()` inside `fn` ends the process, and the exit releases them, because no child holds a copy. |
| `cli/uapi-token` | 122-128 | fd, creating `/etc/config/uapi` | A failed open dies. Otherwise the fd is closed right after the open. |
| `cli/uapi-token` | 130-190 | uci cursor, `create` | Created inside `with_uapi_lock()`, so the package is loaded after the locks are taken and committed before they are released, and an HTTP write of `/etc/config/uapi` cannot run between the two. Freed when the command exits. It reads the file again before it writes, as the commit of the HTTP path does. The command keeps libuci's default cursor, which reads and commits what its shell staged in `/tmp/.uci`, as `uci commit uapi` in that shell does. It is a shell command, and that staging is its shell's. A commit that libuci refuses, as on a full overlay, dies with the error of the cursor, before the bearer is printed and before the reap, so the reap cannot drop the state of a token that still authenticates. After the commit the bearer is printed and flushed, then `reap()` runs `token_store.reap_state` under the same locks. |
| `cli/uapi-token` | 192-201 | uci cursor, `list` | Read only. Freed when the command exits. |
| `cli/uapi-token` | 203-222 | uci cursor, `show` | Read only. Freed when the command exits. |
| `cli/uapi-token` | 233-248 | uci cursor, `revoke` | Same as `create`, with a message in place of the bearer. A refused commit dies before the message and the reap. |

## What runs while a lock is held

Every uapi lock is taken with `LOCK_NB`, so no request waits for one. A request that finds it taken answers 423 at once. `uapi-token` polls instead, for up to 10 s. libuci's own flocks on a package file block, so a load or a commit waits while LuCI or a shell holds them. The restore tries that flock for up to 5 s instead. A load holds it while it parses the file, and a commit while it reads the file again, writes and syncs it. How long a lock is held is set by what runs under it:

| Entry point | Locks | Callers | Held across |
|-------------|-------|---------|-------------|
| `transaction()` | global SH, EX of the package, EX of `unbound` for a write that restarts it | `handler.uc` create, replace, patch, remove, adopt and the singleton patch. `raw.uc` create, replace, patch and remove. `token_store.uc` create, remove and `update_last_used()`, which a GET reaches. | `fn` with its ubus reads, the commit, `/etc/init.d/<svc> reload` for each service, the stay-up watch, `wg set` and `ip route` for wireguard peers. For a token mint or revoke, `token_store.reap_state`, which walks the rate-limit buckets, the token series of the metrics and the last-used markers. After a failed reload or apply: the restore, which can wait up to 5 s for libuci's flock on the package, a second reload, a second watch and the kernel reconcile. |
| `multi_transaction()` | global SH, EX of each package of the batch and of `unbound` when the batch restarts it | `main.uc` `/batch` | Every sub-request, including the `ip route get` of a management-path guard, then one commit per package, and one reload of the services of the packages that the batch committed, one watch and one apply, and the same restore of each package that the batch committed. After a failed commit, only that restore, with no reload and no reconcile. |
| `acquire_pkg_waiting()` | global SH, EX of `uapi` | `cli/uapi-token` create and revoke | The load of `/etc/config/uapi`, the commit and `token_store.reap_state`. |
| `with_lock()` | global EX | `packages.uc` install, remove, feed create, feed remove. `system_access.uc` password, key add, key replace, key remove. `crontab.uc` add and remove. | `apk add`, then `apk update` and `apk add` again when the first add fails. `apk del`. A feed write or unlink followed by `apk update`. `busybox passwd`. A rewrite of `authorized_keys`. A crontab rewrite, `/etc/init.d/cron reload`, and on failure the old crontab and a second reload. |

Two of these hold a lock longer than the write itself takes.

- **The stay-up watch sleeps under the lock.** A reload of `unbound` or `unbound-uci-ext` with a running daemon polls `service list` every 100 ms for up to 2 s (the `sleep()` in `default_watch()`), still holding the global SH and the EX locks. The restore runs the watch again. While it waits, every non-uci write answers 423. The watch needs the lock, because another writer's restart of unbound would read as a stop.
- **The apk paths hold the global EX across network I/O.** `apk add`, `apk update` and the retry fetch from the feeds, and uapi sets no timeout of its own. Every uci write answers 423 until apk returns. Only uhttpd's script timeout (60 s unless configured) ends the request, and the kill then releases the lock while apk still runs, see the next section.

## When the request process is killed

uhttpd sends `SIGKILL` to the request process when the client closes the connection before the response, and when its script timeout expires (60 s unless `script_timeout` is set). A Terraform interrupt or a client-side timeout does the first. No release code runs, so this is where the sites rely on process exit:

- **The request's own descriptors, ubus connection and uci cursor** close at exit. That is safe: nothing else holds them, and the cursor writes no delta file.
- **A lock** is released at exit. uapi's lock files are opened with `O_CLOEXEC`, so a child that runs under the lock (an init script, `apk`, `passwd`, `wg`, `ip`) holds no copy of the descriptor. uhttpd kills the request process alone, so that child runs on without the lock, and the next write can take the lock and start its own reload or `apk` beside it. `apk` has its own lock on its database. Before `O_CLOEXEC` the child held a copy, which kept the serialization while it worked but kept the lock until it exited, and a daemon that it started outside procd kept the lock for as long as the daemon ran, with every write behind that lock answering 423.
- **Temp files** are not removed by an exit. A request killed between the open and the rename leaves `<file>.uapi.tmp` beside `/etc/crontabs/root` or `/etc/dropbear/authorized_keys`, which crond and dropbear do not read and the next write unlinks first, `/var/run/uapi.wg.psk` (mode 0600, unlinked by the next peer write that stages a key), a `.tmp` file in `/var/run/uapi-metrics` or `/var/run/uapi-ratelimit`, which the next write of the same name replaces and no reader opens, `<hash>.json.<pid>` or `.swept.tmp` in `/var/run/uapi-idempotency`, which no reader opens and the first sweep after the TTL unlinks, and `ring.json.<pid>` in `/var/run/uapi-error-ring`, which only a later request with the same pid replaces, so each such kill can leave one copy of the ring until reboot. A kill inside libuci's commit leaves `/etc/config/.<pkg>.uci-XXXXXX` on flash, which libuci never lists and nothing removes. A kill inside the restore before its rename leaves `.<pkg>.uapi-restore` beside the package file and the package as the failed write left it, and the next restore of that package unlinks the temp file first. A kill after the rename leaves the package restored and no temp file.
- **The transaction itself** is not safe, see the first open finding.

## Open findings

These are recorded here, not fixed. A finding leaves this list when it is fixed, and the CHANGELOG entry of the fix describes it.

- **A killed request stops the recipe where it is.** `transaction.uc::run_inner()` commits, then reloads, checks and restores, all in the request process. If uhttpd kills that process during the reload, uci keeps the new config, no stay-up check or restore runs, and the client gets no answer. Scenario: a client times out or is interrupted during `PUT /network/interfaces/wan` and closes its connection while `/etc/init.d/network reload` runs, and a reload that then fails leaves the box on whatever the daemon could make of the new config, with no `reload_failed_restored` and no restore. The same holds for `multi_transaction()` and for the crontab apply in `crontab.uc`. The kill releases the lock while that reload still runs, so the next write to the package can commit and reload beside it. Nothing in the request runs after the kill, so this needs a design change, which `docs/roadmap.md` records under Hardening.

## Tricky case: `non_uci.uc::replace_private_file()`

```ucode
let tmp = path + ".uapi.tmp";
try { fs.unlink(tmp); } catch (e) {}
let f = fs.open(tmp, "w");
if (!f) return false;
try { fs.chmod(tmp, 384); } catch (e) {}  // 0600
f.write(content);
f.close();
if (fs.stat(tmp)?.size != length(content)) {
	try { fs.unlink(tmp); } catch (e) {}
	return false;
}
```

Four exit paths to verify, in order:

1. `fs.open` returns null: early return. No fd held.
2. `fs.chmod` fails: it returns null rather than throwing, and the `try` is only a guard. `f.write` and `f.close` still run on the next lines, so the fd is released. The tolerance is deliberate (some filesystems return EPERM): content correctness is the priority, and the file then gets the default umask permissions.
3. Normal path: `f.write` and `f.close` run unconditionally after the chmod, so the fd is released before the result is judged.
4. Short or failed write: ucode's `close()` drops `fclose`'s result, and `flush()` answers inverted on the ucode that CI runs, so a filesystem that runs out of space shows up as a temp file on disk shorter than `content`. That unlinks the temp file and returns false. Until 3.1.0 nothing checked, and an empty temp file was renamed over the original.

The following `fs.rename(tmp, path)` is checked: a failure unlinks `tmp` and returns false. The rename keeps the replacement atomic.

## Patterns confirmed

- **fd: open / use / close.** Every `fs.open` is followed by an early return (when the open returned null) or an unconditional `.close()` on the success path. No site holds an fd across a return without closing it, except the ubus connections and uci cursors, which live for the request by design.
- **pipe: popen / read / close.** Every `fs.popen` is followed by `.close()`, which both releases the pipe and yields the child's exit code.
- **flock: acquire / try-fn / release / die-if-caught.** `transaction()`, `multi_transaction()` and `with_lock()` release OUTSIDE the try block, AFTER the catch, BEFORE the conditional `die(caught)`.
- **2-level locks.** `default_acquire_pkg()` and `multi_transaction()` take the global SH, then each per-package EX in sorted order. A failure part way releases the per-package locks already held and the global one. The release runs in reverse order (per-package, then global).
- **Temp file then rename.** `replace_private_file()` and `state_dir.replace()`, which the idempotency cache, the metrics, the rate limiter and the error ring write through, check the size on disk and the rename, and unlink the temp file when either fails. The restore in `bus.uc` checks the rename too, and reads the temp file back in place of a size check. No site checks a `flush()`, because ucode's `close()` drops the result of `fclose` and `flush()` answers inverted on the ucode that CI runs (`docs/ucode-quirks.md`).

## The wireguard peer apply

`wg.uc` shells out to `wg set` after the commit, inside the locked region, to push peer changes to the kernel (see `docs/architecture.md` § Transaction recipe step 7). Two things about it are load-bearing here.

The preshared key is staged at a fixed path, `/var/run/uapi.wg.psk`, rather than a unique one. That is safe only because every uci transaction holds the per-package exclusive lock for `network`, so two peer applies can never be in flight at once. If that lock discipline ever changes, this needs a unique path. Mode `0600` is set before the content is written, following the same order as `replace_private_file` above, and the file is unlinked immediately after the command returns. The write is checked as in `replace_private_file`, because `wg` reads an empty key file as no key. `apply_peer()` stages the key before it removes or sets the peer, so a key that the tmpfs cannot hold fails the apply with the peer as the kernel holds it, and no peer is removed for it. The restore then sets every peer of the interface again from uci and stops at the first one that fails, so on a full tmpfs it answers `reload_failed_unrecovered` unless no peer of that interface has a key in the restored config.

`wg show <iface> dump` is read on the reconcile path only. Its second field is the peer's preshared key, so that output must never be logged or surfaced in an error message.

## Scope

This audit is about **logical** resource-state correctness. Every site releases explicitly inside the request on every path the request itself takes. The fork-per-request model closes what remains at exit, and [When the request process is killed](#when-the-request-process-is-killed) says where that backstop is enough and where it is not.
