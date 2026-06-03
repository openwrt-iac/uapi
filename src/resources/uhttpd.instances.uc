let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;
let as_list = values.as_list;

const UAPI_PREFIX = "/api/v2=/usr/share/uapi/main.uc";

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
		max_requests: as_int(section.max_requests),
		max_connections: as_int(section.max_connections),
		script_timeout: as_int(section.script_timeout),
		network_timeout: as_int(section.network_timeout),
		http_keepalive: as_int(section.http_keepalive),
		tcp_keepalive: as_int(section.tcp_keepalive),
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

function validate(json, conn, id) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
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
		listen_http:     { type: "array", items: { type: "string", pattern: "^(\\[[0-9A-Fa-f:]+\\]|[0-9A-Fa-f:.]*):[0-9]+$" } },
		listen_https:    { type: "array", items: { type: "string", pattern: "^(\\[[0-9A-Fa-f:]+\\]|[0-9A-Fa-f:.]*):[0-9]+$" } },
		home:            { type: ["string", "null"],
		                   description: "Document root" },
		cert:            { type: ["string", "null"],
		                   description: "Path to TLS certificate file" },
		key:             { type: ["string", "null"],
		                   description: "Path to TLS key file" },
		cgi_prefix:      { type: ["string", "null"],
		                   description: "URL prefix served as CGI" },
		ucode_prefix:    { type: "array", items: { type: "string" } },
		lua_prefix:      { type: "array", items: { type: "string" } },
		index_page:      { type: "array", items: { type: "string" } },
		error_page:      { type: ["string", "null"],
		                   description: "Path served when a request 404s" },
		max_requests:    { type: "integer", minimum: 0 },
		max_connections: { type: "integer", minimum: 0 },
		script_timeout:  { type: "integer", minimum: 0 },
		network_timeout: { type: "integer", minimum: 0 },
		http_keepalive:  { type: "integer", minimum: 0 },
		tcp_keepalive:   { type: "integer", minimum: 0 },
		no_dirlists:     { type: "boolean",
		                   description: "Disable directory listings" },
		no_symlinks:     { type: "boolean",
		                   description: "Refuse to follow symlinks under home" },
		rfc1918_filter:  { type: "boolean",
		                   description: "Reject requests from RFC1918 ranges with non-RFC1918 host header" },
	},
};
