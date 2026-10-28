let fs = require('fs');
let wg = require('wg');

// Lock layout (introduced to let concurrent writes to different uci packages
// proceed in parallel without losing the apk-vs-uci serialization guarantee):
//
//   /var/lock/uapi.lock              shared by uci transactions, exclusive
//                                     by non-uci writes (apk, system/access,
//                                     cron_jobs)
//   /var/lock/uapi.pkg.<package>.lock exclusive per-package; serializes
//                                     writes to the same uci package only
//
// A uci transaction takes SH on the global + EX on its per-package file.
// Two transactions on different packages: both SH on global (compatible),
// each EX on its own file -> parallel.
// Two on the same package: both SH on global, only one EX on the package
// file -> serialized on the package one.
// A non-uci write takes EX on the global. Every acquire here is LOCK_NB, so it does not
// wait: it fails immediately and the caller answers 423 rather than queueing.
const LOCK_PATH = "/var/lock/uapi.lock";
const PKG_LOCK_PREFIX = "/var/lock/uapi.pkg.";
// Same charset for both: uci package names and init-script names must match
// /^[A-Za-z0-9_-]+$/ before we let them anywhere near a shell command or path.
const SAFE_NAME_RE = /^[A-Za-z0-9_-]+$/;

// Fail-fast before any uci write if a target init script is missing. The
// alternative path stages+commits, fails reload with exit 127, fails the
// restore-reload identically, and reports `reload_failed_unrecovered` -
// misleading since uci IS in a clean state.
function default_check_services(services) {
	for (let svc in services) {
		if (type(svc) != "string" || !match(svc, SAFE_NAME_RE))
			return sprintf("refusing to reload service with unsafe name %J", svc);
		let path = "/etc/init.d/" + svc;
		if (fs.stat(path) == null)
			return sprintf("init script %s not found (is the daemon installed?)", path);
	}
	return null;
}

// A write into a config file that does not exist stores nothing, and the uci cursor raises
// nothing either, so this answers first. Nothing on the box created the file: the package that
// ships it is missing, or, for `wireless`, the radio that `wifi config` would have described.
function missing_config(conn, pkg) {
	if (conn.uci_package_exists(pkg)) return null;
	return sprintf("/etc/config/%s not found: the package or hardware that creates it is missing on this router", pkg);
}

function default_reload(services) {
	for (let svc in services) {
		if (type(svc) != "string" || !match(svc, SAFE_NAME_RE))
			return sprintf("refusing to reload service with unsafe name %J", svc);
		let cmd = sprintf("/etc/init.d/%s reload 2>&1", svc);
		let p = fs.popen(cmd, "r");
		if (p == null)
			return sprintf("could not exec %s", cmd);
		let output = p.read("all") ?? "";
		let exit_code = p.close();
		if (exit_code != 0)
			return sprintf("%s exited with code %d: %s", svc, exit_code, trim(output));
	}
	return null;
}

// procd starts the daemon with its new config on its own, so the init script answers 0 before the
// daemon has read that config. unbound exits within a few hundred ms on a line that it cannot parse,
// and procd starts it again only 5 s later, to fail the same way. A reload of these services waits
// for the daemons that ran before the write to keep running. Writes to two packages that restart
// one daemon also take the lock of the package named after it, because a restart that one starts
// would read as a stop to the other, and its config as the other's.
const STAY_UP = { unbound: [ "unbound" ], "unbound-uci-ext": [ "unbound" ] };

function stay_up_daemons(services) {
	let daemons = {};
	for (let svc in services)
		for (let d in STAY_UP[svc] ?? []) daemons[d] = true;
	return keys(daemons);
}

function instances(conn, daemons) {
	let out = {};
	for (let d in daemons) {
		let r = null;
		try { r = conn.call("service", "list", { name: d }); } catch (e) {}
		for (let name, i in r?.[d]?.instances ?? {})
			out[d + "/" + name] = i;
	}
	return out;
}

