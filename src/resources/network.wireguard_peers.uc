let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;
let is_valid_cidr = values.is_valid_cidr;
let as_int = values.as_int;

const WG_KEY_RE = /^[A-Za-z0-9+/]{43}=$/;

function parent_from_type(t) {
	if (type(t) != "string" || substr(t, 0, 10) != "wireguard_") return null;
	return substr(t, 10);
}

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	let parent = parent_from_type(section['.type']);
	return {
		id: section['.name'],
		managed: !anonymous,
		interface: parent,
		description: section.description ?? null,
		public_key: section.public_key ?? null,
		has_preshared_key: (section.preshared_key != null && section.preshared_key != ""),
		allowed_ips: as_list(section.allowed_ips),
		endpoint_host: section.endpoint_host ?? null,
		endpoint_port: as_int(section.endpoint_port),
		persistent_keepalive: as_int(section.persistent_keepalive),
		route_allowed_ips: normalize_bool(section.route_allowed_ips, false),
		disabled: normalize_bool(section.disabled, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.description != null)    out.description = json.description;
	if (json.public_key != null)     out.public_key = json.public_key;
	if (json.preshared_key != null)
		out.preshared_key = json.preshared_key;
	if (type(json.allowed_ips) == "array" && length(json.allowed_ips) > 0)
		out.allowed_ips = json.allowed_ips;
	if (json.endpoint_host != null)  out.endpoint_host = json.endpoint_host;
	if (json.endpoint_port != null)  out.endpoint_port = "" + json.endpoint_port;
	if (json.persistent_keepalive != null) out.persistent_keepalive = "" + json.persistent_keepalive;
	if (json.route_allowed_ips != null) out.route_allowed_ips = json.route_allowed_ips ? "1" : "0";
	if (json.disabled != null)       out.disabled = json.disabled ? "1" : "0";
	return out;
}

function interface_exists_with_wg_proto(conn, name) {
	let found = false;
	conn.uci_foreach('network', 'interface', function(s) {
		if (s['.name'] == name && s.proto == "wireguard") { found = true; return false; }
	});
	return found;
}

function validate(json, conn) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}

	if (json.interface == null || json.interface == "")
		push(errs, { field: "interface", code: "required",
		             message: "is required (parent WireGuard interface name)" });

	if (json.public_key == null || json.public_key == "")
		push(errs, { field: "public_key", code: "required",
		             message: "is required" });
	else if (!match(json.public_key, WG_KEY_RE))
		push(errs, { field: "public_key", code: "invalid_format",
		             message: "must be a 44-char base64 WireGuard public key" });

	if (json.preshared_key != null && json.preshared_key != ""
	    && !match(json.preshared_key, WG_KEY_RE))
		push(errs, { field: "preshared_key", code: "invalid_format",
		             message: "must be a 44-char base64 WireGuard preshared key" });

	let aips = as_list(json.allowed_ips);
	if (length(aips) == 0)
		push(errs, { field: "allowed_ips", code: "required",
		             message: "must be a non-empty list of CIDRs" });
	for (let i = 0; i < length(aips); i++) {
		if (!is_valid_cidr(aips[i]))
			push(errs, { field: sprintf("allowed_ips[%d]", i), code: "invalid_format",
			             message: "must be a valid IPv4 CIDR" });
	}

	if (conn != null && json.interface != null && json.interface != "") {
		if (!interface_exists_with_wg_proto(conn, json.interface))
			push(errs, { field: "interface", code: "conflict",
			             message: sprintf(
			               "no network interface %J with proto=wireguard exists",
			               json.interface) });
	}

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
	// Carry forward the preshared_key when PATCH omits it (it's masked in read).
	if (body.preshared_key == null && existing_section.preshared_key != null)
		merged.preshared_key = existing_section.preshared_key;
	delete merged.has_preshared_key;
	return merged;
}

return {
	package: "network",
	type: "wireguard_peer",          // sentinel; actual uci types are wireguard_<iface>
	type_predicate: function(t) {
		return type(t) == "string" && substr(t, 0, 10) == "wireguard_";
	},
	create_type: function(body) { return "wireguard_" + body.interface; },
	id_prefix: "g",
	reload: ["network"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	merge_for_patch: merge_for_patch,
	schema_properties: {
		interface:            { type: "string",
		                        description: "Parent WireGuard interface (network/interfaces name with proto=wireguard)" },
		description:          { type: ["string", "null"],
		                        description: "Human-readable label for this peer" },
		public_key:           { type: "string", pattern: "^[A-Za-z0-9+/]{43}=$" },
		preshared_key:        { type: "string", writeOnly: true, pattern: "^[A-Za-z0-9+/]{43}=$",
		                        description: "Optional preshared key; accepted on write, masked on read" },
		has_preshared_key:    { type: "boolean", readOnly: true },
		allowed_ips:          { type: "array", items: { type: "string" } },
		endpoint_host:        { type: ["string", "null"],
		                        description: "Remote endpoint hostname or IP" },
		endpoint_port:        { type: "integer", minimum: 1, maximum: 65535 },
		persistent_keepalive: { type: "integer", minimum: 0, maximum: 65535 },
		route_allowed_ips:    { type: "boolean",
		                        description: "Auto-install routes for allowed_ips" },
		disabled:             { type: "boolean",
		                        description: "Skip this peer when starting the tunnel" },
	},
};
