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

// Pre-flight: confirm every init script we're about to reload actually exists.
// Without this check, a write against a uci section whose daemon isn't installed
// (e.g. POST /sqm/queues on a router without sqm-scripts) would stage + commit,
// fail the first reload with exit 127, succeed the snapshot-restore, then fail
// the SECOND reload with the same exit 127, and surface as `reload_failed_unrecovered`.
// The uci state IS restored fine; only the reload couldn't run. Fail-fast here so
// the caller gets an honest `init_script_missing` (503) before any uci write.
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
		return { ok: true, body: result.body ?? result };
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

return { transaction, with_lock,
         default_acquire, default_release,
         default_acquire_pkg, default_release_pkg,
         default_check_services };
