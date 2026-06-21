let fs = require('fs');
let apply_confirm = require('apply_confirm');

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
// per-package file. Returns the fd handle on success, or one of:
//   { contention: "global" }  - non-uci writer holds the global EX
//   { contention: "package" } - another uci writer holds this package's EX
//   { unavailable: <path> }   - file open failed (infrastructure)
// The contention distinction feeds the 423 message identity so the
// caller learns which lock blocked them.
function default_acquire_pkg(global_path, package) {
	if (type(package) != "string" || !match(package, SAFE_NAME_RE))
		return { unavailable: sprintf("invalid package name %J", package) };
	let g = _lock_one(global_path ?? LOCK_PATH, "s");
	if (g == null) return { contention: "global" };
	if (type(g) == "object" && g.unavailable != null) return g;
	let p = _lock_one(PKG_LOCK_PREFIX + package + ".lock", "x");
	if (p == null) { _release_one(g); return { contention: "package" }; }
	if (type(p) == "object" && p.unavailable != null) { _release_one(g); return p; }
	return { _g: g, _p: p };
}

function default_release_pkg(handle) {
	if (handle == null) return;
	_release_one(handle._p);
	_release_one(handle._g);
}

// Shape the post-reload result: success on reload_err == null, otherwise run
// restore_fn (which performs uci_import + uci_commit + reload) and classify
// as reload_failed_restored / reload_failed_unrecovered.
function _finalize_after_reload(reload_err, restore_fn, body, services) {
	if (reload_err == null) {
		return { ok: true, body: body,
		         reload_services: services,
		         reload_status: (length(services) > 0) ? "ok" : "no_reload" };
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

// Attach the confirm block to a successful result, or disarm the window when
// uapi already reverted in-band (the apply reload failed, so the staged
// rollback is now pointless and must not fire later). Disarm with ac_ack, not
// ac_rollback: uapi has already restored the pre-change config in-band, so we
// only need to cancel apply-confirm's timer. ac_rollback would re-import the
// (identical) snapshot and run a redundant second service reload whose failure
// we could not surface. `armed` is ac_stage's return; null when no confirm.
function _attach_confirm(result, armed, packages) {
	if (armed == null) return result;
	if (result.ok)
		result.confirm = { token: armed.token, timeout: armed.timeout,
		                   deadline: armed.deadline, packages };
	else
		apply_confirm.ac_ack(armed.token);
	return result;
}

function run_inner(conn, pkg, services, fn, snapshot, reload, confirm) {
	let result = fn(conn, pkg);

	if (!result || result.ok === false) {
		conn.uci_revert(pkg);
		return result ?? { ok: false, kind: "unknown" };
	}

	// Arm the commit-confirmed rollback BEFORE commit: apply-confirm snapshots
	// the on-disk pre-change config, which uci_commit is about to overwrite.
	let armed = null;
	if (confirm != null) {
		armed = apply_confirm.ac_stage([pkg], services, confirm);
		if (!armed.ok) {
			conn.uci_revert(pkg);
			return { ok: false, kind: armed.kind, message: armed.message };
		}
	}

	// If commit or reload throws after the window is armed, disarm it before
	// propagating: otherwise a stale rollback fires at the deadline and reverts
	// whatever state exists then, with no token ever delivered to ack.
	let fin;
	try {
		conn.uci_commit(pkg);
		fin = _finalize_after_reload(reload(services), function() {
			conn.uci_import(pkg, snapshot);
			conn.uci_commit(pkg);
			return reload(services);
		}, result.body, services);
	} catch (e) {
		if (armed != null) apply_confirm.ac_rollback(armed.token);
		die(e);
	}

	return _attach_confirm(fin, armed, [pkg]);
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
	// `null` means a test/legacy stub that pre-dates the contention sentinel;
	// treat as per-package since that's the production-default flavour.
	if (lock == null)
		return { ok: false, kind: "locked", lock_kind: "package", package: pkg };
	if (type(lock) == "object" && lock.contention != null) {
		if (lock.contention == "global")
			return { ok: false, kind: "locked", lock_kind: "global" };
		return { ok: false, kind: "locked", lock_kind: "package", package: pkg };
	}
	if (type(lock) == "object" && lock.unavailable != null)
		return { ok: false, kind: "lock_unavailable", error: lock.unavailable };

	let result = null;
	let caught = null;
	try {
		let snapshot = conn.uci_export(pkg);
		result = run_inner(conn, pkg, services, fn, snapshot, reload, params.confirm);
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
	// Global SH contention means a non-uci writer holds EX (system/password,
	// packages/installed, etc.). Report it as such so the client knows the
	// blocker isn't another uci write.
	if (g == null) return { ok: false, kind: "locked", lock_kind: "global" };
	if (type(g) == "object" && g.unavailable != null)
		return { ok: false, kind: "lock_unavailable", error: g.unavailable };
	for (let pkg in sorted) {
		let p = _lock_one(PKG_LOCK_PREFIX + pkg + ".lock", "x");
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
	let armed = null;
	try {
		for (let pkg in sorted) snapshots[pkg] = conn.uci_export(pkg);
		let inner = fn(conn);
		if (!inner || inner.ok === false) {
			for (let pkg in sorted) conn.uci_revert(pkg);
			result = inner ?? { ok: false, kind: "unknown" };
		} else {
			// Arm the commit-confirmed rollback over all packages before any
			// commit (apply-confirm snapshots the pre-change on-disk config).
			if (params.confirm != null) {
				armed = apply_confirm.ac_stage(sorted, services, params.confirm);
				if (!armed.ok) {
					for (let pkg in sorted) conn.uci_revert(pkg);
					result = { ok: false, kind: armed.kind, message: armed.message };
				}
			}
			if (result == null) {
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
				result = _attach_confirm(_finalize_after_reload(reload_err, function() {
					for (let pkg in sorted) {
						conn.uci_import(pkg, snapshots[pkg]);
						conn.uci_commit(pkg);
					}
					return reload(services);
				}, inner.body, services), armed, sorted);
			}
		}
	} catch (e) { caught = e; }

	for (let h in acquired) _release_one(h);
	_release_one(g);
	if (caught != null) {
		// A throw after arming (e.g. reload throwing) would leave the window
		// armed; disarm before propagating so a stale rollback can't fire.
		if (armed != null) apply_confirm.ac_rollback(armed.token);
		die(caught);
	}
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
         default_acquire_pkg, default_release_pkg,
         default_check_services };
