let ids = require("ids");
let errors = require("errors");
let scope = require("scope");
let transaction = require("transaction");
let ucitrack = require("ucitrack");
let handler = require("handler");

const ID_RE = /^[A-Za-z0-9_]+$/;
let load_section = handler.load_section;

const TYPE_DOMAIN_MAP = {
	"firewall.rule":        ["firewall", "rules"],
	"firewall.zone":        ["firewall", "zones"],
	"firewall.redirect":    ["firewall", "redirects"],
	"network.interface":    ["network", "interfaces"],
	"network.device":       ["network", "devices"],
	"wireless.wifi-device": ["wireless", "devices"],
	"wireless.wifi-iface":  ["wireless", "interfaces"],
	"dhcp.host":            ["dhcp", "hosts"],
	"dhcp.lease":           ["dhcp", "leases"],
	"system.system":        ["system"],
};

function inferred_domain_path(pkg, sec_type) {
	let key = pkg + "." + sec_type;
	return TYPE_DOMAIN_MAP[key] ?? [pkg];
}

function permits_raw(scopes, pkg, verb) {
	return scope.permits(scopes, ["raw", pkg], verb);
}

function permits_domain(scopes, pkg, sec_type, verb) {
	return scope.permits(scopes, inferred_domain_path(pkg, sec_type), verb);
}

function normalize_section(s) {
	let out = {
		id: s['.name'],
		'.type': s['.type'],
		managed: !s['.anonymous'],
	};
	for (let k in s) {
		if (substr(k, 0, 1) == ".") continue;
		out[k] = s[k];
	}
	return out;
}

function build_response_body(view, reload_info) {
	let body = normalize_section(view);
	body.reloaded = !!reload_info.known;
	body.reload_services = reload_info.services;
	if (!reload_info.known)
		body.reload_note = "no reload service is known for this package; configuration is on disk but no daemon was notified";
	return body;
}

function translate_raw_tx(ctx, result) {
	if (result.ok) return errors.ok(ctx, result.body);
	if (result.kind == "locked") return errors.locked(ctx);
	if (result.kind == "lock_unavailable")
		return errors.error(ctx, "internal_error",
		                    sprintf("transaction lock file not available: %s", result.error));
	if (result.kind == "not_found")
		return errors.error(ctx, "not_found", result.message);
	if (result.kind == "conflict")
		return errors.error(ctx, "conflict", result.message);
	if (result.kind == "reload_failed_restored")
		return errors.reload_failed_restored(ctx, result.reload_error);
	if (result.kind == "reload_failed_unrecovered")
		return errors.reload_failed_unrecovered(ctx, result.reload_error, result.restore_error);
	return errors.error(ctx, "internal_error",
	                    sprintf("transaction returned unknown kind %J", result.kind));
}

function reject_dotted_options(body) {
	for (let k in body) {
		if (k == ".type" || k == "id") continue;
		if (substr(k, 0, 1) == ".")
			return errors.field_error(k, "invalid_format",
			                          sprintf("option %J: dotted keys other than .type are reserved", k));
	}
	return null;
}

function list(conn, ctx, scopes, pkg) {
	if (!permits_raw(scopes, pkg, "ro") || !scope.permits(scopes, [pkg], "ro"))
		return errors.error(ctx, "insufficient_scope",
		                    sprintf("Token does not permit listing %s via /raw/", pkg));

	let sections = [];
	conn.uci_foreach(pkg, null, function(s) {
		push(sections, normalize_section(s));
	});
	return errors.ok(ctx, sections);
}

function get_one(conn, ctx, scopes, pkg, id) {
	let s = load_section(conn, pkg, id);
	if (!s)
		return errors.error(ctx, "not_found",
		                    sprintf("No section %s.%s", pkg, id));

	let sec_type = s['.type'];
	if (!permits_raw(scopes, pkg, "ro") || !permits_domain(scopes, pkg, sec_type, "ro"))
		return errors.error(ctx, "insufficient_scope",
		                    sprintf("Token does not permit reading %s.%s (type %s)", pkg, id, sec_type));

	return errors.ok(ctx, normalize_section(s));
}

function create(conn, ctx, scopes, pkg, body) {
	if (type(body) != "object")
		return errors.error(ctx, "bad_request", "Request body must be a JSON object");
	let sec_type = body[".type"];
	if (type(sec_type) != "string" || sec_type == "")
		return errors.validation_failed(ctx,
			[errors.field_error(".type", "required", "is required on raw create")]);

	let dotted_err = reject_dotted_options(body);
	if (dotted_err)
		return errors.validation_failed(ctx, [dotted_err]);

	if (!permits_raw(scopes, pkg, "rw") || !permits_domain(scopes, pkg, sec_type, "rw"))
		return errors.error(ctx, "insufficient_scope",
		                    sprintf("Token does not permit creating %s.%s (type %s) via /raw/", pkg, sec_type, sec_type));

	let client_supplied_id = body.id != null && body.id != "";
	let new_id;
	if (client_supplied_id) {
		new_id = body.id;
		if (type(new_id) != "string" || !match(new_id, ID_RE))
			return errors.validation_failed(ctx,
				[errors.field_error("id", "invalid_format",
				                    "id must match /^[A-Za-z0-9_]+$/ (uci section-name charset)")]);
		if (load_section(conn, pkg, new_id) != null)
			return errors.error(ctx, "conflict",
			                    sprintf("Section %s.%s already exists", pkg, new_id));
	} else {
		new_id = ids.new_id(substr(sec_type, 0, 1));
	}

	let reload = ucitrack.reload_services(conn, pkg);
	let opts = {};
	for (let k in body) {
		if (k == ".type" || k == "id") continue;
		opts[k] = body[k];
	}

	let result = transaction.transaction(conn, {
		package: pkg,
		reload_services: reload.services,
		fn: function(c, p) {
			if (client_supplied_id && load_section(c, p, new_id) != null)
				return { ok: false, kind: "conflict",
				         message: sprintf("Section %s.%s already exists", pkg, new_id) };
			c.uci_create_section(p, new_id, sec_type);
			for (let k in opts) c.uci_set(p, new_id, k, opts[k]);
			let view = { ...opts };
			view['.name'] = new_id;
			view['.anonymous'] = false;
			view['.type'] = sec_type;
			return { ok: true, body: build_response_body(view, reload) };
		},
	});

	return translate_raw_tx(ctx, result);
}

