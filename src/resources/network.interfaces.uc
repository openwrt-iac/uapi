let values = require('values');
let ids = require('ids');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;
let is_valid_ipv4 = values.is_valid_ipv4;
let is_valid_cidr = values.is_valid_cidr;
let as_int = values.as_int;

const PKG = "network";

// Linux IFNAMSIZ-1 caps the wireguard netdev name at 15 chars (netifd uses
// the section name as the kernel netdev); hyphens are valid in ifnames but
// uci section names reject them, so they're not in the charset either.
const IFNAMSIZ_RE = /^[A-Za-z][A-Za-z0-9_]{0,14}$/;

const VALID_PROTOS = {
	"static": true, "dhcp": true, "dhcpv6": true, "pppoe": true,
	"none": true, "ppp": true, "wwan": true, "wireguard": true,
};
const WG_KEY_RE = /^[A-Za-z0-9+/]{43}=$/;
const VALID_REQADDRESS = { "try": true, "force": true, "none": true };
const IPV6_PREFIX_RE = /^[0-9A-Fa-f:]+\/[0-9]+$/;
const IPV6_IFACEID_RE = /^[0-9A-Fa-f:]+$/;

function fetch_runtime(conn, name) {
	if (conn == null || type(name) != "string" || name == "")
		return {};
	let status = null;
	try { status = conn.call("network.interface." + name, "status"); }
	catch (e) { return {}; }
	if (status == null) return {};
	// ubus emits hyphenated keys (ipv4-address, ipv6-address, ipv6-prefix).
	// Hyphenated identifiers are the only ones in our API surface that need
	// quoting in HCL/Go field tags; remap to snake_case to match the rest.
	return {
		up: !!status.up,
		pending: !!status.pending,
		available: !!status.available,
		// What netifd is actually running, which is not always what uci asks
		// for. netifd registers protocol handlers by scanning
		// /lib/netifd/proto at startup and caches the result: a reload does not
		// rescan, only a restart does. So a protocol whose package is absent, or
		// was installed after netifd started, is silently discarded and reported
		// as "none" while uci still holds the requested value. Comparing this
		// against `proto` is the only way to see that from outside.
		effective_proto: status.proto ?? null,
		l3_device: status.l3_device ?? null,
		uptime: status.uptime ?? null,
		ipv4_address: status["ipv4-address"] ?? [],
		ipv6_address: status["ipv6-address"] ?? [],
		ipv6_prefix:  status["ipv6-prefix"]  ?? [],
		route: status.route ?? [],
	};
}

function fromUci(section, conn) {
	let anonymous = !!section['.anonymous'];
	let proto = section.proto ?? "none";
	// Modern OpenWrt (25+) writes `list ipaddr` for multi-address static
	// interfaces (e.g. loopback ships as `list ipaddr '127.0.0.1/8'`), while
	// older configs used `option ipaddr 'x.x.x.x'`. Surface BOTH forms:
	// `ipaddr` keeps the v1.0/v1.1 contract (a single string; the first entry
	// when uci has a list), and a new `ipaddrs` array holds the full set.
	let ipaddr_raw = section.ipaddr;
	let ipaddrs = (type(ipaddr_raw) == "array") ? ipaddr_raw
	              : (ipaddr_raw != null && ipaddr_raw != "") ? [ipaddr_raw] : [];
	let ipaddr_first = length(ipaddrs) > 0 ? ipaddrs[0] : null;
	let view = {
		id: section['.name'],
		managed: !anonymous,
		device: section.device ?? null,
		proto: proto,
		ipaddr: ipaddr_first,
		ipaddrs: ipaddrs,
		netmask: section.netmask ?? null,
		gateway: section.gateway ?? null,
		dns: as_list(section.dns),
		ip6assign: as_int(section.ip6assign),
		mtu: as_int(section.mtu),
		auto: normalize_bool(section.auto, true),
		runtime: fetch_runtime(conn, section['.name']),
	};
	if (proto == "wireguard") {
		view.listen_port = as_int(section.listen_port);
		view.addresses = as_list(section.addresses);
		view.nohostroute = normalize_bool(section.nohostroute, false);
		view.ip4table = section.ip4table ?? null;
		view.ip6table = section.ip6table ?? null;
		view.has_private_key = (section.private_key != null && section.private_key != "");
	}
	// For the v1.2 dhcp / dhcpv6 fields, surface null when uci has nothing
	// explicitly set. Surfacing the daemon's effective default would have the
	// patch merge write those defaults into uci on the next PATCH, silently
	// changing the section's surface area for the client.
	if (proto == "dhcp") {
		view.peerdns = (section.peerdns != null) ? normalize_bool(section.peerdns, true) : null;
		view.defaultroute = (section.defaultroute != null) ? normalize_bool(section.defaultroute, true) : null;
		view.metric = as_int(section.metric);
		view.hostname = section.hostname ?? null;
		view.clientid = section.clientid ?? null;
	}
	if (proto == "dhcpv6") {
		view.peerdns = (section.peerdns != null) ? normalize_bool(section.peerdns, true) : null;
		view.reqprefix = section.reqprefix ?? null;
		view.reqaddress = section.reqaddress ?? null;
		view.ip6hint = section.ip6hint ?? null;
		view.ip6ifaceid = section.ip6ifaceid ?? null;
		view.delegate = (section.delegate != null) ? normalize_bool(section.delegate, true) : null;
	}
	return view;
}

