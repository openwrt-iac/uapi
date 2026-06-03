let fs = require('fs');

// Lock layout (introduced to let concurrent writes to different uci packages
// proceed in parallel without losing the apk-vs-uci serialization guarantee):
//
//   /var/lock/uapi.lock              shared by uci transactions, exclusive
//                                     by non-uci writes (apk, system/access)
//   /var/lock/uapi.pkg.<package>.lock exclusive per-package; serializes
//                                     writes to the same uci package only
//
// A uci transaction takes SH on the global + EX on its per-package file.
// Two transactions on different packages: both SH on global (compatible),
// each EX on its own file -> parallel.
// Two on the same package: both SH on global, only one EX on the package
// file -> serialized on the package one.
// A non-uci write takes EX on the global -> waits for any in-flight uci
// transaction (any package) and blocks new ones until done.
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

// Open + flock a single file. mode is "x" (exclusive) or "s" (shared); always
// non-blocking ("n" suffix). Returns the fd handle on success; null on lock
// contention; { unavailable: <path> } on infrastructure failure (fs.open).
function _lock_one(path, mode) {
	let fd = fs.open(path, "w+");
	if (!fd) return { unavailable: "" + path };
	let r = fd.lock(mode + "n");
	if (r !== true) { fd.close(); return null; }
	return fd;
}

