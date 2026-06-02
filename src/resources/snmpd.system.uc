function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		sys_location:  section.sysLocation ?? null,
		sys_contact:   section.sysContact ?? null,
		sys_name:      section.sysName ?? null,
		sys_services:  section.sysServices ?? null,
		sys_descr:     section.sysDescr ?? null,
		sys_object_id: section.sysObjectID ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.sys_location != null)  out.sysLocation = json.sys_location;
	if (json.sys_contact != null)   out.sysContact = json.sys_contact;
	if (json.sys_name != null)      out.sysName = json.sys_name;
	if (json.sys_services != null)  out.sysServices = "" + json.sys_services;
	if (json.sys_descr != null)     out.sysDescr = json.sys_descr;
	if (json.sys_object_id != null) out.sysObjectID = json.sys_object_id;
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
	package: "snmpd",
	type: "system",
	reload: ["snmpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		sys_location:  { type: "string", description: "SNMPv2-MIB::sysLocation" },
		sys_contact:   { type: "string", description: "SNMPv2-MIB::sysContact" },
		sys_name:      { type: "string", description: "SNMPv2-MIB::sysName" },
		sys_services:  { type: "integer", minimum: 0, maximum: 127,
		                 description: "SNMPv2-MIB::sysServices bitfield" },
		sys_descr:     { type: "string", description: "SNMPv2-MIB::sysDescr" },
		sys_object_id: { type: "string", description: "SNMPv2-MIB::sysObjectID OID" },
	},
};