function toUci(json) {
	let out = {};
	if (json.device != null) out.device = json.device;
	if (json.proto != null) out.proto = json.proto;
	// Prefer ipaddrs (list form) when present; fall back to ipaddr (string).
	// uci handles both `option ipaddr` and `list ipaddr` semantically; the
	// list form is required for multi-address static interfaces.
	if (type(json.ipaddrs) == "array" && length(json.ipaddrs) > 0)
		out.ipaddr = json.ipaddrs;
	else if (json.ipaddr != null)
		out.ipaddr = json.ipaddr;
	if (json.netmask != null) out.netmask = json.netmask;
	if (json.gateway != null) out.gateway = json.gateway;
	if (type(json.dns) == "array" && length(json.dns) > 0) out.dns = json.dns;
	if (json.ip6assign != null) out.ip6assign = "" + json.ip6assign;
	if (json.mtu != null) out.mtu = "" + json.mtu;
	if (json.auto != null) out.auto = json.auto ? "1" : "0";
	if (json.proto == "wireguard") {
		if (json.private_key != null) out.private_key = json.private_key;
		if (json.listen_port != null) out.listen_port = "" + json.listen_port;
		if (type(json.addresses) == "array" && length(json.addresses) > 0)
			out.addresses = json.addresses;
		if (json.nohostroute != null) out.nohostroute = json.nohostroute ? "1" : "0";
		if (json.ip4table != null) out.ip4table = "" + json.ip4table;
		if (json.ip6table != null) out.ip6table = "" + json.ip6table;
	}
	if (json.proto == "dhcp") {
		if (json.peerdns != null)      out.peerdns = json.peerdns ? "1" : "0";
		if (json.defaultroute != null) out.defaultroute = json.defaultroute ? "1" : "0";
		if (json.metric != null)       out.metric = "" + json.metric;
		if (json.hostname != null)     out.hostname = json.hostname;
		if (json.clientid != null)     out.clientid = json.clientid;
	}
	if (json.proto == "dhcpv6") {
		if (json.peerdns != null)    out.peerdns = json.peerdns ? "1" : "0";
		if (json.reqprefix != null)  out.reqprefix = "" + json.reqprefix;
		if (json.reqaddress != null) out.reqaddress = json.reqaddress;
		if (json.ip6hint != null)    out.ip6hint = json.ip6hint;
		if (json.ip6ifaceid != null) out.ip6ifaceid = json.ip6ifaceid;
		if (json.delegate != null)   out.delegate = json.delegate ? "1" : "0";
	}
	return out;
}

// The default merge folds the read view into the body, so a PATCH naming only
// `ipaddr` arrived carrying the `ipaddrs` that had just been read, and toUci
// preferred that list: the patch answered 200 and changed nothing. Whichever of
// the two the caller actually named wins, and the other is dropped rather than
// resurrected from the server's own read.
function merge_for_patch(existing_section, existing_json, body) {
	let merged = { ...existing_json };
	for (let k in body) {
		if (type(merged[k]) == "object" && type(body[k]) == "object")
			merged[k] = { ...merged[k], ...body[k] };
		else
			merged[k] = body[k];
	}
	let sent_scalar = exists(body, "ipaddr");
	let sent_list = exists(body, "ipaddrs");
	if (sent_scalar && !sent_list) delete merged.ipaddrs;
	else if (sent_list && !sent_scalar) delete merged.ipaddr;
	return merged;
}

