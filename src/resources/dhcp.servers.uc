let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;
let as_list = values.as_list;
let fs = require('fs');

const LEASES4_PATH = "/tmp/dhcp.leases";
const LEASES6_PATHS = ["/tmp/hosts/odhcpd", "/tmp/odhcpd.leases"];

function read_file_or_empty(path) {
	let f = fs.open(path, "r");
	if (!f) return "";
	let c = f.read("all") ?? "";
	f.close();
	return c;
}

// Lightweight counters; deliberately not reusing dhcp.leases*.uc modules to
// avoid an inter-module loadfile dependency that breaks unit-test isolation.
// We don't surface the lease bodies here, just the counts.
//
// active_leases_v4 is a box-total: dnsmasq's /tmp/dhcp.leases does not reliably
// tag leases by serving interface, so per-interface counts are not available.
// active_leases_v6_iface is per-interface: odhcpd writes the interface name
// into each lease line and we filter on it. The asymmetry is named in the
// field set so a client comparing the two doesn't conflate them.
function count_v4_leases_total() {
	let n = 0;
	for (let line in split(read_file_or_empty(LEASES4_PATH), "\n")) {
		let t = trim(line);
		if (t == "" || substr(t, 0, 1) == "#") continue;
		// /tmp/dhcp.leases format: <expires> <mac> <ip> <hostname> [<duid>]
		let parts = split(t, " ");
		if (length(parts) < 4) continue;
		n++;
	}
	return n;
}

function count_v6_leases_for(iface) {
	let content = "";
	for (let p in LEASES6_PATHS) {
		content = read_file_or_empty(p);
		if (content != "") break;
	}
	let n = 0;
	for (let line in split(content, "\n")) {
		let t = trim(line);
		if (t == "" || substr(t, 0, 1) == "#") continue;
		// Split on whitespace (space OR tab) so trailing tabs don't shift columns.
		let parts = split(t, /[ \t]+/);
		if (length(parts) < 7) continue;
		if (parts[4] != iface) continue;
		// One v6 lease line can carry multiple addresses (slots 6..end).
		for (let i = 6; i < length(parts); i++)
			if (parts[i] != "" && parts[i] != "-") n++;
	}
	return n;
}

function lease_counts_for_interface(iface) {
	return {
		active_leases_v4_box_total:   count_v4_leases_total(),
		active_leases_v6_iface:   count_v6_leases_for(iface),
	};
}
const VALID_RA = {
	"disabled": true, "server": true, "relay": true, "hybrid": true,
};

function fromUci(section, conn) {
	let anonymous = !!section['.anonymous'];
	let iface = section.interface ?? null;
	let runtime = {};
	if (iface != null && iface != "") {
		try { runtime = lease_counts_for_interface(iface); }
		catch (e) { runtime = {}; }
	}
	return {
		id: section['.name'],
		managed: !anonymous,
		interface: iface,
		start: as_int(section.start),
		limit: as_int(section.limit),
		leasetime: section.leasetime ?? null,
		ignore: normalize_bool(section.ignore, false),
		force: normalize_bool(section.force, false),
		dynamicdhcp: normalize_bool(section.dynamicdhcp, true),
		ra: section.ra ?? null,
		dhcpv6: section.dhcpv6 ?? null,
		ra_default: as_int(section.ra_default),
		domain: section.domain ?? null,
		dhcp_option: as_list(section.dhcp_option),
		runtime: runtime,
	};
}

function toUci(json) {
	let out = {};
	if (json.interface != null)    out.interface = json.interface;
	if (json.start != null)        out.start = "" + json.start;
	if (json.limit != null)        out.limit = "" + json.limit;
	if (json.leasetime != null)    out.leasetime = json.leasetime;
	if (json.ignore != null)       out.ignore = json.ignore ? "1" : "0";
	if (json.force != null)        out.force = json.force ? "1" : "0";
	if (json.dynamicdhcp != null)  out.dynamicdhcp = json.dynamicdhcp ? "1" : "0";
	if (json.ra != null)           out.ra = json.ra;
	if (json.dhcpv6 != null)       out.dhcpv6 = json.dhcpv6;
	if (json.ra_default != null)   out.ra_default = "" + json.ra_default;
	if (json.domain != null)       out.domain = json.domain;
	if (type(json.dhcp_option) == "array" && length(json.dhcp_option) > 0)
		out.dhcp_option = json.dhcp_option;
	return out;
}

function validate(json, conn) {
	let errs = [];

	values.require_present(errs, json, "interface");

	if (json.ra != null && !VALID_RA[json.ra])
		push(errs, { field: "ra", code: "not_in_enum",
		             message: "must be disabled, server, relay, or hybrid" });
	if (json.dhcpv6 != null && !VALID_RA[json.dhcpv6])
		push(errs, { field: "dhcpv6", code: "not_in_enum",
		             message: "must be disabled, server, relay, or hybrid" });

	// Intentionally NOT verifying that json.interface names a real
	// network.interface section: stock OpenWrt ships `config dhcp wan`
	// referencing the `wan` interface, which on targets without a default WAN
	// port (e.g. x86 generic) is absent. dnsmasq tolerates dangling interface
	// refs (section is silently inactive until the interface appears), so
	// rejecting them would be stricter than the platform.

	return errs;
}

return {
	package: "dhcp",
	type: "dhcp",
	// reload via ucitrack on the dhcp package, which fans out to both dnsmasq
	// and odhcpd. Listing them here would double-reload.
	reload: ["dnsmasq"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "DHCP server",
	openapi_required: ["interface"],
	openapi_runtime: {
		type: "object",
		description: "Lease counters derived from /tmp/dhcp.leases (v4 box-total) and odhcpd statefile (v6 per-interface). Empty {} when no interface is bound.",
		properties: {
			active_leases_v4_box_total: { type: "integer", minimum: 0,
			                          description: "Total IPv4 leases box-wide; dnsmasq leases are not interface-tagged" },
			active_leases_v6_iface: { type: "integer", minimum: 0,
			                          description: "IPv6 leases issued on this section's interface" },
		},
	},
	schema_properties: {
		interface:   { type: "string" },
		start:       { type: "integer", minimum: 0, maximum: 254 },
		limit:       { type: "integer", minimum: 0, maximum: 254 },
		leasetime:   { type: ["string", "null"], pattern: "^[0-9]+[smhdwMY]?$" },
		ignore:      { type: "boolean", default: false },
		force:       { type: "boolean", default: false },
		dynamicdhcp: { type: "boolean", default: true },
		ra:          { type: "string", enum: keys(VALID_RA) },
		dhcpv6:      { type: "string", enum: keys(VALID_RA) },
		ra_default:  { type: ["integer", "null"], minimum: 0, maximum: 2,
		               description: "0 default, 1 deprecate prefix, 2 advertise as router" },
		domain:      { type: ["string", "null"] },
		dhcp_option: { type: "array", items: { type: "string" } },
	},
};
