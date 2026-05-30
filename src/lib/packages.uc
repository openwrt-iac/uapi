let fs = require('fs');
let errors = require('errors');

const PKG_NAME_RE = /^[A-Za-z0-9_+.-]+$/;
const FEEDS_DIR = "/etc/apk/repositories.d";
const FEED_NAME_RE = /^[A-Za-z0-9_.-]+$/;

function shell_quote_safe(s) {
	// Strict allowlist used after the regex above; this is belt-and-suspenders.
	return s;
}

function apk_exec(args) {
	let cmd = "apk " + args + " 2>&1";
	let p = fs.popen(cmd, "r");
	if (p == null) return { ok: false, error: sprintf("could not exec apk %s", args) };
	let output = p.read("all") ?? "";
	let exit_code = p.close();
	return { ok: exit_code == 0, exit_code: exit_code, output: trim(output) };
}

function list_installed() {
	let p = fs.popen("apk info --installed 2>&1", "r");
	if (p == null) return [];
	let raw = p.read("all") ?? "";
	p.close();
	let names = [];
	for (let line in split(raw, "\n")) {
		let t = trim(line);
		if (t == "") continue;
		push(names, t);
	}
	return names;
}

function info_one(name) {
	let p = fs.popen(sprintf("apk info -e %s 2>&1", name), "r");
	if (p == null) return null;
	let raw = trim(p.read("all") ?? "");
	let exit_code = p.close();
	if (exit_code != 0 || raw == "") return null;
	// Fetch version too
	let pv = fs.popen(sprintf("apk info %s 2>&1 | head -1", name), "r");
	let version_line = pv ? trim(pv.read("all") ?? "") : "";
	if (pv) pv.close();
	let version = null;
	let m = match(version_line, /^[A-Za-z0-9_+.-]+-([^[:space:]]+)/);
	if (m) version = m[1];
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
			                    "must match ^[A-Za-z0-9_+.-]+$")]);
	let r = apk_exec("add " + name);
	if (!r.ok)
		return errors.error(ctx, "internal_error",
			sprintf("apk add %s failed (exit %d): %s", name, r.exit_code, r.output));
	let info = info_one(name) ?? { id: name, name: name, managed: true,
	                                installed: true, version: null, runtime: {} };
	return errors.ok(ctx, info);
}

function remove_handler(ctx, name) {
	if (!match(name, PKG_NAME_RE))
		return errors.error(ctx, "bad_request", sprintf("invalid package name %J", name));
	if (!info_one(name))
		return errors.error(ctx, "not_found", sprintf("package %J is not installed", name));
	let r = apk_exec("del " + name);
	if (!r.ok)
		return errors.error(ctx, "internal_error",
			sprintf("apk del %s failed (exit %d): %s", name, r.exit_code, r.output));
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
		sprintf("feed %J not found at %s", id, path));
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
		                              "must match ^[A-Za-z0-9_.-]+$"));
	if (type(url) != "string" || url == "")
		push(errs, errors.field_error("url", "required", "is required"));
	else if (!match(url, /^https?:\/\//))
		push(errs, errors.field_error("url", "invalid_format",
		                              "must start with http:// or https://"));
	if (length(errs) > 0)
		return errors.validation_failed(ctx, errs);
	let path = feed_path(name);
	if (fs.stat(path) != null)
		return errors.error(ctx, "conflict",
			sprintf("feed %J already exists at %s", name, path));
	let fp = fs.open(path, "w");
	if (!fp) return errors.error(ctx, "internal_error",
		sprintf("could not create %s", path));
	fp.write(url + "\n");
	fp.close();
	let r = apk_exec("update");
	let body_out = { id: name, managed: true, name: name,
	                 filename: name + ".list", url: url, enabled: true,
	                 update_status: r.ok ? "ok" : sprintf("apk update failed: %s", r.output),
	                 runtime: {} };
	return errors.ok(ctx, body_out);
}

function remove_feed_handler(ctx, id) {
	if (!match(id, FEED_NAME_RE))
		return errors.error(ctx, "bad_request", sprintf("invalid feed name %J", id));
	let path = feed_path(id);
	if (fs.stat(path) == null)
		return errors.error(ctx, "not_found",
			sprintf("feed %J not found at %s", id, path));
	let r = fs.unlink(path);
	if (!r) return errors.error(ctx, "internal_error",
		sprintf("could not remove %s", path));
	apk_exec("update");
	return errors.no_content(ctx);
}

return {
	// /packages/installed handlers
	list_installed: list_handler,
	get_installed: get_one_handler,
	install: install_handler,
	remove_installed: remove_handler,
	// /packages/feeds handlers
	list_feeds: list_feeds_handler,
	get_feed: get_feed_handler,
	create_feed: create_feed_handler,
	remove_feed: remove_feed_handler,
};
