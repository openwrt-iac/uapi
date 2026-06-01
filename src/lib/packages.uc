let fs = require('fs');
let errors = require('errors');
let transaction = require('transaction');

const PKG_NAME_RE  = /^[A-Za-z0-9_+][A-Za-z0-9_+.-]*$/;
const FEED_NAME_RE = /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/;
const FEEDS_DIR = "/etc/apk/repositories.d";

function apk_exec(args) {
	let cmd = "apk " + args + " 2>&1";
	let p = fs.popen(cmd, "r");
	if (p == null) return { ok: false, exit_code: -1,
	                        output: sprintf("could not exec apk %s", args) };
	let output = p.read("all") ?? "";
	let exit_code = p.close();
	return { ok: exit_code == 0, exit_code: exit_code, output: trim(output) };
}

function audit_apk_failure(ctx, action, name, r) {
	let log = require('log');
	log.syslog(log.LOG_WARNING,
		sprintf("uapi-pkg-failure %s action=%s name=%J exit=%d output=%J",
			ctx.request_id, action, name, r.exit_code, r.output));
}

function list_installed() {
	// On apk-tools 3.x (OpenWrt 25+), `apk info --installed` returns nothing;
	// plain `apk info` prints one installed package name per line. Older
	// apk-tools 2.x accepted `--installed` but on a uapi router we only
	// target apk-tools 3.x, so the older flag is gone.
	let p = fs.popen("apk info 2>&1", "r");
	if (p == null) return [];
	let raw = p.read("all") ?? "";
	p.close();
	let names = [];
	for (let line in split(raw, "\n")) {
		let t = trim(line);
		if (t == "") continue;
		// Defensive: apk info on some versions can return diagnostic lines
		// that don't look like package names. Filter to the package-name
		// charset we already enforce for writes.
		if (!match(t, /^[A-Za-z0-9_+][A-Za-z0-9_+.-]*$/)) continue;
		push(names, t);
	}
	return names;
}

function info_one(name) {
	if (!match(name, PKG_NAME_RE)) return null;
	let exists = apk_exec(sprintf("info -e -- %s", name));
	if (!exists.ok || exists.output == "") return null;
	let info = apk_exec(sprintf("info -- %s", name));
	let version = null;
	if (info.ok) {
		let first_line = "";
		for (let line in split(info.output, "\n")) {
			let t = trim(line);
			if (t != "") { first_line = t; break; }
		}
		let m = match(first_line, /^[A-Za-z0-9_+.-]+-([^[:space:]-][^[:space:]]*)\s/);
		if (!m) m = match(first_line, /^[A-Za-z0-9_+.-]+-([0-9][^[:space:]]*)/);
		if (m) version = m[1];
	}
	return { id: name, managed: true, name: name,
	         installed: true, version: version, runtime: {} };
}

function list_handler(ctx) {
	let names = list_installed();
	let out = [];
	for (let n in names)
		push(out, { id: n, managed: true, name: n, installed: true,
		            version: null, runtime: {} });
	return errors.ok(ctx, out);
}

function get_one_handler(ctx, name) {
	if (!match(name, PKG_NAME_RE))
		return errors.error(ctx, "not_found", sprintf("invalid package name %J", name));
	let info = info_one(name);
	if (!info)
		return errors.error(ctx, "not_found", sprintf("package %J is not installed", name));
	return errors.ok(ctx, info);
}

function install_handler(ctx, body) {
	if (type(body) != "object")
		return errors.error(ctx, "bad_request", "Request body must be a JSON object");
	let name = body.name;
	if (type(name) != "string" || name == "")
		return errors.validation_failed(ctx,
			[errors.field_error("name", "required", "is required")]);
	if (!match(name, PKG_NAME_RE))
		return errors.validation_failed(ctx,
			[errors.field_error("name", "invalid_format",
			                    "must match ^[A-Za-z0-9_+][A-Za-z0-9_+.-]*$")]);

	let r = transaction.with_lock({ fn: function() {
		let exec = apk_exec(sprintf("add -- %s", name));
		return { ok: exec.ok, exec: exec };
	}});
	if (r.kind == "locked") return errors.locked(ctx);
	if (r.kind == "lock_unavailable")
		return errors.error(ctx, "internal_error",
			sprintf("transaction lock file not available: %s", r.error));
	if (!r.exec.ok) {
		audit_apk_failure(ctx, "install", name, r.exec);
		return errors.error(ctx, "internal_error",
			sprintf("apk add failed (exit %d); see syslog %s for details",
				r.exec.exit_code, ctx.request_id));
	}
	let info = info_one(name);
	if (!info)
		return errors.error(ctx, "internal_error",
			sprintf("apk add reported success but %J is not visible to apk info", name));
	return errors.ok(ctx, info);
}

function remove_handler(ctx, name) {
	if (!match(name, PKG_NAME_RE))
		return errors.error(ctx, "bad_request", sprintf("invalid package name %J", name));
	if (!info_one(name))
		return errors.error(ctx, "not_found", sprintf("package %J is not installed", name));

	let r = transaction.with_lock({ fn: function() {
		let exec = apk_exec(sprintf("del -- %s", name));
		return { ok: exec.ok, exec: exec };
	}});
	if (r.kind == "locked") return errors.locked(ctx);
	if (r.kind == "lock_unavailable")
		return errors.error(ctx, "internal_error",
			sprintf("transaction lock file not available: %s", r.error));
	if (!r.exec.ok) {
		audit_apk_failure(ctx, "remove", name, r.exec);
		return errors.error(ctx, "internal_error",
			sprintf("apk del failed (exit %d); see syslog %s for details",
				r.exec.exit_code, ctx.request_id));
	}
	return errors.no_content(ctx);
}

