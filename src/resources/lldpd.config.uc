let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;
let as_list = values.as_list;

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		enable_cdp: normalize_bool(section.enable_cdp, false),
		enable_fdp: normalize_bool(section.enable_fdp, false),
		enable_sonmp: normalize_bool(section.enable_sonmp, false),
		enable_edp: normalize_bool(section.enable_edp, false),
		enable_lldpmed: normalize_bool(section.enable_lldpmed, false),
		lldp_class: as_int(section.lldp_class),
		lldp_description: normalize_bool(section.lldp_description, true),
		lldp_capabilities: normalize_bool(section.lldp_capabilities, true),
		lldp_mgmt_ip: section.lldp_mgmt_ip ?? null,
		interface: as_list(section.interface),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	let bool_fields = ["enable_cdp", "enable_fdp", "enable_sonmp", "enable_edp",
	                   "enable_lldpmed", "lldp_description", "lldp_capabilities"];
	for (let f in bool_fields) {
		if (json[f] != null) out[f] = json[f] ? "1" : "0";
	}
	if (json.lldp_class != null)   out.lldp_class = "" + json.lldp_class;
	if (json.lldp_mgmt_ip != null) out.lldp_mgmt_ip = json.lldp_mgmt_ip;
	if (type(json.interface) == "array" && length(json.interface) > 0)
		out.interface = json.interface;
	return out;
}

function validate(json) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
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
		enable_cdp:        { type: "boolean",
		                     description: "Emit Cisco Discovery Protocol frames" },
		enable_fdp:        { type: "boolean",
		                     description: "Emit Foundry Discovery Protocol frames" },
		enable_sonmp:      { type: "boolean",
		                     description: "Emit Nortel SONMP frames" },
		enable_edp:        { type: "boolean",
		                     description: "Emit Extreme Discovery Protocol frames" },
		enable_lldpmed:    { type: "boolean",
		                     description: "Emit LLDP-MED extensions" },
		lldp_class:        { type: "integer", minimum: 1, maximum: 4 },
		lldp_description:  { type: "boolean",
		                     description: "Advertise the system description TLV" },
		lldp_capabilities: { type: "boolean",
		                     description: "Advertise the system capabilities TLV" },
		lldp_mgmt_ip:      { type: ["string", "null"],
		                     description: "Management IP advertised in LLDP frames" },
		interface:         { type: "array", items: { type: "string" } },
	},
};
