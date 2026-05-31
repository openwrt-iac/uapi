function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		sysLocation: section.sysLocation ?? null,
		sysContact: section.sysContact ?? null,
		sysName: section.sysName ?? null,
		sysServices: section.sysServices ?? null,
		sysDescr: section.sysDescr ?? null,
		sysObjectID: section.sysObjectID ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.sysLocation != null) out.sysLocation = json.sysLocation;
	if (json.sysContact != null)  out.sysContact = json.sysContact;
	if (json.sysName != null)     out.sysName = json.sysName;
	if (json.sysServices != null) out.sysServices = "" + json.sysServices;
	if (json.sysDescr != null)    out.sysDescr = json.sysDescr;
	if (json.sysObjectID != null) out.sysObjectID = json.sysObjectID;
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
		sysLocation: { type: "string", description: "SNMPv2-MIB::sysLocation" },
		sysContact:  { type: "string", description: "SNMPv2-MIB::sysContact" },
		sysName:     { type: "string", description: "SNMPv2-MIB::sysName" },
		sysServices: { type: "integer", minimum: 0, maximum: 127,
		               description: "SNMPv2-MIB::sysServices bitfield" },
		sysDescr:    { type: "string", description: "SNMPv2-MIB::sysDescr" },
		sysObjectID: { type: "string", description: "SNMPv2-MIB::sysObjectID OID" },
	},
};
