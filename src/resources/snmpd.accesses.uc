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
	let found = false;
	conn.uci_foreach('snmpd', 'group', function(s) {
		if (s.group == name) { found = true; return false; }
	});
	return found;
}

function validate(json, conn) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	if (json.group == null || json.group == "")
		push(errs, { field: "group", code: "required", message: "is required" });
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
	schema_properties: {
		version: { type: "string", enum: keys(VALID_VERSIONS) },
		level: { type: "string", enum: keys(VALID_LEVELS) },
		prefix: { type: "string", enum: keys(VALID_PREFIXES) },
	},
};
