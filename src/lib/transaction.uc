let fs = require('fs');

const LOCK_PATH = "/var/lock/uapi.lock";

function default_acquire(path) {
	let fd = fs.open(path, "w+");
	if (!fd) return { unavailable: "" + path };
	let r = fd.lock("xn");
	if (r !== true) {
		fd.close();
		return null;
	}
	return fd;
}

function default_release(handle) {
	if (handle) {
		handle.lock("u");
		handle.close();
	}
}

function reload_all(conn, services) {
	for (let svc in services) {
		try {
			conn.call(svc, "reload", {});
		} catch (e) {
			return "" + e;
		}
	}
	return null;
}

function run_inner(conn, pkg, services, fn, snapshot) {
	let result = fn(conn, pkg);

	if (!result || result.ok === false) {
		conn.uci_revert(pkg);
		return result ?? { ok: false, kind: "unknown" };
	}

	conn.uci_commit(pkg);

	let reload_err = reload_all(conn, services);
	if (reload_err == null) {
		return { ok: true, body: result.body ?? result };
	}

	let restore_err = null;
	try {
		conn.uci_import(pkg, snapshot);
		conn.uci_commit(pkg);
		let restore_reload_err = reload_all(conn, services);
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
	let acquire = params.acquire ?? default_acquire;
	let release = params.release ?? default_release;

	let lock = acquire(path);
	if (lock == null) return { ok: false, kind: "locked" };
	if (type(lock) == "object" && lock.unavailable != null)
		return { ok: false, kind: "lock_unavailable", error: lock.unavailable };

	let result = null;
	let caught = null;
	try {
		let snapshot = conn.uci_export(pkg);
		result = run_inner(conn, pkg, services, fn, snapshot);
	} catch (e) {
		caught = e;
	}
	release(lock);
	if (caught != null) die(caught);
	return result;
}

return { transaction };
