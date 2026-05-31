let fs = require('fs');

const LOCK_PATH = "/var/lock/uapi.lock";
const SERVICE_NAME_RE = /^[A-Za-z0-9_-]+$/;

function default_reload(services) {
	for (let svc in services) {
		if (type(svc) != "string" || !match(svc, SERVICE_NAME_RE))
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
	let acquire = params.acquire ?? default_acquire;
	let release = params.release ?? default_release;
	let reload = params.reload ?? default_reload;

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

return { transaction, with_lock };