// The restore runs the same check, so it fails when the previous config does not bring the daemon
// back either. An instance that `service list` does not show is being restarted, by `restart` or by
// another writer, or the ubus call failed, so only one that procd reports as not running counts.
function default_watch(conn, services, total_ms, step_ms) {
	let names = stay_up_daemons(services);
	if (length(names) == 0) return null;
	let was = instances(conn, names);
	let before = filter(keys(was), (k) => was[k].running);
	if (length(before) == 0) return null;
	return function() {
		for (let waited = 0; ; waited += step_ms) {
			let now = instances(conn, names);
			for (let k in before)
				if (now[k] != null && !now[k].running)
					return sprintf("%s stopped after the reload%s", split(k, "/")[0],
					               (now[k]?.exit_code != null) ? sprintf(", with exit code %d", now[k].exit_code) : "");
			if (waited >= total_ms) return null;
			sleep(step_ms);
		}
	};
}

const watch_stay_up = (conn, services) => default_watch(conn, services, 2000, 100);

// Open + flock a single file. mode is "x" (exclusive) or "s" (shared); always
// non-blocking ("n" suffix). Returns the fd handle on success; null on lock
// contention; { unavailable: <path> } on infrastructure failure (fs.open).
//
// "e" is O_CLOEXEC. An flock belongs to the open file description, and without "e" every
// child started under the lock (an init script, apk, passwd, wg) held a copy of it. A request
// that uhttpd killed then left its lock held until that child exited, or for as long as a
// daemon that the child started outside procd ran. With no copy, the close in _release_one(),
// or the exit of a killed request, releases the lock.
function _lock_one(path, mode) {
	let fd = fs.open(path, "w+e");
	if (!fd) return { unavailable: "" + path };
	let r = fd.lock(mode + "n");
	if (r !== true) { fd.close(); return null; }
	return fd;
}

function _release_one(fd) {
	if (fd) fd.close();
}

// Default global-exclusive lock; used by non-uci writes (apk, system/access).
// Backward-compatible signature: ignores extras, returns a single fd.
function default_acquire(path) {
	return _lock_one(path ?? LOCK_PATH, "x");
}

function default_release(handle) {
	_release_one(handle);
}

// Per-package uci-transaction lock. Holds SH on the global, EX on the
// per-package file of `package` and of each package in `also`, taken in
// sorted order as multi_transaction takes them. Returns { _g, _p } on
// success, or one of:
//   { contention: "global" }  - non-uci writer holds the global EX
//   { contention: "package", package } - another uci writer holds the EX
//                                        of that package
//   { unavailable: <path> }   - file open failed (infrastructure)
// The contention distinction feeds the 423 message identity so the
// caller learns which lock blocked them. prefix is for the tests, as in
// multi_transaction().
function default_acquire_pkg(global_path, package, also, prefix) {
	if (type(package) != "string" || !match(package, SAFE_NAME_RE))
		return { unavailable: sprintf("invalid package name %J", package) };
	let g = _lock_one(global_path ?? LOCK_PATH, "s");
	if (g == null) return { contention: "global" };
	if (type(g) == "object" && g.unavailable != null) return g;
	let held = [];
	for (let name in sort([ package, ...(also ?? []) ])) {
		let p = _lock_one((prefix ?? PKG_LOCK_PREFIX) + name + ".lock", "x");
		if (p == null || type(p) == "object" && p.unavailable != null) {
			for (let h in held) _release_one(h);
			_release_one(g);
			return (p == null) ? { contention: "package", package: name } : p;
		}
		push(held, p);
	}
	return { _g: g, _p: held };
}

function default_release_pkg(handle) {
	if (handle == null) return;
	for (let h in handle._p) _release_one(h);
	_release_one(handle._g);
}

