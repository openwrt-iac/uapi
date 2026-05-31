let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;

const UAPI_PREFIX = "/api/v1=/usr/share/uapi/main.uc";

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		listen_http: as_list(section.listen_http),
		listen_https: as_list(section.listen_https),
		home: section.home ?? null,
		cert: section.cert ?? null,
		key: section.key ?? null,
		cgi_prefix: section.cgi_prefix ?? null,
		lua_prefix: as_list(section.lua_prefix),
		ucode_prefix: as_list(section.ucode_prefix),
		max_requests: section.max_requests ?? null,
		max_connections: section.max_connections ?? null,
		script_timeout: section.script_timeout ?? null,
		network_timeout: section.network_timeout ?? null,
		http_keepalive: section.http_keepalive ?? null,
		tcp_keepalive: section.tcp_keepalive ?? null,
		index_page: as_list(section.index_page),
		error_page: section.error_page ?? null,
		no_dirlists: normalize_bool(section.no_dirlists, false),
		no_symlinks: normalize_bool(section.no_symlinks, false),
		rfc1918_filter: normalize_bool(section.rfc1918_filter, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	let pass_list = ["listen_http", "listen_https", "lua_prefix", "ucode_prefix", "index_page"];
	for (let k in pass_list) {
		if (type(json[k]) == "array" && length(json[k]) > 0)
			out[k] = json[k];
	}
	let pass_str = ["home", "cert", "key", "cgi_prefix", "error_page"];
	for (let k in pass_str) {
		if (json[k] != null) out[k] = json[k];
	}
	let pass_int = ["max_requests", "max_connections", "script_timeout",
	                "network_timeout", "http_keepalive", "tcp_keepalive"];
	for (let k in pass_int) {
		if (json[k] != null) out[k] = "" + json[k];
	}
	let pass_bool = ["no_dirlists", "no_symlinks", "rfc1918_filter"];
	for (let k in pass_bool) {
		if (json[k] != null) out[k] = json[k] ? "1" : "0";
	}
	return out;
}

function uapi_prefix_present(json) {
	let prefixes = as_list(json.ucode_prefix);
	for (let p in prefixes)
		if (p == UAPI_PREFIX) return true;
	return false;
}

const VALID_LISTEN_RE = /^(\[[0-9A-Fa-f:]+\]|[0-9A-Fa-f:.]*):[0-9]+$/;

function validate(json, conn, id) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}

	for (let f in ["listen_http", "listen_https"]) {
		let l = json[f];
		if (type(l) != "array") continue;
		for (let i = 0; i < length(l); i++) {
			if (type(l[i]) != "string" || !match(l[i], VALID_LISTEN_RE))
				push(errs, { field: sprintf("%s[%d]", f, i),
				             code: "invalid_format",
				             message: "must be <host>:<port>, e.g. 0.0.0.0:80 or [::]:443" });
		}
	}

	let int_fields = ["max_requests", "max_connections", "script_timeout",
	                  "network_timeout", "http_keepalive", "tcp_keepalive"];
	for (let f in int_fields) {
		if (json[f] == null) continue;
		let n = int(json[f]);
		if (n < 0)
			push(errs, { field: f, code: "out_of_range",
			             message: "must be non-negative" });
	}

	// Self-lockout protection: refuse a write to the 'main' instance that
	// would strip uapi's own ucode_prefix entry. Applies to PUT and PATCH
	// (id == 'main'); POST creates a new instance with a generated id and
	// cannot target main.
	if (id == "main" && !uapi_prefix_present(json))
		push(errs, { field: "ucode_prefix", code: "conflict",
		             message: sprintf(
		               "uhttpd 'main' instance must keep uapi's ucode_prefix entry %J; refusing the write to avoid self-lockout",
		               UAPI_PREFIX) });

	return errs;
}

function merge_for_patch(existing_section, existing_json, body) {
	let merged = { ...existing_json };
	for (let k in body) {
		if (type(merged[k]) == "object" && type(body[k]) == "object")
			merged[k] = { ...merged[k], ...body[k] };
		else
			merged[k] = body[k];
	}
	return merged;
}

return {
	package: "uhttpd",
	type: "uhttpd",
	reload: ["uhttpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	merge_for_patch: merge_for_patch,
	schema_properties: {
		listen_http:  { type: "array", items: { type: "string" } },
		listen_https: { type: "array", items: { type: "string" } },
		ucode_prefix: { type: "array", items: { type: "string" } },
		lua_prefix:   { type: "array", items: { type: "string" } },
		index_page:   { type: "array", items: { type: "string" } },
	},
};
