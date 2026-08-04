let values = require('values');

const VALID_VERSIONS = { "any": true, "v1": true, "v2c": true, "usm": true };
const VALID_LEVELS = { "noauth": true, "auth": true, "priv": true };
const VALID_PREFIXES = { "exact": true, "prefix": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		group: section.group ?? null,
		context: section.context ?? null,
		version: section.version ?? null,
		level: section.level ?? null,
		prefix: section.prefix ?? null,
		read: section.read ?? null,
		write: section.write ?? null,
		notify: section.notify ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.group != null)   out.group = json.group;
	if (json.context != null) out.context = json.context;
	if (json.version != null) out.version = json.version;
	if (json.level != null)   out.level = json.level;
	if (json.prefix != null)  out.prefix = json.prefix;
	if (json.read != null)    out.read = json.read;
	if (json.write != null)   out.write = json.write;
	if (json.notify != null)  out.notify = json.notify;
	return out;
}

function group_exists(conn, name) {
	return values.section_index(conn, 'snmpd', 'group', 'group')[name] != null;
}

function validate(json, conn) {
	let errs = [];
	values.require_present(errs, json, "group");
	if (conn != null && json.group != null && json.group != "") {
		if (!group_exists(conn, json.group))
			push(errs, { field: "group", code: "conflict",
			             message: sprintf("no snmpd group named %J exists", json.group) });
	}
	return errs;
}

return {
	package: "snmpd",
	type: "access",
	reload: ["snmpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "SNMP access ACL",
	openapi_required: ["group"],
	schema_properties: {
		group:   { type: "string",
		           description: "snmpd group this access entry binds to (must exist in snmpd/groups)" },
		context: { type: ["string", "null"],
		           description: "SNMPv3 context (usually empty)" },
		version: { type: "string", enum: keys(VALID_VERSIONS) },
		level:   { type: "string", enum: keys(VALID_LEVELS) },
		prefix:  { type: "string", enum: keys(VALID_PREFIXES) },
		read:    { type: ["string", "null"],
		           description: "View name granted for read access" },
		write:   { type: ["string", "null"],
		           description: "View name granted for write access" },
		notify:  { type: ["string", "null"],
		           description: "View name granted for notifications" },
	},
};