// For a writer outside a request, such as uapi-token, which waits rather than answer 423.
// Every acquire here is non-blocking, so it polls. Returns the locks, an unavailable path, or
// the last contention once wait_ms has passed.
function acquire_pkg_waiting(package, wait_ms, global_path, prefix) {
	for (let waited = 0; ; waited += 100) {
		let lock = default_acquire_pkg(global_path, package, null, prefix);
		if (lock._g != null || lock.unavailable != null || waited >= wait_ms) return lock;
		sleep(100);
	}
}

// A write with no kernel path at all is distinct from one whose every target was
// skipped: without that distinction an absent header cannot tell a caller which
// of the two it got, which is the whole point of reporting this.
function _kernel_status(ops, applied) {
	let targets = wg.interfaces_of(ops);
	if (length(targets) == 0) return "no_kernel";
	if (length(applied) == 0) return "skipped";
	return (length(applied) == length(targets)) ? "ok" : "partial";
}

function _finalize_after_reload(reload_err, restore_fn, body, services, ops, applied) {
	if (reload_err == null) {
		return { ok: true, body: body,
		         reload_services: services,
		         reload_status: (length(services) > 0) ? "ok" : "no_reload",
		         kernel_applied: applied ?? [],
		         kernel_status: _kernel_status(ops ?? [], applied ?? []) };
	}

	let restore_err = null;
	try {
		let r2 = restore_fn();
		if (r2 != null) restore_err = "reload during restore failed: " + r2;
	} catch (e) {
		restore_err = "" + e;
	}

	if (restore_err != null)
		return { ok: false, kind: "reload_failed_unrecovered",
		         reload_error: reload_err, restore_error: restore_err };
	return { ok: false, kind: "reload_failed_restored",
	         reload_error: reload_err };
}

function run_inner(conn, pkg, services, fn, snapshot, apply, restore, ops, applied) {
	let result = fn(conn, pkg);

	if (!result || result.ok === false) {
		conn.uci_revert(pkg);
		return result ?? { ok: false, kind: "unknown" };
	}

	// A package that the write left as it was gets no restore, which would put the snapshot over
	// what another writer committed since.
	let committed = conn.uci_commit(pkg);

	return _finalize_after_reload(apply(), function() {
		if (committed) conn.uci_import(pkg, snapshot);
		return restore();
	}, result.body, services, ops, applied);
}

// Reload the declared services, then push the wireguard peer changes the write
// collected to the kernel. Both report the same way (null or a message), so a
// failed apply lands in the existing reload-failure recipe: restore the snapshot,
// re-apply, and report reload_failed_restored. `ops` is read here rather than
// captured by value because the handler fills it while fn runs, and fn has
// already returned by the time this is called.
function _make_apply(conn, reload, services, wg_apply, ops, applied, watch) {
	return function() {
		watch.check = watch.start(conn, services);
		let err = reload(services);
		if (err == null && watch.check != null) err = watch.check();
		if (err != null) return err;
		return wg_apply(conn, ops, applied);
	};
}

// The restore path must not replay the request's own operations. A batch can
// apply several peers before failing on a later one, so replaying would reapply
// the failure instead of undoing what landed. Reconciling each touched interface
// against the restored uci converges from whatever state the kernel is in.
function _make_restore(conn, reload, services, wg_reconcile, ops, watch) {
	return function() {
		let err = reload(services);
		if (err == null && watch.check != null) err = watch.check();
		if (err != null) return err;
		return wg_reconcile(conn, wg.interfaces_of(ops));
	};
}

