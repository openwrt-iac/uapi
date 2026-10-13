let fs = require('fs');
let values = require('values');
let is_valid_ipv4 = values.is_valid_ipv4;
let is_valid_cidr = values.is_valid_cidr;
let netifd_int = values.netifd_int;
let rt_table_id = values.rt_table_id;
let platform_bool = values.platform_bool;

const VALID_TYPES = {
	"unicast": true, "blackhole": true, "unreachable": true,
	"prohibit": true, "throw": true, "anycast": true,
	"multicast": true, "local": true, "broadcast": true,
};

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		interface: section.interface ?? null,
		target: section.target ?? null,
		netmask: section.netmask ?? null,
		gateway: section.gateway ?? null,
		table: rt_table_id(section.table, () => fs.readfile("/etc/iproute2/rt_tables")),
		metric: netifd_int(section.metric),
		mtu: netifd_int(section.mtu),
		source: section.source ?? null,
		type: section.type ?? "unicast",
		// netifd omits a disabled section entirely, so without this a route that does not
		// exist on the box reads back as ordinary active config and a converged client sees
		// nothing to apply. platform_bool rather than shell_bool: measured on 25.12.5,
		// netifd honours `1` and `true` and ignores `on`/`yes`/`enabled`, so the wider
		// helper would report a section disabled that netifd is still installing.
		disabled: platform_bool(section.disabled, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.interface != null) out.interface = json.interface;
	if (json.target != null)    out.target = json.target;
	if (json.netmask != null)   out.netmask = json.netmask;
	if (json.gateway != null)   out.gateway = json.gateway;
	if (json.table != null)     out.table = "" + json.table;
	if (json.metric != null)    out.metric = "" + json.metric;
	if (json.mtu != null)       out.mtu = "" + json.mtu;
	if (json.source != null)    out.source = json.source;
	if (json.type != null && json.type != "unicast") out.type = json.type;
	if (json.disabled != null)  out.disabled = json.disabled ? "1" : "0";
	return out;
}

function validate(json, conn) {
	let errs = [];

	if (values.require_present(errs, json, "target")
	    && !is_valid_ipv4(json.target) && !is_valid_cidr(json.target))
		push(errs, { field: "target", code: "invalid_format",
		             message: "must be a valid IPv4 address or CIDR" });

	if (json.gateway != null && json.gateway != "" && !is_valid_ipv4(json.gateway))
		push(errs, { field: "gateway", code: "invalid_format",
		             message: "must be a valid IPv4 address" });

	if (json.netmask != null && json.netmask != "" && !is_valid_ipv4(json.netmask))
		push(errs, { field: "netmask", code: "invalid_format",
		             message: "must be a valid IPv4 netmask" });

	if (json.source != null && json.source != ""
	    && !is_valid_ipv4(json.source) && !is_valid_cidr(json.source))
		push(errs, { field: "source", code: "invalid_format",
		             message: "must be a valid IPv4 address or CIDR" });

	// The schema allows 0 because a read reports a table that netifd cannot resolve as 0.
	if (json.table === 0)
		push(errs, { field: "table", code: "out_of_range",
		             message: "must be from 1 to 4294967295: netifd drops a route whose table is 0, or a name it cannot resolve, which reads as 0" });

	let needs_iface = (json.type == null || json.type == "unicast");
	if (conn != null && needs_iface && json.interface != null && json.interface != "") {
		if (values.section_index(conn, 'network', 'interface', '.name')[json.interface] == null)
			push(errs, { field: "interface", code: "conflict",
			             message: sprintf("interface %J does not exist", json.interface) });
	}

	return errs;
}

return {
	package: "network",
	type: "route",
	reload: ["network"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "network route",
	openapi_required: ["target"],
	schema_properties: {
		type:      { type: "string", enum: keys(VALID_TYPES), default: "unicast" },
		interface: { type: ["string", "null"],
		             description: "Parent network interface name" },
		target:    { "x-uapi-read-nullable": true, type: "string",
		             description: "Destination IPv4 address or CIDR" },
		netmask:   { type: ["string", "null"],
		             description: "IPv4 netmask if target is an address (not CIDR)" },
		gateway:   { type: ["string", "null"],
		             description: "IPv4 next-hop address" },
		table:     { type: ["integer", "null"], minimum: 0, maximum: 4294967295,
		             description: "Routing table id. A name that uci stores reads as its id: 253 default, 254 main, 255 local, or the id in /etc/iproute2/rt_tables. 0 reads when netifd cannot resolve the stored table, and netifd then drops the route; a write of 0 answers 422." },
		metric:    { "x-uapi-read-nullable": true, type: "integer", minimum: 0 },
		mtu:       { "x-uapi-read-nullable": true, type: "integer", minimum: 0 },
		source:    { type: ["string", "null"],
		             description: "Preferred source address (IPv4 or CIDR)" },
		disabled:  { type: "boolean", default: false,
		             description: "Whether netifd skips this route. A disabled route is not installed at all, so it is absent from `ip route`." },
	},
};
