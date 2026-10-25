let ids = require("ids");
let errors = require("errors");
let scope = require("scope");
let transaction = require("transaction");
let ucitrack = require("ucitrack");
let handler = require("handler");

const ID_RE = /^[A-Za-z0-9_]+$/;
const TYPE_RE = /^[!-~]+$/;
// uci takes these in a type, but writes the type unquoted, so the file re-reads them as a
// quote, a comment, a separator or an escape. `config rule#x 's'` came back as an anonymous
// rule, which the scope check had mapped to [firewall], and a quote left the package unparseable.
const TYPE_UNQUOTED_RE = /["#';\\]/;
const UCI_SCALAR = { string: true, int: true, double: true, bool: true };
// Body keys that are not options. `.type` and `id` name the section. `managed` and the reload
// fields are derived on every response, so a read-modify-write client echoes them, and stored
// as options they would shadow the derived values on the way back out.
const NOT_OPTIONS = { ".type": true, "id": true, "managed": true,
                      "reloaded": true, "reload_services": true, "reload_note": true };
let load_section = handler.load_section;

const TYPE_DOMAIN_MAP = {
	"firewall.rule":        ["firewall", "rules"],
	"firewall.zone":        ["firewall", "zones"],
	"firewall.redirect":    ["firewall", "redirects"],
	"firewall.forwarding":  ["firewall", "forwardings"],
	"firewall.defaults":    ["firewall", "defaults"],
	"network.interface":    ["network", "interfaces"],
	"network.device":       ["network", "devices"],
	"network.route":        ["network", "routes"],
	"network.rule":         ["network", "rules"],
	"network.bridge-vlan":  ["network", "bridge_vlans"],
	"wireless.wifi-device": ["wireless", "devices"],
	"wireless.wifi-iface":  ["wireless", "interfaces"],
	"dhcp.host":            ["dhcp", "hosts"],
	"dhcp.lease":           ["dhcp", "leases"],
	"dhcp.dhcp":            ["dhcp", "servers"],
	"dhcp.dnsmasq":         ["dhcp", "dnsmasq"],
	"dhcp.odhcpd":          ["dhcp", "odhcpd"],
	"system.system":        ["system"],
	"system.timeserver":    ["system", "timeservers"],
	"dropbear.dropbear":    ["dropbear", "instances"],
	"uhttpd.uhttpd":        ["uhttpd", "instances"],
	"uhttpd.cert":          ["uhttpd", "certs"],
	"unbound.unbound":      ["unbound", "server"],
	"sqm.queue":            ["sqm", "queues"],
	"snmpd.agent":          ["snmpd", "agents"],
	"snmpd.com2sec":        ["snmpd", "com2secs"],
	"snmpd.group":          ["snmpd", "groups"],
	"snmpd.access":         ["snmpd", "accesses"],
	"snmpd.system":         ["snmpd", "system"],
	"lldpd.lldpd":          ["lldpd", "config"],
	"prometheus-node-exporter-lua.prometheus-node-exporter-lua": ["prometheus_node_exporter_lua", "config"],
	"vnstat.vnstat":        ["vnstat", "config"],
	"vnstat.interface":     ["vnstat", "interfaces"],
};

function inferred_domain_path(pkg, sec_type) {
	let key = pkg + "." + sec_type;
	if (TYPE_DOMAIN_MAP[key]) return TYPE_DOMAIN_MAP[key];
	// Dynamic section types: wireguard_<iface> peer sections map to network/wireguard_peers
	if (pkg == "network" && type(sec_type) == "string" && substr(sec_type, 0, 10) == "wireguard_")
		return ["network", "wireguard_peers"];
	return [pkg];
}

function permits_raw(scopes, pkg, verb) {
	return scope.permits(scopes, ["raw", pkg], verb);
}

function permits_domain(scopes, pkg, sec_type, verb) {
	return scope.permits(scopes, inferred_domain_path(pkg, sec_type), verb);
}

// Composite raw check: both the raw tree and the domain tree must permit
// the verb. sec_type may be null for list (uses bare-pkg domain). Returns
// null on pass or an insufficient_scope envelope.
function require_raw_scope(ctx, scopes, pkg, sec_type, verb, action) {
	let domain_ok = (sec_type == null)
		? scope.permits(scopes, [pkg], verb)
		: permits_domain(scopes, pkg, sec_type, verb);
	if (permits_raw(scopes, pkg, verb) && domain_ok) return null;
	return errors.error(ctx, "insufficient_scope",
	                    sprintf("Token does not permit %s", action));
}

// The curated token endpoints gate `salt` and `hash` behind an include_secret flag that only
// the internal auth path sets, so the passthrough must not hand back verbatim what they take
// care to mask. Reaching a token section already needs both `raw:uapi` and `uapi:tokens`, so
// this is not an escalation path; what it stops is credential material flowing into whatever a
// raw read feeds, a config export or a backup being the obvious ones.
const SECRET_BY_TYPE = { "token": { "salt": true, "hash": true } };

function normalize_section(s) {
	let out = {
		id: s['.name'],
		'.type': s['.type'],
	};
	let secret = SECRET_BY_TYPE[s['.type']] ?? {};
	for (let k in s) {
		if (substr(k, 0, 1) == ".") continue;
		if (secret[k]) continue;
		// zerotier stores its network id as `option id`, which used to replace the section
		// name here, so the read named a section that did not exist.
		if (k == "id") continue;
		out[k] = s[k];
	}
	// After the copy, not before it. `managed` is derived from `.anonymous`, but a section
	// written by a client before raw stopped storing the field carries a literal
	// `option managed`, and that stored string used to overwrite the derived boolean here:
	// the response came back as "0" against a schema that declares boolean. Deriving last
	// makes those sections read correctly whether or not the stale option is ever removed.
	out.managed = !s['.anonymous'];
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
	if (result.kind == "locked")
		return errors.locked_from(ctx, null, result);
	if (result.kind == "lock_unavailable")
		return errors.lock_unavailable(ctx, result.error);
	if (result.kind == "not_found")
		return errors.error(ctx, "not_found", result.message);
	if (result.kind == "conflict")
		return errors.error(ctx, "conflict", result.message);
	if (result.kind == "init_script_missing")
		return errors.error(ctx, "init_script_missing", result.message);
	if (result.kind == "config_missing")
		return errors.error(ctx, "config_missing", result.message);
	if (result.kind == "reload_failed_restored")
		return errors.reload_failed_restored(ctx, result.reload_error);
	if (result.kind == "reload_failed_unrecovered")
		return errors.reload_failed_unrecovered(ctx, result.reload_error, result.restore_error);
	return errors.error(ctx, "internal_error",
	                    sprintf("transaction returned unknown kind %J", result.kind));
}

// Raw has no toUci, so this is where a body becomes uci options. The cursor stores nothing for a
// name outside the uci charset and still returns true, refuses a null or an object, and keeps
// only part of a list that holds one. null and "" remove the option, as [] does: "" is uci's own
// removal, and the binding drops a "" that leads a longer list.
function writable_options(body) {
	let opts = {}, errs = [];
	for (let k, v in body) {
		if (NOT_OPTIONS[k]) continue;
		if (!match(k, ID_RE)) {
			push(errs, errors.field_error(k, "invalid_format", "must hold only letters, digits and _, the option names uci stores"));
			continue;
		}
		if (v == null || v === "") {
			opts[k] = [];
			continue;
		}
		if (type(v) != "array") {
			if (!UCI_SCALAR[type(v)])
				push(errs, errors.field_error(k, "invalid_type", "must be a string, a number, a boolean, a list of them, or null to remove the option"));
			opts[k] = v;
			continue;
		}
		for (let i = 0; i < length(v); i++)
			if (!UCI_SCALAR[type(v[i])])
				push(errs, errors.field_error(sprintf("%s[%d]", k, i), "invalid_type", "must be a string, a number or a boolean"));
		if (length(v) > 1 && v[0] === "")
			push(errs, errors.field_error(k + "[0]", "invalid_format", "must not be empty at the start of a longer list, because uci drops it"));
		opts[k] = v;
	}
	return { opts, errors: errs };
}

// The section is named by the path and typed by uci, so a body can only echo them. Before,
// any value answered 200 and changed nothing.
function identity_errors(body, id, sec_type) {
	let errs = [];
	if (body[".type"] != null && body[".type"] !== sec_type)
		push(errs, errors.field_error(".type", "read_only", sprintf("must be %J, the type of the section: raw cannot change it", sec_type)));
	if (body.id != null && body.id !== id)
		push(errs, errors.field_error("id", "read_only", sprintf("must be %J, the section in the path: raw cannot rename it", id)));
	return errs;
}

function list(conn, ctx, scopes, pkg) {
	let denied = require_raw_scope(ctx, scopes, pkg, null, "ro",
		sprintf("listing %s via /raw/", pkg));
	if (denied != null) return denied;

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
	let denied = require_raw_scope(ctx, scopes, pkg, sec_type, "ro",
		sprintf("reading %s.%s (type %s)", pkg, id, sec_type));
	if (denied != null) return denied;

	return errors.ok(ctx, normalize_section(s));
}

function create(conn, ctx, scopes, pkg, body) {
	if (type(body) != "object")
		return errors.error(ctx, "bad_request", "Request body must be a JSON object");
	let sec_type = body[".type"];
	let new_id = body.id;
	let client_supplied_id = new_id != null && new_id !== "";
	let errs = [];
	if (type(sec_type) != "string" || sec_type == "")
		push(errs, errors.field_error(".type", "required", "is required on raw create"));
	else if (!match(sec_type, TYPE_RE) || match(sec_type, TYPE_UNQUOTED_RE))
		push(errs, errors.field_error(".type", "invalid_format",
			"must be printable ASCII without spaces or any of \" # ' ; \\, because uci writes the type unquoted"));
	if (client_supplied_id && (type(new_id) != "string" || !match(new_id, ID_RE)))
		push(errs, errors.field_error("id", "invalid_format",
			"must hold only letters, digits and _, the section names uci stores"));
	let w = writable_options(body);
	push(errs, ...w.errors);
	if (length(errs) > 0)
		return errors.validation_failed(ctx, errs);

	let denied = require_raw_scope(ctx, scopes, pkg, sec_type, "rw",
		sprintf("creating %s.%s (type %s) via /raw/", pkg, sec_type, sec_type));
	if (denied != null) return denied;

	if (client_supplied_id) {
		if (load_section(conn, pkg, new_id) != null)
			return errors.error(ctx, "conflict",
			                    sprintf("Section %s.%s already exists", pkg, new_id));
	} else {
		// ids.new_id takes only lowercase letters, so a type such as olsrd's LoadPlugin, or
		// one that starts with a digit, answered 500.
		let initial = lc(substr(sec_type, 0, 1));
		new_id = ids.new_id(match(initial, /^[a-z]$/) ? initial : null);
	}

	let reload = ucitrack.reload_services(conn, pkg);
	let result = transaction.transaction(conn, {
		package: pkg,
		reload_services: reload.services,
		fn: function(c, p) {
			if (client_supplied_id && load_section(c, p, new_id) != null)
				return { ok: false, kind: "conflict",
				         message: sprintf("Section %s.%s already exists", pkg, new_id) };
			c.uci_create_section(p, new_id, sec_type);
			for (let k in w.opts) c.uci_set(p, new_id, k, w.opts[k]);
			return { ok: true, body: build_response_body(load_section(c, p, new_id), reload) };
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
	let denied = require_raw_scope(ctx, scopes, pkg, sec_type, "rw",
		sprintf("writing %s.%s (type %s) via /raw/", pkg, id, sec_type));
	if (denied != null) return denied;

	let w = writable_options(body);
	let errs = identity_errors(body, id, sec_type);
	push(errs, ...w.errors);
	if (length(errs) > 0)
		return errors.validation_failed(ctx, errs);

	let reload = ucitrack.reload_services(conn, pkg);

	let result = transaction.transaction(conn, {
		package: pkg,
		reload_services: reload.services,
		fn: function(c, p) {
			let existing = load_section(c, p, id);
			if (!existing)
				return { ok: false, kind: "not_found",
				         message: sprintf("No section %s.%s", pkg, id) };
			let secret = SECRET_BY_TYPE[existing['.type']] ?? {};
			for (let k in existing) {
				if (substr(k, 0, 1) == ".") continue;
				if (exists(w.opts, k)) continue;
				// A stripped secret, or a stored `option id` hidden behind the section name,
				// is absent from every read, so no replace body can carry it back. Deleting
				// it here would make an ordinary read-modify-write destroy the credential or
				// zerotier's network id, which is the trap `carry_write_only` exists to
				// avoid on the curated side.
				if (secret[k] || k == "id") continue;
				c.uci_delete(p, id, k);
			}
			for (let k in w.opts) c.uci_set(p, id, k, w.opts[k]);
			return { ok: true, body: build_response_body(load_section(c, p, id), reload) };
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
	let denied = require_raw_scope(ctx, scopes, pkg, sec_type, "rw",
		sprintf("writing %s.%s via /raw/", pkg, id));
	if (denied != null) return denied;

	let w = writable_options(body);
	let errs = identity_errors(body, id, sec_type);
	push(errs, ...w.errors);
	if (length(errs) > 0)
		return errors.validation_failed(ctx, errs);

	let reload = ucitrack.reload_services(conn, pkg);

	let result = transaction.transaction(conn, {
		package: pkg,
		reload_services: reload.services,
		fn: function(c, p) {
			let existing = load_section(c, p, id);
			if (!existing)
				return { ok: false, kind: "not_found",
				         message: sprintf("No section %s.%s", pkg, id) };
			// Sweep a stored `managed` left by a client from before raw stopped copying it.
			// Nothing else reaches it: NOT_OPTIONS keeps the key out of every body, so even
			// the removal idiom cannot target it, and until now only a full replace removed
			// it. An empty array is uci's "no such option".
			if (exists(existing, "managed")) c.uci_set(p, id, "managed", []);
			for (let k in w.opts) c.uci_set(p, id, k, w.opts[k]);
			return { ok: true, body: build_response_body(load_section(c, p, id), reload) };
		},
	});

	return translate_raw_tx(ctx, result);
}

function remove(conn, ctx, scopes, pkg, id) {
	let preview = load_section(conn, pkg, id);
	if (!preview)
		return errors.error(ctx, "not_found", sprintf("No section %s.%s", pkg, id));
	let sec_type = preview['.type'];
	let denied = require_raw_scope(ctx, scopes, pkg, sec_type, "rw",
		sprintf("deleting %s.%s via /raw/", pkg, id));
	if (denied != null) return denied;

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
	writable_options,
	TYPE_DOMAIN_MAP,
};