function transaction(conn, params) {
	let pkg = params.package;
	let services = params.reload_services ?? [];
	let fn = params.fn;
	let path = params.lock_path ?? LOCK_PATH;
	let acquire = params.acquire ?? function(p, also) { return default_acquire_pkg(p, pkg, also); };
	let release = params.release ?? default_release_pkg;
	let reload = params.reload ?? default_reload;
	let wg_apply = params.wg_apply ?? wg.apply;
	let wg_reconcile = params.wg_reconcile ?? wg.reconcile;
	let wg_ops = params.wg_ops ?? [];
	let wg_applied = [];
	let check_services = params.check_services ?? default_check_services;
	let watch = { start: params.watch ?? watch_stay_up };

	// Bare mode: run fn against `conn` without acquiring any lock, taking a
	// snapshot, committing, or reloading. Used by /batch to compose many
	// handler-level writes under a single outer multi_transaction lock+commit.
	if (params.bare === true)
		return fn(conn, pkg);

	let svc_err = check_services(services);
	if (svc_err != null)
		return { ok: false, kind: "init_script_missing", message: svc_err };
	let cfg_err = missing_config(conn, pkg);
	if (cfg_err != null)
		return { ok: false, kind: "config_missing", message: cfg_err };

	let lock = acquire(path, filter(stay_up_daemons(services), (d) => d != pkg));
	// `null` means a test/legacy stub that pre-dates the contention sentinel;
	// treat as per-package since that's the production-default flavour.
	if (lock == null)
		return { ok: false, kind: "locked", lock_kind: "package", package: pkg };
	if (type(lock) == "object" && lock.contention != null) {
		if (lock.contention == "global")
			return { ok: false, kind: "locked", lock_kind: "global" };
		return { ok: false, kind: "locked", lock_kind: "package", package: lock.package ?? pkg };
	}
	if (type(lock) == "object" && lock.unavailable != null)
		return { ok: false, kind: "lock_unavailable", error: lock.unavailable };

	let result = null;
	let caught = null;
	try {
		// The preview before the lock loaded the package into this cursor, and libuci serves
		// every later read from that copy. A commit by LuCI or a shell in between was then
		// invisible to fn: a PUT kept an option that it had to remove, and the response showed
		// a section that uci did not store. The commit itself re-reads the file, so only the
		// reads were stale.
		conn.uci_unload(pkg);
		let snapshot = conn.uci_export(pkg);
		result = run_inner(conn, pkg, services, fn, snapshot,
		                   _make_apply(conn, reload, services, wg_apply, wg_ops, wg_applied, watch),
		                   _make_restore(conn, reload, services, wg_reconcile, wg_ops, watch),
		                   wg_ops, wg_applied);
	} catch (e) {
		caught = e;
	}
	release(lock);
	if (caught != null) die(caught);
	return result;
}