function _release_one(fd) {
	if (fd) { fd.lock("u"); fd.close(); }
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
// per-package file. Returns an opaque handle (object with both fds) or one
// of the same null / { unavailable } sentinels.
function default_acquire_pkg(global_path, package) {
	if (type(package) != "string" || !match(package, SAFE_NAME_RE))
		return { unavailable: sprintf("invalid package name %J", package) };
	let g = _lock_one(global_path ?? LOCK_PATH, "s");
	if (g == null) return null;
	if (type(g) == "object" && g.unavailable != null) return g;
	let p = _lock_one(PKG_LOCK_PREFIX + package + ".lock", "x");
	if (p == null) { _release_one(g); return null; }
	if (type(p) == "object" && p.unavailable != null) { _release_one(g); return p; }
	return { _g: g, _p: p };
}

function default_release_pkg(handle) {
	if (handle == null) return;
	_release_one(handle._p);
	_release_one(handle._g);
}

function run_inner(conn, pkg, services, fn, snapshot, reload) {
	let result = fn(conn, pkg);

	if (!result || result.ok === false) {
		conn.uci_revert(pkg);
		return result ?? { ok: false, kind: "unknown" };
	}

	conn.uci_commit(pkg);

	let reload_err = reload(services);
	if (reload_err == null) {
		// reload_result is surfaced as a response header by translate_tx so
		// clients can distinguish "no reload service for this resource"
		// from "reload service ran and exited 0". The init script's exit
		// code is the only convergence signal available; clients should
		// not treat `ok` as "device converged" (see docs/operations.md).
		return { ok: true, body: result.body ?? result,
		         reload_services: services,
		         reload_status: (length(services) > 0) ? "ok" : "no_reload" };
	}

	let restore_err = null;
	try {
		conn.uci_import(pkg, snapshot);
		conn.uci_commit(pkg);
		let restore_reload_err = reload(services);
		if (restore_reload_err != null)
			restore_err = "reload during restore failed: " + restore_reload_err;
	} catch (e) {
		restore_err = "" + e;
	}

	if (restore_err != null) {
		return {
			ok: false,
			kind: "reload_failed_unrecovered",
			reload_error: reload_err,
			restore_error: restore_err,
		};
	}

	return {
		ok: false,
		kind: "reload_failed_restored",
		reload_error: reload_err,
	};
}

function transaction(conn, params) {
	let pkg = params.package;
	let services = params.reload_services ?? [];
	let fn = params.fn;
	let path = params.lock_path ?? LOCK_PATH;
	let acquire = params.acquire ?? function(p) { return default_acquire_pkg(p, pkg); };
	let release = params.release ?? default_release_pkg;
	let reload = params.reload ?? default_reload;
	let check_services = params.check_services ?? default_check_services;

	// Bare mode: run fn against `conn` without acquiring any lock, taking a
	// snapshot, committing, or reloading. Used by /batch to compose many
	// handler-level writes under a single outer multi_transaction lock+commit.
	if (params.bare === true)
		return fn(conn, pkg);

	let svc_err = check_services(services);
	if (svc_err != null)
		return { ok: false, kind: "init_script_missing", message: svc_err };

	let lock = acquire(path);
	if (lock == null) return { ok: false, kind: "locked" };
	if (type(lock) == "object" && lock.unavailable != null)
		return { ok: false, kind: "lock_unavailable", error: lock.unavailable };

	let result = null;
	let caught = null;
	try {
		let snapshot = conn.uci_export(pkg);
		result = run_inner(conn, pkg, services, fn, snapshot, reload);
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
// commit and the union of reload services runs once; on any failure all
// packages are restored from their snapshots in reverse order. Per-package
// EX locks are acquired in sorted order to avoid deadlocks vs other writers.
function multi_transaction(conn, params) {
	let packages = params.packages ?? [];
	let services = params.reload_services ?? [];
	let fn = params.fn;
	let path = params.lock_path ?? LOCK_PATH;
	let reload = params.reload ?? default_reload;
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

	// Acquire global SH + per-package EX in sorted order.
	let acquired = [];
	let g = _lock_one(path, "s");
	if (g == null) return { ok: false, kind: "locked" };
	if (type(g) == "object" && g.unavailable != null)
		return { ok: false, kind: "lock_unavailable", error: g.unavailable };
	for (let pkg in sorted) {
		let p = _lock_one(PKG_LOCK_PREFIX + pkg + ".lock", "x");
		if (p == null) {
			for (let h in acquired) _release_one(h);
			_release_one(g);
			return { ok: false, kind: "locked" };
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
		for (let pkg in sorted) snapshots[pkg] = conn.uci_export(pkg);
		let inner = fn(conn);
		if (!inner || inner.ok === false) {
			for (let pkg in sorted) conn.uci_revert(pkg);
			result = inner ?? { ok: false, kind: "unknown" };
		} else {
			// Commit each package, but capture the first failure so we can
			// still attempt a restore on every package (committed or not).
			// Without this, a mid-loop commit throw leaves earlier packages
			// committed and breaks the across-packages atomicity contract.
			let commit_err = null;
			for (let pkg in sorted) {
				let caught_commit = null;
				try { conn.uci_commit(pkg); } catch (e) { caught_commit = "" + e; }
				if (caught_commit != null) {
					commit_err = sprintf("uci_commit(%s) failed: %s",
					                     pkg, caught_commit);
					break;
				}
			}
			let reload_err = (commit_err == null) ? reload(services) : commit_err;
			if (reload_err == null) {
				result = { ok: true, body: inner.body ?? inner,
				           reload_services: services,
				           reload_status: (length(services) > 0) ? "ok" : "no_reload" };
			} else {
				let restore_err = null;
				try {
					for (let pkg in sorted) {
						conn.uci_import(pkg, snapshots[pkg]);
						conn.uci_commit(pkg);
					}
					let r2 = reload(services);
					if (r2 != null) restore_err = "reload during restore failed: " + r2;
				} catch (e) { restore_err = "" + e; }
				if (restore_err != null) {
					result = { ok: false, kind: "reload_failed_unrecovered",
					           reload_error: reload_err, restore_error: restore_err };
				} else {
					result = { ok: false, kind: "reload_failed_restored",
					           reload_error: reload_err };
				}
			}
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
	if (lock == null) return { ok: false, kind: "locked" };
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
         default_acquire_pkg, default_release_pkg,
         default_check_services };