function feed_path(name) {
	return FEEDS_DIR + "/" + name + ".list";
}

function list_feeds_handler(ctx) {
	let entries = fs.lsdir(FEEDS_DIR) ?? [];
	let out = [];
	for (let f in entries) {
		if (!match(f, /\.list$/)) continue;
		let id = substr(f, 0, length(f) - 5);
		let fp = fs.open(FEEDS_DIR + "/" + f, "r");
		let url = fp ? trim(fp.read("line") ?? "") : "";
		if (fp) fp.close();
		push(out, {
			id: id, managed: true, name: id, filename: f,
			url: url, enabled: true, runtime: {},
		});
	}
	return errors.ok(ctx, out);
}

function get_feed_handler(ctx, id) {
	if (!match(id, FEED_NAME_RE))
		return errors.error(ctx, "not_found", sprintf("invalid feed name %J", id));
	let path = feed_path(id);
	let fp = fs.open(path, "r");
	if (!fp) return errors.error(ctx, "not_found",
		sprintf("feed %J not found", id));
	let url = trim(fp.read("line") ?? "");
	fp.close();
	return errors.ok(ctx, {
		id: id, managed: true, name: id, filename: id + ".list",
		url: url, enabled: true, runtime: {},
	});
}

function create_feed_handler(ctx, body) {
	if (type(body) != "object")
		return errors.error(ctx, "bad_request", "Request body must be a JSON object");
	let name = body.name;
	let url  = body.url;
	let errs = [];
	if (type(name) != "string" || name == "")
		push(errs, errors.field_error("name", "required", "is required"));
	else if (!match(name, FEED_NAME_RE))
		push(errs, errors.field_error("name", "invalid_format",
		                              "must match ^[A-Za-z0-9_][A-Za-z0-9_.-]*$"));
	if (type(url) != "string" || url == "")
		push(errs, errors.field_error("url", "required", "is required"));
	else if (!match(url, /^https?:\/\//))
		push(errs, errors.field_error("url", "invalid_format",
		                              "must start with http:// or https://"));
	if (length(errs) > 0)
		return errors.validation_failed(ctx, errs);

	let r = transaction.with_lock({ fn: function() {
		let path = feed_path(name);
		if (fs.stat(path) != null) return { ok: false, kind: "conflict" };
		// O_EXCL: if a concurrent writer created the file between the stat
		// above and this open, fail (don't truncate someone else's content).
		let fp = fs.open(path, "wx");
		if (!fp) {
			// Either the file appeared in the TOCTOU window (treat as
			// conflict) or the open failed for an unrelated reason.
			if (fs.stat(path) != null) return { ok: false, kind: "conflict" };
			return { ok: false, kind: "io_error" };
		}
		fp.write(url + "\n");
		fp.close();
		let upd = apk_exec("update");
		return { ok: true, update_ok: upd.ok, update_output: upd.output,
		         update_exit: upd.exit_code };
	}});
	if (r.kind == "locked") return errors.locked(ctx);
	if (r.kind == "lock_unavailable")
		return errors.error(ctx, "internal_error",
			sprintf("transaction lock file not available: %s", r.error));
	if (r.kind == "conflict")
		return errors.error(ctx, "conflict",
			sprintf("feed %J already exists", name));
	if (r.kind == "io_error")
		return errors.error(ctx, "internal_error",
			sprintf("could not create feed %J", name));

	let update_status = "ok";
	if (!r.update_ok) {
		audit_apk_failure(ctx, "feed_create_update", name,
			{ exit_code: r.update_exit, output: r.update_output });
		update_status = sprintf("apk update failed (exit %d); see syslog %s",
			r.update_exit, ctx.request_id);
	}
	return errors.ok(ctx, { id: name, managed: true, name: name,
	                        filename: name + ".list", url: url, enabled: true,
	                        update_status: update_status, runtime: {} });
}

function remove_feed_handler(ctx, id) {
	if (!match(id, FEED_NAME_RE))
		return errors.error(ctx, "bad_request", sprintf("invalid feed name %J", id));
	let path = feed_path(id);
	if (fs.stat(path) == null)
		return errors.error(ctx, "not_found",
			sprintf("feed %J not found", id));

	let r = transaction.with_lock({ fn: function() {
		if (fs.stat(path) == null) return { ok: false, kind: "gone" };
		if (!fs.unlink(path)) return { ok: false, kind: "io_error" };
		apk_exec("update");
		return { ok: true };
	}});
	if (r.kind == "locked") return errors.locked(ctx);
	if (r.kind == "lock_unavailable")
		return errors.error(ctx, "internal_error",
			sprintf("transaction lock file not available: %s", r.error));
	if (r.kind == "gone")
		return errors.error(ctx, "not_found", sprintf("feed %J vanished", id));
	if (r.kind == "io_error")
		return errors.error(ctx, "internal_error",
			sprintf("could not remove feed %J", id));
	return errors.no_content(ctx);
}

return {
	list_installed: list_handler,
	get_installed: get_one_handler,
	install: install_handler,
	remove_installed: remove_handler,
	list_feeds: list_feeds_handler,
	get_feed: get_feed_handler,
	create_feed: create_feed_handler,
	remove_feed: remove_feed_handler,
};