// multi_transaction snapshots, EX-locks, and on-failure restores N packages
// atomically. Caller passes a sorted-deduped package list and an fn that
// performs all uci writes inside the locked region. On success all packages
// commit and the union of reload services runs once. On a failure after the
// commits, every package that the batch committed is restored from its
// snapshot. Per-package EX locks are acquired in sorted order to avoid
// deadlocks vs other writers.
function multi_transaction(conn, params) {
	let packages = params.packages ?? [];
	let services = params.reload_services ?? [];
	let fn = params.fn;
	let path = params.lock_path ?? LOCK_PATH;
	let reload = params.reload ?? default_reload;
	let wg_ops = params.wg_ops ?? [];
	let wg_applied = [];
	let watch = { start: params.watch ?? watch_stay_up };
	let apply = _make_apply(conn, reload, services, params.wg_apply ?? wg.apply, wg_ops, wg_applied, watch);
	let restore_apply = _make_restore(conn, reload, services,
	                                  params.wg_reconcile ?? wg.reconcile, wg_ops, watch);
	let check_services = params.check_services ?? default_check_services;

	let svc_err = check_services(services);
	if (svc_err != null)
		return { ok: false, kind: "init_script_missing", message: svc_err };

	// Validate package names + sort + dedup so lock acquisition is deterministic.
	let unique = {};
	for (let p in packages) {
		if (type(p) != "string" || !match(p, SAFE_NAME_RE))
			return { ok: false, kind: "lock_unavailable",
			         error: sprintf("invalid package name %J", p) };
		unique[p] = true;
	}
	let sorted = [];
	for (let p in unique) push(sorted, p);
	sort(sorted);
	for (let p in sorted) {
		let cfg_err = missing_config(conn, p);
		if (cfg_err != null)
			return { ok: false, kind: "config_missing", message: cfg_err };
	}

	let locks = { ...unique };
	for (let d in stay_up_daemons(services)) locks[d] = true;
	locks = sort(keys(locks));
	let lock_prefix = params.pkg_lock_prefix ?? PKG_LOCK_PREFIX;

	let acquired = [];
	let g = _lock_one(path, "s");
	// Global SH contention means a non-uci writer holds EX (system/password,
	// packages/installed, etc.). Report it as such so the client knows the
	// blocker isn't another uci write.
	if (g == null) return { ok: false, kind: "locked", lock_kind: "global" };
	if (type(g) == "object" && g.unavailable != null)
		return { ok: false, kind: "lock_unavailable", error: g.unavailable };
	for (let pkg in locks) {
		let p = _lock_one(lock_prefix + pkg + ".lock", "x");
		if (p == null) {
			for (let h in acquired) _release_one(h);
			_release_one(g);
			return { ok: false, kind: "locked", lock_kind: "package", package: pkg };
		}
		if (type(p) == "object" && p.unavailable != null) {
			for (let h in acquired) _release_one(h);
			_release_one(g);
			return { ok: false, kind: "lock_unavailable", error: p.unavailable };
		}
		push(acquired, p);
	}

	let snapshots = {};
	let result = null;
	let caught = null;
	try {
		for (let pkg in sorted) {
			conn.uci_unload(pkg);
			snapshots[pkg] = conn.uci_export(pkg);
		}
		let inner = fn(conn);
		if (!inner || inner.ok === false) {
			for (let pkg in sorted) conn.uci_revert(pkg);
			result = inner ?? { ok: false, kind: "unknown" };
		} else {
			// Commit each package, but capture the first failure so the
			// packages committed before it are still restored. Without this, a
			// mid-loop commit throw leaves earlier packages committed and
			// breaks the across-packages atomicity contract. Only those are
			// restored: the snapshot of a package that this batch did not write
			// would undo what another writer committed since, such as LuCI's
			// delete of the section that made this batch's commit fail.
			let committed = [];
			let commit_err = null;
			for (let pkg in sorted) {
				let caught_commit = null;
				let wrote = false;
				try { wrote = conn.uci_commit(pkg); } catch (e) { caught_commit = "" + e; }
				if (caught_commit != null) {
					commit_err = sprintf("uci_commit(%s) failed: %s",
					                     pkg, caught_commit);
					break;
				}
				if (wrote) push(committed, pkg);
			}
			let reload_err = (commit_err == null) ? apply() : commit_err;
			result = _finalize_after_reload(reload_err, function() {
				for (let pkg in committed) conn.uci_import(pkg, snapshots[pkg]);
				return restore_apply();
			}, inner.body, services, wg_ops, wg_applied);
		}
	} catch (e) { caught = e; }

	for (let h in acquired) _release_one(h);
	_release_one(g);
	if (caught != null) die(caught);
	return result;
}

function with_lock(params) {
	let path = params.lock_path ?? LOCK_PATH;
	let acquire = params.acquire ?? default_acquire;
	let release = params.release ?? default_release;
	let fn = params.fn;

	let lock = acquire(path);
	if (lock == null) return { ok: false, kind: "locked", lock_kind: "global" };
	if (type(lock) == "object" && lock.unavailable != null)
		return { ok: false, kind: "lock_unavailable", error: lock.unavailable };

	let result = null;
	let caught = null;
	try { result = fn(); }
	catch (e) { caught = e; }
	release(lock);
	if (caught != null) die(caught);
	return result ?? { ok: true };
}

return { transaction, multi_transaction, with_lock,
         default_acquire, default_release,
         default_acquire_pkg, default_release_pkg, acquire_pkg_waiting,
         default_check_services, default_reload, default_watch };