// A full-replace caller cannot avoid sending both names disagreeing. fromUci
// mirrors the first list entry into `ipaddr`, so the scalar is in the caller's
// state even when its own config named only `ipaddrs`, and a PUT carries every
// field it knows. Refusing that body made `ipaddrs` unchangeable through any
// full-replace client. The list is the documented winner and toUci already
// prefers it, so resolve to it here instead. PATCH has `merge_for_patch` to
// express "did not name", and POST has no prior read to have carried a stale
// scalar back, so both keep the 422.
function resolve_for_replace(body) {
	if (type(body) != "object" || type(body.ipaddrs) != "array"
	    || length(body.ipaddrs) == 0 || body.ipaddr == null
	    || body.ipaddr == "" || body.ipaddr == body.ipaddrs[0])
		return body;

	let out = { ...body };
	delete out.ipaddr;
	return out;
}

function validate(json, conn, id) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type", message: "body must be a JSON object" });
		return errs;
	}

	// `ipaddr` and `ipaddrs` are two wire names for the same `list ipaddr`, and
	// toUci prefers the list whenever it is non-empty. A body carrying both, with
	// the scalar naming a different address, is a contradiction: half of it was
	// discarded and answered 200, so a caller re-reading saw its own write vanish
	// rather than fail. Agreement is still accepted, which is what a faithful
	// GET-then-PUT round trip sends.
	let ips = json.ipaddrs;
	if (type(ips) == "array" && length(ips) > 0
	    && json.ipaddr != null && json.ipaddr != "" && json.ipaddr != ips[0])
		push(errs, { field: "ipaddr", code: "conflict",
		             message: sprintf(
		               "conflicts with ipaddrs[0] (%J): both name the same uci option, so send one or the other",
		               ips[0]) });

	if (json.proto == null || json.proto == "")
		push(errs, { field: "proto", code: "required", message: "is required" });

	// Both `id` (the universal section-name input, since 2.2.0) and `name`
	// (the original 2.1.0 wireguard-era field) are accepted at create. If
	// both are supplied they must match. Charset / IFNAMSIZ-tightness is
	// enforced here for `name`; `id` goes through the framework's
	// validate_section_id which applies the broader uci section-name rules.
	// In-package uniqueness is checked by the framework for either path.
	let push_ifnamsiz_err = function(field, ctx) {
		push(errs, { field: field, code: "invalid_format",
		             message: sprintf("must match [A-Za-z][A-Za-z0-9_]{0,14} (%s)", ctx) });
	};
	if (json.name != null) {
		if (id != null)
			push(errs, { field: "name", code: "read_only",
			             message: "name can only be set at create time; rename via DELETE + POST" });
		else if (type(json.name) != "string" || !match(json.name, IFNAMSIZ_RE))
			push_ifnamsiz_err("name", "uci section name, IFNAMSIZ-tight");
		if (id == null && json.id != null && json.name != null && json.id != json.name)
			push(errs, { field: "name", code: "conflict",
			             message: sprintf("id (%J) and name (%J) must match when both are supplied",
			                              json.id, json.name) });
	}
	// Reject id at PATCH time (read-only post-create).
	if (id != null && json.id != null && json.id != id)
		push(errs, { field: "id", code: "read_only",
		             message: "id can only be set at create time; rename via DELETE + POST" });
	// For proto=wireguard, the IFNAMSIZ-tight cap is a kernel constraint:
	// netifd uses the uci section name as the netdev name and Linux's
	// IFNAMSIZ limits that to 15 chars. Tighten beyond the framework's
	// 32-char default when the caller supplied `id` directly on a
	// wireguard interface.
	if (id == null && json.id != null && json.proto == "wireguard"
	    && (type(json.id) != "string" || !match(json.id, IFNAMSIZ_RE)))
		push_ifnamsiz_err("id",
			"proto=wireguard binds the uci section name to the kernel netdev name; IFNAMSIZ caps it at 15 chars");

	if (json.proto == "static") {
		let has_list = type(json.ipaddrs) == "array" && length(json.ipaddrs) > 0;
		let has_single = json.ipaddr != null && json.ipaddr != "";
		if (!has_list && !has_single)
			push(errs, { field: "ipaddr", code: "required",
			             message: "is required when proto is static (use 'ipaddr' for a single address or 'ipaddrs' for a list)" });
		if (has_single && !is_valid_ipv4(json.ipaddr) && !is_valid_cidr(json.ipaddr))
			push(errs, { field: "ipaddr", code: "invalid_format",
			             message: "must be a valid IPv4 address or CIDR" });
		if (has_list) {
			for (let i = 0; i < length(json.ipaddrs); i++) {
				if (!is_valid_ipv4(json.ipaddrs[i]) && !is_valid_cidr(json.ipaddrs[i]))
					push(errs, { field: sprintf("ipaddrs[%d]", i), code: "invalid_format",
					             message: "must be a valid IPv4 address or CIDR" });
			}
		}
		if (json.netmask != null && json.netmask != "" && !is_valid_ipv4(json.netmask))
			push(errs, { field: "netmask", code: "invalid_format",
			             message: "must be a valid IPv4 netmask" });
	}

	if (json.proto == "wireguard") {
		if (json.private_key == null || json.private_key == "")
			push(errs, { field: "private_key", code: "required",
			             message: "is required when proto is wireguard" });
		else if (!match(json.private_key, WG_KEY_RE))
			push(errs, { field: "private_key", code: "invalid_format",
			             message: "must be a 44-char base64 WireGuard private key" });
		let addrs = as_list(json.addresses);
		if (length(addrs) == 0)
			push(errs, { field: "addresses", code: "required",
			             message: "is required when proto is wireguard (list of CIDRs)" });
		for (let i = 0; i < length(addrs); i++) {
			if (!is_valid_cidr(addrs[i]))
				push(errs, { field: sprintf("addresses[%d]", i), code: "invalid_format",
				             message: "must be a valid IPv4 CIDR" });
		}
	}

	let dns = as_list(json.dns);
	for (let i = 0; i < length(dns); i++) {
		if (!is_valid_ipv4(dns[i]) && type(dns[i]) != "string")
			push(errs, { field: sprintf("dns[%d]", i), code: "invalid_format",
			             message: "must be an IP address" });
	}

	if (json.proto == "dhcpv6") {
		if (json.ip6hint != null && json.ip6hint != ""
		    && !match(json.ip6hint, IPV6_PREFIX_RE))
			push(errs, { field: "ip6hint", code: "invalid_format",
			             message: "must be an IPv6 prefix like 2001:db8::/56" });
		if (json.ip6ifaceid != null && json.ip6ifaceid != ""
		    && !match(json.ip6ifaceid, IPV6_IFACEID_RE))
			push(errs, { field: "ip6ifaceid", code: "invalid_format",
			             message: "must be an IPv6 host id like ::1 or eui64-form" });
	}

	return errs;
}

