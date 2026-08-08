let values = require('values');
let shell_bool = values.shell_bool;
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;
let as_list = values.as_list;

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		enable_cdp: shell_bool(section.enable_cdp, false),
		enable_fdp: shell_bool(section.enable_fdp, false),
		enable_sonmp: shell_bool(section.enable_sonmp, false),
		enable_edp: shell_bool(section.enable_edp, false),
		enable_lldpmed: shell_bool(section.enable_lldpmed, false),
		lldp_class: as_int(section.lldp_class),
		lldp_description: section.lldp_description ?? null,
		// lldpd reads `lldp_capability_advertisements`; uapi wrote `lldp_capabilities`,
		// which the init never looks at, so this field has never done anything. The old
		// key is still read as a fallback, or an upgrade would silently drop the value an
		// operator set and report the default instead.
		lldp_capabilities: shell_bool(section.lldp_capability_advertisements
		                              ?? section.lldp_capabilities, true),
		lldp_mgmt_ip: section.lldp_mgmt_ip ?? null,
		interface: as_list(section.interface),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	let bool_fields = ["enable_cdp", "enable_fdp", "enable_sonmp", "enable_edp",
	                   "enable_lldpmed"];
	for (let f in bool_fields) {
		if (json[f] != null) out[f] = json[f] ? "1" : "0";
	}
	// See unbound.server.uc: the legacy key has to be cleared explicitly or a PATCH that
	// clears the field leaves it behind for the fallback read to resurrect.
	out.lldp_capabilities = [];
	if (json.lldp_capabilities != null)
		out.lldp_capability_advertisements = json.lldp_capabilities ? "1" : "0";
	if (json.lldp_description != null) out.lldp_description = json.lldp_description;
	if (json.lldp_class != null)   out.lldp_class = "" + json.lldp_class;
	if (json.lldp_mgmt_ip != null) out.lldp_mgmt_ip = json.lldp_mgmt_ip;
	if (type(json.interface) == "array" && length(json.interface) > 0)
		out.interface = json.interface;
	return out;
}

function validate(json) {
	let errs = [];
	return errs;
}

return {
	package: "lldpd",
	type: "lldpd",
	reload: ["lldpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		enable_cdp:        { type: "boolean", default: false,
		                     description: "Emit Cisco Discovery Protocol frames" },
		enable_fdp:        { type: "boolean", default: false,
		                     description: "Emit Foundry Discovery Protocol frames" },
		enable_sonmp:      { type: "boolean", default: false,
		                     description: "Emit Nortel SONMP frames" },
		enable_edp:        { type: "boolean", default: false,
		                     description: "Emit Extreme Discovery Protocol frames" },
		enable_lldpmed:    { type: "boolean", default: false,
		                     description: "Emit LLDP-MED extensions" },
		lldp_class:        { type: "integer", minimum: 1, maximum: 4 },
		// Free text, not a flag: lldpd.init reads it with config_get and emits it
		// verbatim as the system description. Typed boolean, a write replaced the
		// operator's string with "1".
		lldp_description:  { type: ["string", "null"],
		                     description: "System description advertised in LLDP frames" },
		lldp_capabilities: { type: "boolean", default: true,
		                     description: "Advertise the system capabilities TLV" },
		lldp_mgmt_ip:      { type: ["string", "null"],
		                     description: "Management IP advertised in LLDP frames" },
		interface:         { type: "array", items: { type: "string" } },
	},
};
