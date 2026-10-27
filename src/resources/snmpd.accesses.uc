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

function validate(json, conn) {
	let errs = [];
	values.require_present(errs, json, "group");
	if (conn != null && json.group != null && json.group != "") {
		if (values.section_index(conn, 'snmpd', 'group', 'group')[json.group] == null)
			push(errs, { field: "group", code: "conflict",
			             message: sprintf("no snmpd group named %J exists", json.group) });
	}
	return errs;
}

// snmpd.init skips an access that does not set each of these. It tests `context` unquoted, so an
// empty one passes the test and writes an access line with a word missing, which snmpd drops.
// LuCI leaves `context` optional and uapi required only `group`, so a stored access can lack one:
// see new_errors() in the handler.
function validate_new(json) {
	let errs = [];
	for (let f in [ "context", "version", "level", "prefix", "read", "write", "notify" ])
		if (json[f] == null || json[f] == "")
			push(errs, { field: f, code: "required",
			             message: (f == "context")
			                 ? "is required: snmpd drops an access without a context. Use \"none\" for the empty context"
			                 : "is required: snmpd.init skips an access without it" });
	return errs;
}

return {
	package: "snmpd",
	type: "access",
	reload: ["snmpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	validate_new: validate_new,
	openapi_singular: "SNMP access ACL",
	openapi_required: ["group"],
	schema_properties: {
		group:   { "x-uapi-read-nullable": true, type: "string", pattern: values.ONE_WORD_RE,
		           description: "snmpd group this access entry binds to (must exist in snmpd/groups)" },
		context: { type: ["string", "null"], pattern: values.SHELL_WORD_RE,
		           description: "SNMPv3 context. `none` is the empty context, which is the usual value: snmpd.init writes it as \"\"" },
		version: { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_VERSIONS) },
		level:   { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_LEVELS) },
		prefix:  { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_PREFIXES) },
		read:    { type: ["string", "null"], pattern: values.ONE_WORD_RE,
		           description: "View name granted for read access" },
		write:   { type: ["string", "null"], pattern: values.ONE_WORD_RE,
		           description: "View name granted for write access" },
		notify:  { type: ["string", "null"], pattern: values.ONE_WORD_RE,
		           description: "View name granted for notifications" },
	},
};