return {
	package: PKG,
	type: "interface",
	reload: ["network"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	merge_for_patch: merge_for_patch,
	resolve_for_replace: resolve_for_replace,
	// Caller-supplied name wins. proto=wireguard falls back to a 14-char
	// wg_<rand> (netifd's IFNAMSIZ constraint); other protos return null
	// so handler.create emits the standard 28-char ULID.
	id_for_create: function(body) {
		if (body == null) return null;
		if (body.name != null) return body.name;
		if (body.proto == "wireguard") return ids.new_id("wg", 11);
		return null;
	},
	openapi_singular: "network interface",
	openapi_required: ["proto"],
	openapi_conditional: [
		{ if:   { properties: { proto: { const: "static" } }, required: ["proto"] },
		  then: { anyOf: [
		            { required: ["ipaddr"] },
		            { required: ["ipaddrs"] },
		          ] } },
		// private_key is write-only; GET surfaces only has_private_key, so listing
		// it in `required` would make strict OpenAPI client codegen reject reads.
		// validate() enforces presence on create.
		{ if:   { properties: { proto: { const: "wireguard" } }, required: ["proto"] },
		  then: { required: ["addresses"] } },
	],
	openapi_runtime: {
		type: "object",
		description: "Populated from ubus network.interface.<name> status; empty {} when the interface has no runtime state.",
		properties: {
			up:               { type: "boolean" },
			pending:          { type: "boolean" },
			available:        { type: "boolean" },
			effective_proto:  { type: ["string", "null"],
			                    description: "The protocol netifd is actually running for this interface. Differs from the configured `proto` when no handler is registered for it, in which case netifd reports `none` and the interface is inert; a mismatch means the device needs the handler package and a networking restart." },
			l3_device:        { type: ["string", "null"] },
			uptime:           { type: ["integer", "null"], minimum: 0 },
			ipv4_address:     { type: "array", items: { type: "object" } },
			ipv6_address:     { type: "array", items: { type: "object" } },
			ipv6_prefix:      { type: "array", items: { type: "object" } },
			route:            { type: "array", items: { type: "object" } },
		},
	},
	schema_properties: {
		proto: { type: "string", enum: keys(VALID_PROTOS), default: "none",
		         description: "Interface protocol. Several values need a handler package on the device: wwan needs `wwan`, wireguard needs `wireguard-tools`, dhcpv6 needs `odhcp6c`, and ppp/pppoe need `ppp`. When the handler is missing the write still succeeds and the interface is inert; `runtime.effective_proto` is what reveals it" },
		name:      { type: "string", pattern: "^[A-Za-z][A-Za-z0-9_]{0,14}$",
		             deprecated: true,
		             description: "DEPRECATED in 2.2.0: use `id` instead (the universal section-name input across every resource). Both are accepted during the deprecation window; if both are supplied they must match. `name` is scheduled for removal in v3. See docs/deprecations.md." },
		id:        { type: "string", pattern: "^[A-Za-z][A-Za-z0-9_]{0,31}$",
		             description: "Create-time only; picks the uci section name (which becomes the uapi `id` field). When omitted, the server emits a 14-char `wg_<rand>` for proto=wireguard (fits Linux IFNAMSIZ for the kernel netdev) or a 28-char ULID otherwise. Useful for LuCI parity (`lan`, `wan`, `guest`) and readable cross-references. For proto=wireguard the value must additionally fit IFNAMSIZ (15 chars max)." },
		device:    { type: ["string", "null"],
		             description: "Physical or logical L2 device this interface binds to" },
		ipaddr:    { type: ["string", "null"],
		             description: "Static IPv4 address (single). Backward-compatible view of the first entry when uci has `list ipaddr`. The same uci option as `ipaddrs`, which wins on write when non-empty. On PUT a differing `ipaddr` is dropped in favour of the list, since a full-replace caller carries the mirrored scalar back whether or not it named it; POST and PATCH reject the pair instead, where naming both is a choice. DEPRECATED as a write input: send `ipaddrs`. Reads keep this field, which is why it is not flagged `deprecated`, but v3 makes it read-only. See docs/deprecations.md." },
		ipaddrs:   { type: "array", items: { type: "string" },
		             description: "Full IPv4 address list for static proto (uci `list ipaddr`). Preferred on write for multi-address interfaces, and takes precedence over `ipaddr`. On PUT that precedence is applied silently; on POST and PATCH a body carrying both with a differing `ipaddr` is rejected." },
		netmask:   { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv4 netmask (static proto)" },
		gateway:   { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv4 default gateway (static proto)" },
		dns:       { type: "array", items: { type: "string" } },
		ip6assign: { type: ["integer", "null"], minimum: 0, maximum: 128,
		             description: "Prefix length to assign downstream from a delegated prefix" },
		mtu:       { type: ["integer", "null"], minimum: 0, maximum: 65535 },
		auto:      { type: "boolean", default: true,
		             description: "Bring this interface up at boot" },
		addresses: { type: "array", items: { type: "string" } },
		private_key: { type: "string", writeOnly: true,
		               description: "WireGuard private key; accepted on write, masked on read" },
		has_private_key: { type: "boolean", readOnly: true },
		listen_port:  { type: "integer", minimum: 0, maximum: 65535 },
		nohostroute:  { type: "boolean",
		                description: "Suppress the implicit host-route for wireguard endpoint" },
		ip4table:     { type: ["string", "null"],
		                description: "Routing table to install WireGuard IPv4 routes into" },
		ip6table:     { type: ["string", "null"],
		                description: "Routing table to install WireGuard IPv6 routes into" },
		peerdns:      { type: "boolean",
		                description: "Accept DNS servers advertised by the upstream (dhcp/dhcpv6)" },
		defaultroute: { type: "boolean",
		                description: "Install the default route from DHCP (dhcp)" },
		metric:       { type: "integer", minimum: 0,
		                description: "Default-route metric (dhcp)" },
		hostname:     { type: "string",
		                description: "Client hostname sent in DHCPDISCOVER (dhcp)" },
		clientid:     { type: "string",
		                description: "DHCP client identifier (dhcp)" },
		reqprefix:    { type: "string", pattern: "^(auto|no|[0-9]+)$",
		                description: "DHCPv6 prefix-delegation request: auto, no, or numeric size" },
		reqaddress:   { type: "string", enum: keys(VALID_REQADDRESS),
		                description: "DHCPv6 IA_NA request mode (dhcpv6)" },
		ip6hint:      { type: "string",
		                description: "Preferred IPv6 prefix hint for PD (dhcpv6)" },
		ip6ifaceid:   { type: "string",
		                description: "Static IPv6 interface id for IA_NA (dhcpv6)" },
		delegate:     { type: "boolean",
		                description: "Accept prefix delegation downstream (dhcpv6)" },
	},
};
