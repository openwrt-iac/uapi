let fs = require('fs');
let values = require('values');
let shell_bool = values.shell_bool;
let as_list = values.as_list;
let as_word_list_or_null = values.as_word_list_or_null;
let is_valid_cidr_any = values.is_valid_cidr_any;
let is_valid_ip = values.is_valid_ip;
let as_int = values.as_int;

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
		allowed_ips: as_word_list_or_null(section.allowed_ips),
		endpoint_host: section.endpoint_host ?? null,
		endpoint_port: values.service_port(section.endpoint_port, () => fs.readfile("/etc/services")),
		persistent_keepalive: values.wg_int(section.persistent_keepalive),
		route_allowed_ips: shell_bool(section.route_allowed_ips, false),
		disabled: shell_bool(section.disabled, false),
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
	return values.section_index(conn, 'network', 'interface', '.name',
	                            function(s) { return s.proto == "wireguard"; })[name] != null;
}

// wireguard.sh builds the config that it gives `wg syncconf` with `printf %b`, so a backslash in a
// value is an escape: `\n[Peer]` in plain text in endpoint_host added a peer that no read showed,
// at the next ifup, and so does a newline. It also brackets every host with a colon, so a bracketed
// IPv6 address reaches wg as `[[...]]`, and wg refuses the whole config. No regex syntax reads a
// bracket and a backslash in a character class the same way in ucode and in ECMAScript, so the
// request schema carries no pattern for this.
function endpoint_host_problem(host) {
	if (index(host, "\\") >= 0 || index(host, "\n") >= 0)
		return "must not contain a backslash or a newline: wireguard.sh expands escapes in the config that it gives wg";
	if (match(host, /[][]/))
		return "must not be in brackets: wireguard.sh brackets an IPv6 address itself, and wg refuses a doubled bracket";
	return null;
}

function validate(json, conn) {
	let errs = [];

	if (json.interface == null || json.interface == "")
		push(errs, { field: "interface", code: "required",
		             message: "is required (parent WireGuard interface name)" });

	if (json.public_key == null || json.public_key == "")
		push(errs, { field: "public_key", code: "required",
		             message: "is required" });

	// wg accepts an IPv4 or IPv6 prefix, or a bare address of either family which
	// it widens to /32 or /128. Requiring IPv4 CIDR rejected every IPv6 peer, so
	// a dual-stack tunnel could not be configured through the API at all, and
	// refused the bare form that `wg show` itself prints back.
	let aips = as_list(json.allowed_ips);
	if (length(aips) == 0)
		push(errs, { field: "allowed_ips", code: "required",
		             message: "must be a non-empty list of addresses or CIDRs" });
	for (let i = 0; i < length(aips); i++) {
		if (!is_valid_cidr_any(aips[i]) && !is_valid_ip(aips[i]))
			push(errs, { field: sprintf("allowed_ips[%d]", i), code: "invalid_format",
			             message: "must be an IPv4 or IPv6 address or CIDR" });
	}

	// The schema allows 0 because a read reports a port name that /etc/services does not resolve
	// as 0.
	if (json.endpoint_port === 0)
		push(errs, { field: "endpoint_port", code: "out_of_range",
		             message: "must be from 1 to 65535: wg cannot use port 0, which is also how a port name that /etc/services does not resolve reads" });

	if (conn != null && json.interface != null && json.interface != "") {
		if (!interface_exists_with_wg_proto(conn, json.interface))
			push(errs, { field: "interface", code: "conflict",
			             message: sprintf(
			               "no network interface %J with proto=wireguard exists",
			               json.interface) });
	}

	return errs;
}

const WG_KEY_RE = /^[A-Za-z0-9+\/]{43}=$/;

// The rules on what wireguard.sh hands to wg through printf %b, on the peer as if it were enabled.
// The handler refuses a write only for an error that it adds: see new_errors(). The keys are
// checked here as well as by their schema pattern, because the schema sees only what a PATCH
// sends, and a stored key reaches the same printf %b.
function validate_new(json) {
	let errs = [];

	// wireguard.sh reads a list option as its words joined by spaces.
	let read = (v) => (type(v) == "array") ? join(" ", v) : v;

	for (let k in [ "public_key", "preshared_key" ]) {
		let key = read(json[k]);
		if (type(key) == "string" && key != "" && !match(key, WG_KEY_RE))
			push(errs, { field: k, code: "invalid_format", message: "must be a WireGuard key: 43 base64 characters and =" });
	}

	let host = read(json.endpoint_host);
	if (type(host) == "string") {
		let problem = endpoint_host_problem(host);
		if (problem != null)
			push(errs, { field: "endpoint_host", code: "invalid_format", message: problem });
	}

	return errs;
}