function replace(conn, ctx, scopes, pkg, id, body) {
	if (type(body) != "object")
		return errors.error(ctx, "bad_request", "Request body must be a JSON object");
	let preview = load_section(conn, pkg, id);
	if (!preview)
		return errors.error(ctx, "not_found", sprintf("No section %s.%s", pkg, id));
	let sec_type = preview['.type'];
	if (!permits_raw(scopes, pkg, "rw") || !permits_domain(scopes, pkg, sec_type, "rw"))
		return errors.error(ctx, "insufficient_scope",
		                    sprintf("Token does not permit writing %s.%s (type %s) via /raw/", pkg, id, sec_type));

	let dotted_err = reject_dotted_options(body);
	if (dotted_err)
		return errors.validation_failed(ctx, [dotted_err]);

	let reload = ucitrack.reload_services(conn, pkg);
	let new_opts = {};
	for (let k in body) {
		if (k == ".type" || k == "id") continue;
		new_opts[k] = body[k];
	}

	let result = transaction.transaction(conn, {
		package: pkg,
		reload_services: reload.services,
		fn: function(c, p) {
			let existing = load_section(c, p, id);
			if (!existing)
				return { ok: false, kind: "not_found",
				         message: sprintf("No section %s.%s", pkg, id) };
			for (let k in existing) {
				if (substr(k, 0, 1) == ".") continue;
				if (exists(new_opts, k)) continue;
				c.uci_delete(p, id, k);
			}
			for (let k in new_opts) c.uci_set(p, id, k, new_opts[k]);
			let view = { ...new_opts };
			view['.name'] = id;
			view['.anonymous'] = !!existing['.anonymous'];
			view['.type'] = existing['.type'];
			return { ok: true, body: build_response_body(view, reload) };
		},
	});

	return translate_raw_tx(ctx, result);
}

function patch(conn, ctx, scopes, pkg, id, body) {
	if (type(body) != "object")
		return errors.error(ctx, "bad_request", "Request body must be a JSON object");
	let preview = load_section(conn, pkg, id);
	if (!preview)
		return errors.error(ctx, "not_found", sprintf("No section %s.%s", pkg, id));
	let sec_type = preview['.type'];
	if (!permits_raw(scopes, pkg, "rw") || !permits_domain(scopes, pkg, sec_type, "rw"))
		return errors.error(ctx, "insufficient_scope",
		                    sprintf("Token does not permit writing %s.%s via /raw/", pkg, id));

	let dotted_err = reject_dotted_options(body);
	if (dotted_err)
		return errors.validation_failed(ctx, [dotted_err]);

	let reload = ucitrack.reload_services(conn, pkg);
	let updates = {};
	for (let k in body) {
		if (k == ".type" || k == "id") continue;
		updates[k] = body[k];
	}

	let result = transaction.transaction(conn, {
		package: pkg,
		reload_services: reload.services,
		fn: function(c, p) {
			let existing = load_section(c, p, id);
			if (!existing)
				return { ok: false, kind: "not_found",
				         message: sprintf("No section %s.%s", pkg, id) };
			for (let k in updates) c.uci_set(p, id, k, updates[k]);
			let view = { ...existing, ...updates };
			view['.name'] = id;
			view['.type'] = existing['.type'];
			return { ok: true, body: build_response_body(view, reload) };
		},
	});

	return translate_raw_tx(ctx, result);
}

function remove(conn, ctx, scopes, pkg, id) {
	let preview = load_section(conn, pkg, id);
	if (!preview)
		return errors.error(ctx, "not_found", sprintf("No section %s.%s", pkg, id));
	let sec_type = preview['.type'];
	if (!permits_raw(scopes, pkg, "rw") || !permits_domain(scopes, pkg, sec_type, "rw"))
		return errors.error(ctx, "insufficient_scope",
		                    sprintf("Token does not permit deleting %s.%s via /raw/", pkg, id));

	let reload = ucitrack.reload_services(conn, pkg);
	let result = transaction.transaction(conn, {
		package: pkg,
		reload_services: reload.services,
		fn: function(c, p) {
			let existing = load_section(c, p, id);
			if (!existing)
				return { ok: false, kind: "not_found",
				         message: sprintf("No section %s.%s", pkg, id) };
			c.uci_delete(p, id);
			return { ok: true, body: null };
		},
	});
	if (result.ok) return errors.no_content(ctx);
	return translate_raw_tx(ctx, result);
}

return {
	list,
	get_one,
	create,
	replace,
	patch,
	remove,
	inferred_domain_path,
	TYPE_DOMAIN_MAP,
};
