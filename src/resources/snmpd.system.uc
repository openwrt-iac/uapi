let values = require('values');
let as_int = values.as_int;

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		sys_location:  section.sysLocation ?? null,
		sys_contact:   section.sysContact ?? null,
		sys_name:      section.sysName ?? null,
		// snmpd.init reads `sysService`, singular. uapi wrote the plural, which is
		// upstream's own typo in its sample config, so the value never reached snmpd.
		// The plural is still read as a fallback.
		sys_services:  as_int(section.sysService ?? section.sysServices),
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
	// See unbound.server.uc: clear the legacy key or the fallback read resurrects it.
	out.sysServices = [];
	if (json.sys_services != null)  out.sysService = "" + json.sys_services;
	if (json.sys_descr != null)     out.sysDescr = json.sys_descr;
	if (json.sys_object_id != null) out.sysObjectID = json.sys_object_id;
	return out;
}

function validate(json) {
	let errs = [];
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
		sys_location:  { "x-uapi-read-nullable": true, type: "string", description: "SNMPv2-MIB::sysLocation" },
		sys_contact:   { "x-uapi-read-nullable": true, type: "string", description: "SNMPv2-MIB::sysContact" },
		sys_name:      { "x-uapi-read-nullable": true, type: "string", description: "SNMPv2-MIB::sysName" },
		sys_services:  { "x-uapi-read-nullable": true, type: "integer", minimum: 0, maximum: 127,
		                 description: "SNMPv2-MIB::sysServices bitfield" },
		sys_descr:     { "x-uapi-read-nullable": true, type: "string", description: "SNMPv2-MIB::sysDescr" },
		sys_object_id: { "x-uapi-read-nullable": true, type: "string", description: "SNMPv2-MIB::sysObjectID OID" },
	},
};