function merge_for_patch(existing_json, body) {
	let merged = { ...existing_json };
	for (let k in body) {
		if (type(merged[k]) == "object" && type(body[k]) == "object")
			merged[k] = { ...merged[k], ...body[k] };
		else
			merged[k] = body[k];
	}
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
	// A peer edit leaves the parent `interface` section untouched, so a network
	// reload converges nothing and the peer never reaches the kernel. These are the
	// peer changes the transaction pushes there once the write is committed.
	//
	// Reads the uci options rather than the resource view because the view masks
	// preshared_key, and the parent interface off the section type because it is
	// not stored as an option. A rotated public key means the kernel still holds
	// the old peer under its old key, so the old one is removed first: without
	// that, a PUT that changes the key leaves the previous peer installed and its
	// access intact. A disabled peer is one netifd omits when it builds the
	// config, so it is removed rather than set.
	// `opts` is always toUci output, so its booleans are "1"/"0" and can be
	// compared literally. `existing` is a raw uci section and cannot.
	kernel_ops: function(kind, opts, sec_type, existing) {
		let iface = parent_from_type(sec_type);
		if (iface == null || iface == "") return [];

		// route_allowed_ips routes outlive the peer, and the apply needs the previous
		// allowed_ips to know which prefixes this write may have orphaned.
		let prev_ips = (existing != null) ? (as_word_list_or_null(existing.allowed_ips) ?? []) : [];
		// `existing` is the raw uci section, so this needs the netifd-faithful read:
		// a section written by hand or by another tool can carry `true`, and reading
		// that as false tells the apply the old config installed no routes, so the
		// ones it did install are never withdrawn.
		let prev_routes = (existing != null) && shell_bool(existing.route_allowed_ips, false);

		if (kind == "remove") {
			if (existing?.public_key == null) return [];
			return [ { iface: iface, action: "remove", public_key: existing.public_key,
			           prev_allowed_ips: prev_ips, prev_route_allowed_ips: prev_routes } ];
		}

		let out = [];
		if (existing?.public_key != null && existing.public_key != opts.public_key)
			push(out, { iface: iface, action: "remove", public_key: existing.public_key });

		if (opts.disabled == "1") {
			if (opts.public_key != null)
				push(out, { iface: iface, action: "remove", public_key: opts.public_key,
				            prev_allowed_ips: prev_ips, prev_route_allowed_ips: prev_routes });
			return out;
		}

		push(out, {
			iface: iface,
			action: "set",
			public_key: opts.public_key,
			allowed_ips: as_list(opts.allowed_ips),
			endpoint_host: opts.endpoint_host,
			endpoint_port: as_int(opts.endpoint_port),
			persistent_keepalive: as_int(opts.persistent_keepalive),
			preshared_key: opts.preshared_key,
			route_allowed_ips: opts.route_allowed_ips == "1",
			prev_allowed_ips: prev_ips,
			prev_route_allowed_ips: prev_routes,
		});
		return out;
	},
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	validate_new: validate_new,
	openapi_singular: "wireguard peer",
	merge_for_patch: merge_for_patch,
	openapi_required: ["interface", "public_key", "allowed_ips"],
	schema_properties: {
		interface:            { type: "string",
		                        description: "Parent WireGuard interface (network/interfaces name with proto=wireguard)" },
		description:          { type: ["string", "null"],
		                        description: "Human-readable label for this peer" },
		public_key:           { "x-uapi-read-nullable": true, type: "string", pattern: "^[A-Za-z0-9+/]{43}=$" },
		preshared_key:        { type: "string", writeOnly: true, pattern: "^[A-Za-z0-9+/]{43}=$",
		                        description: "Optional preshared key; accepted on write, masked on read" },
		has_preshared_key:    { type: "boolean", readOnly: true },
		allowed_ips:          { type: ["array", "null"], items: { type: "string" },
		                        description: "IPv4 or IPv6 addresses or CIDRs routed to this peer; a bare address means a single host" },
		endpoint_host:        { type: ["string", "null"],
		                        description: "Remote endpoint host name or IP address, without brackets, because wireguard.sh brackets an IPv6 address itself. A write refuses a backslash, a newline and brackets. A write that leaves the host as it is, and does not enable the peer, is not refused for a problem that it already had" },
		endpoint_port:        { "x-uapi-read-nullable": true, type: "integer", minimum: 0, maximum: 65535, "x-uapi-write": { minimum: 1 },
		                        description: "Endpoint UDP port. A service name that uci stores, such as `https`, reads as its port from /etc/services, as wg resolves it. 0 reads when the name does not resolve, and then wg cannot bring the interface up; a write of 0 answers 422." },
		persistent_keepalive: { "x-uapi-read-nullable": true, type: "integer", minimum: 0, maximum: 65535 },
		route_allowed_ips:    { type: "boolean", default: false,
		                        description: "Auto-install routes for allowed_ips" },
		disabled:             { type: "boolean", default: false,
		                        description: "Skip this peer when starting the tunnel" },
	},
};
