let fs = require('fs');
let values = require('values');
let wg = require('wg');
let shell_bool = values.shell_bool;
let config_get = values.config_get;
let as_list = values.as_list;
let is_valid_cidr_any = values.is_valid_cidr_any;
let is_valid_ip = values.is_valid_ip;
let as_int = values.as_int;

const WG_KEY_RE = regexp("^" + values.WG_KEY_PATTERN + "$");

function parent_from_type(t) {
	if (type(t) != "string" || substr(t, 0, 10) != "wireguard_") return null;
	return substr(t, 10);
}

function read_port(v) {
	return values.service_port(v, () => fs.readfile("/etc/services"));
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
		allowed_ips: wg.allowed_ips(section.allowed_ips),
		endpoint_host: config_get(section.endpoint_host) ?? null,
		endpoint_port: read_port(section.endpoint_port),
		persistent_keepalive: values.wg_keepalive(section.persistent_keepalive),
		route_allowed_ips: shell_bool(config_get(section.route_allowed_ips), false),
		disabled: shell_bool(config_get(section.disabled), false),
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
// at the next ifup, and so does a newline. It also brackets every host with a colon, so wg finds
// the port only after an IPv6 address, which can end in a %zone, and wg cuts the line at `#`. No
// regex syntax reads a bracket and a backslash in a character class the same way in ucode and in
// ECMAScript, so the request schema carries no pattern for this.
function endpoint_host_problems(host) {
	let out = [];
	if (index(host, "\\") >= 0 || index(host, "\n") >= 0)
		push(out, "must not contain a backslash or a newline: wireguard.sh expands escapes in the config that it gives wg");
	if (index(host, "#") >= 0)
		push(out, "must not contain #: wg reads the rest of the line as a comment, and then finds no port");
	let h = replace(host, /[[:space:]]/g, "");
	if (index(h, ":") >= 0 && !values.is_valid_ipv6(split(h, "%")[0]))
		push(out, "must hold a colon only in an IPv6 address, which can end in a %zone: wireguard.sh brackets every host with a colon, and wg cannot read another host in brackets");
	return out;
}

function validate(json, conn, id, delta) {
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
	// refused the bare form that `wg show` itself prints back. No allowed IP at all
	// is valid too: LuCI leaves the list optional, and wireguard.sh and wg take it.
	let aips = as_list(json.allowed_ips);
	// wg refuses the whole config for one entry that it cannot parse, and wireguard.sh leaves a
	// disabled peer out of that config, so a peer that stores such an entry can still be disabled.
	if (json.disabled === true)
		aips = as_list((delta ?? json).allowed_ips);
	for (let i = 0; i < length(aips); i++) {
		if (!is_valid_cidr_any(aips[i]) && !is_valid_ip(aips[i]))
			push(errs, { field: sprintf("allowed_ips[%d]", i), code: "invalid_format",
			             message: "must be an IPv4 or IPv6 address or CIDR" });
	}

	// toUci writes a 0 as "0", which wg takes as port 0, so a PUT of the read would turn a stored
	// port that wg cannot resolve into one that it takes. A stored 0 is the only port that a write
	// can send back as 0.
	let stored = (conn != null && id != null) ? conn.uci_get("network", id, "endpoint_port") : null;
	if ((delta ?? json).endpoint_port === 0 && read_port(stored) === 0
	    && !match(replace(stored, /[[:space:]]/g, ""), /^[+-]?0+$/))
		push(errs, { field: "endpoint_port", code: "conflict",
		             message: "must be from 1 to 65535: uci holds a port that does not resolve, which reads 0, and a write of 0 would replace it with port 0, which wg takes" });

	// The kernel apply gives wg an endpoint only with a port. A write that changes the host of an
	// enabled peer whose port reads 0 would leave the kernel on the old endpoint, and one that changes
	// the key sets the peer again, with no endpoint at all. Hosts compare as apply_peer reads them.
	let strip = (v) => replace(config_get(v) ?? "", /[[:space:]]/g, "");
	let host = strip(json.endpoint_host);
	if (json.endpoint_port === 0 && json.disabled !== true && host != "" && conn != null && id != null) {
		let old = conn.uci_get("network", id) ?? {};
		if (host != strip(old.endpoint_host) || wg.kernel_key(json.public_key) != wg.kernel_key(old.public_key))
			push(errs, { field: "endpoint_port", code: "out_of_range",
			             message: "must be from 1 to 65535 in a write that changes endpoint_host or public_key: the port reads 0, and the kernel apply gives wg an endpoint only with a port" });
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

// The rules on what wireguard.sh hands to wg through printf %b, and on values that wg or the routes
// of route_allowed_ips read in another way than the read, or cannot use. Another writer, such as
// LuCI, can enable the peer later, so an error is reported whether the peer is enabled or not, and
// marked `live: false` while wireguard.sh does not hand the value to wg: see new_errors() in the
// handler. network/interfaces runs these rules over the peers that a write of the interface makes
// live. The keys are checked here as well as by their schema pattern, because the schema sees only
// what a PATCH sends, and a stored key reaches the same printf %b.
function validate_new(json) {
	let errs = [];
	let enabled = json.disabled !== true;
	// wireguard.sh writes no [Peer] block for a peer without a key, and still adds its routes.
	let key = config_get(json.public_key);
	let live = enabled && type(key) == "string" && key != "";

	// wg reads a key without its whitespace and comment, and a newline adds a line to the config.
	// wireguard.sh expands a backslash, which only the kernel apply follows, for a stored key. A key
	// with one is refused here as it stands, so a request key costs no expansion under the lock.
	for (let k in [ "public_key", "preshared_key" ]) {
		let key = config_get(json[k]);
		if (type(key) == "string" && key != "" && (index(key, "\n") >= 0 || index(key, "\\") >= 0 || !match(values.wg_line(key), WG_KEY_RE)))
			push(errs, { field: k, code: "invalid_format", live,
			             message: "must be a WireGuard key as wg genkey prints it, on one line and without a backslash" });
	}

	// netifd and `ip route` read a prefix length in base 0 and wg in base 10, so `/010` routes /8 to
	// a peer that wg gives /10, and netifd installs no route for `/08`.
	let aips = as_list(json.allowed_ips);
	for (let i = 0; i < length(aips); i++)
		if (type(aips[i]) == "string" && match(aips[i], /\/0[0-9]+$/) && !match(aips[i], /\/0+[0-7]?$/))
			push(errs, { field: sprintf("allowed_ips[%d]", i), code: "invalid_format",
			             live: enabled && json.route_allowed_ips === true,
			             message: "must not start its prefix length with 0, unless the length is 0 to 7: the route of route_allowed_ips reads it as octal, and wg as decimal" });

	let host = config_get(json.endpoint_host);
	if (type(host) == "string")
		for (let message in endpoint_host_problems(host))
			push(errs, { field: "endpoint_host", code: "invalid_format", message, live });

	// The schema allows 0 and -1 because a read reports a port that /etc/services does not resolve
	// as 0, and a keepalive that wg refuses as -1. wireguard.sh writes the port only with a host.
	if (json.endpoint_port === 0)
		push(errs, { field: "endpoint_port", code: "out_of_range", live: live && type(host) == "string" && host != "",
		             message: "must be from 1 to 65535: wg cannot use port 0, which is also how a port name that /etc/services does not resolve reads" });
	if (json.persistent_keepalive === -1)
		push(errs, { field: "persistent_keepalive", code: "out_of_range", live,
		             message: "must be from 0 to 65535: -1 is how a stored value that wg cannot read reads, and wg cannot bring the interface up with it" });

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
	// access intact. The keys are compared as wg reads them, because a remove and a
	// set of the same peer cut its tunnel. A disabled peer is one netifd omits when
	// it builds the config, so it is removed rather than set.
	// `opts` is always toUci output, so its booleans are "1"/"0" and can be
	// compared literally. `existing` is a raw uci section and cannot.
	// `staged` is the section as the write leaves it in uci. The routes go to its words, which can
	// differ from the allowed IPs of the read that `opts` holds: a PATCH that leaves allowed_ips as
	// it is keeps an option with an escape, whose words wireguard.sh routes before printf %b.
	kernel_ops: function(kind, opts, sec_type, existing, staged) {
		let iface = parent_from_type(sec_type);
		if (iface == null || iface == "") return [];

		// route_allowed_ips routes outlive the peer, and the apply needs the previous
		// allowed_ips to know which prefixes this write may have orphaned. wireguard.sh installs
		// them from the words of the option, which it splits at a tab too.
		let prev_ips = (existing != null) ? (values.config_get_words(existing.allowed_ips) ?? []) : [];
		// `existing` is the raw uci section, so this needs the netifd-faithful read:
		// a section written by hand or by another tool can carry `true`, and reading
		// that as false tells the apply the old config installed no routes, so the
		// ones it did install are never withdrawn.
		let prev_routes = (existing != null) && shell_bool(config_get(existing.route_allowed_ips), false);

		if (kind == "remove") {
			if (existing?.public_key == null) return [];
			return [ { iface: iface, action: "remove", public_key: existing.public_key,
			           prev_allowed_ips: prev_ips, prev_route_allowed_ips: prev_routes } ];
		}

		let out = [];
		if (existing?.public_key != null && wg.kernel_key(existing.public_key) !== wg.kernel_key(opts.public_key))
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
			allowed_ips: wg.allowed_ips(opts.allowed_ips) ?? [],
			route_words: values.config_get_words(staged.allowed_ips) ?? [],
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
	read_runtime: (section, conn) => wg.runtime(conn, parent_from_type(section['.type']), section.public_key),
	toUci: toUci,
	validate: validate,
	validate_new: validate_new,
	openapi_singular: "wireguard peer",
	merge_for_patch: merge_for_patch,
	openapi_required: ["interface", "public_key"],
	openapi_read_required: ["allowed_ips"],
	openapi_runtime: {
		type: "object",
		description: "What the kernel holds for the peer, read-only. It is never part of the desired state or of a plan diff: it shows what the kernel holds beside the fields that uci holds, so that a client can report the difference, which a peer that `wg` changed by hand or a failed apply leaves. uapi compares nothing and corrects nothing. A GET reads it with one `wg show <interface> dump` for each interface of the peers that it reads. A write answers {} and reads no kernel state: read in a write, it would come from before the kernel apply, and `X-Kernel-Status` says whether the apply landed. A GET in a `/batch` that writes answers {} too, since it runs before the apply of the batch. Also {} when uapi did not read the kernel, because netifd does not report the interface up, wg fails, or wg prints a dump in a shape that uapi does not read, so that a failed read never looks like a missing peer. Also {} when the stored `public_key` gives wg more than a key through the escapes of printf %b, a second line or the end of the config, or holds a backslash and is longer than 512 bytes, which uapi does not expand: uapi then does not match the value to a peer of the kernel.",
		properties: {
			in_kernel:            { type: "boolean",
			                        description: "The kernel holds a peer under the key that wg reads from the stored `public_key`, which wireguard.sh gives wg through printf %b. false for a stored value that is not a key. The other fields are null when this is false. Two peers of an interface that store the same key share the one peer of the kernel, and both report it, a disabled one included." },
			endpoint:             { type: ["string", "null"],
			                        description: "The endpoint of the peer in the kernel, as an address and a port, such as `192.0.2.1:51820` or `[2001:db8::1]:51820`. wg resolves a host name when it sets the peer, and the kernel moves the endpoint to the address that an authenticated packet of the peer comes from, so this can differ from `endpoint_host` and `endpoint_port` with no write: a peer without `endpoint_host` reads the address that it last sent from. null when the kernel holds no endpoint for the peer." },
			allowed_ips:          { type: ["array", "null"], items: { type: "string" },
			                        description: "The allowed IPs of the peer in the kernel, in the form that the kernel prints: an address and a prefix length, with the host bits cleared and an IPv6 address in its short lower-case form, so a stored `10.0.0.2` reads `10.0.0.2/32`, `10.0.0.5/24` reads `10.0.0.0/24` and `FD00:0::1/64` reads `fd00::/64`. A write takes host bits and any IPv6 spelling, so a client compares the two in that form. Empty when the kernel holds none for the peer." },
			persistent_keepalive: { type: ["integer", "null"], minimum: 0, maximum: 65535,
			                        description: "The keepalive interval of the peer in the kernel, in seconds, 0 when it is off." },
			latest_handshake:     { type: ["integer", "null"], minimum: 0,
			                        description: "The time of the latest handshake with the peer, in seconds since the epoch, 0 when there was none." },
			rx_bytes:             { type: ["integer", "null"], minimum: 0,
			                        description: "Bytes that the kernel received from the peer since it added the peer." },
			tx_bytes:             { type: ["integer", "null"], minimum: 0,
			                        description: "Bytes that the kernel sent to the peer since it added the peer." },
		},
	},
	schema_properties: {
		interface:            { type: "string",
		                        description: "Parent WireGuard interface (network/interfaces name with proto=wireguard)" },
		description:          { type: ["string", "null"],
		                        description: "Human-readable label for this peer" },
		public_key:           { "x-uapi-read-nullable": true, type: "string", pattern: "^" + values.WG_KEY_PATTERN + "$",
		                        description: "WireGuard public key of the peer, as wg pubkey prints it" },
		preshared_key:        { type: "string", writeOnly: true, pattern: "^" + values.WG_KEY_PATTERN + "$",
		                        description: "Optional preshared key, as wg genpsk prints it. A write sets it, and a read does not show it." },
		has_preshared_key:    { type: "boolean", readOnly: true },
		allowed_ips:          { type: ["array", "null"], items: { type: "string" },
		                        description: "IPv4 or IPv6 addresses or CIDRs routed to this peer; a bare address means a single host. A read gives the entries as wg gets them: wireguard.sh joins a list with spaces, leaving out an empty entry, makes each space a comma, and expands the backslash escapes of printf %b, and wg cuts the line at a NUL byte and at `#` and splits it at commas. So `10.0.0.0/8\\054192.168.0.0/16` reads as two entries, and so does a comma, while two prefixes that a tab separates read as one entry, and a space at either end or next to another adds an empty entry, and wg refuses the config for either, so the interface does not come up. A value that the escapes would give a second line, the end of the config or a byte that is not printable ASCII, or that holds a backslash and is longer than 512 bytes, reads unexpanded. A value that wg reads as an empty line, such as one that starts with `#`, reads as one empty entry, because wireguard.sh still writes the line and wg refuses it. The routes of `route_allowed_ips` go to each word of the value as stored, before the escapes, with the address before the first `/` of the word and the length after its last, read as netifd reads it. Each entry that a write leaves on an enabled peer must be an address or CIDR, and a write that leaves the peer disabled checks only the entries that it sends." },
		endpoint_host:        { type: ["string", "null"],
		                        description: "Remote endpoint host name or IP address. An IPv6 address goes without brackets, because wireguard.sh brackets every host with a colon itself. A write that changes the host, or enables the peer, refuses a backslash, a newline, a `#`, and a colon outside an IPv6 address, which can end in a %zone" },
		endpoint_port:        { "x-uapi-read-nullable": true, type: "integer", minimum: 0, maximum: 65535, "x-uapi-write": { minimum: 1 },
		                        description: "Endpoint UDP port. A service name that uci stores, such as `https`, reads as its port from /etc/services, as wg resolves it. 0 reads when the name does not resolve, and then wg cannot bring the interface up. A write that changes the port to 0 answers 422, and so does a write that sends back the 0 of a name that does not resolve, because it would store port 0 in its place. A write that leaves a stored port as it is passes, unless it enables the peer, or changes the host or the key of an enabled peer, while the port reads 0." },
		persistent_keepalive: { "x-uapi-read-nullable": true, type: "integer", minimum: -1, maximum: 65535, "x-uapi-write": { minimum: 0 },
		                        description: "Seconds between keepalive packets. 0, a stored `off` or no value turns them off. -1 reads when wg cannot read the stored value, and then wg cannot bring the interface up. A write that changes the keepalive to -1 answers 422. A write that leaves such a stored value as it is passes, unless it enables the peer, and a PUT that sends the -1 back stores -1, which wg refuses as it refuses the stored value." },
		route_allowed_ips:    { type: "boolean", default: false,
		                        description: "Auto-install routes for allowed_ips" },
		disabled:             { type: "boolean", default: false,
		                        description: "Skip this peer when starting the tunnel" },
	},
};
