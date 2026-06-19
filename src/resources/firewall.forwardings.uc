let values = require('values');
let normalize_bool = values.normalize_bool;

const VALID_FAMILIES = { "any": true, "ipv4": true, "ipv6": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		src: section.src ?? null,
		dest: section.dest ?? null,
		family: section.family ?? "any",
		enabled: normalize_bool(section.enabled, true),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.src != null) out.src = json.src;
	if (json.dest != null) out.dest = json.dest;
	if (json.family != null && json.family != "any") out.family = json.family;
	if (json.enabled != null) out.enabled = json.enabled ? "1" : "0";
	return out;
}

function load_zones(conn) {
	let zones = {};
	conn.uci_foreach('firewall', 'zone', function(s) {
		if (s.name) zones[s.name] = true;
	});
	return zones;
}

function validate(json, conn) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}

	if (json.src == null || json.src == "")
		push(errs, { field: "src", code: "required", message: "is required" });

	if (json.dest == null || json.dest == "")
		push(errs, { field: "dest", code: "required", message: "is required" });

	if (conn != null) {
		let zones = null;
		if (json.src != null && json.src != "") {
			zones = load_zones(conn);
			if (!zones[json.src])
				push(errs, { field: "src", code: "conflict",
				             message: sprintf("zone %J does not exist", json.src) });
		}
		if (json.dest != null && json.dest != "") {
			if (zones == null) zones = load_zones(conn);
			if (!zones[json.dest])
				push(errs, { field: "dest", code: "conflict",
				             message: sprintf("zone %J does not exist", json.dest) });
		}
	}

	return errs;
}

return {
	package: "firewall",
	type: "forwarding",
	reload: ["firewall"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "firewall forwarding",
	openapi_required: ["src", "dest"],
	schema_properties: {
		src:     { type: "string", description: "Source zone name" },
		dest:    { type: "string", description: "Destination zone name" },
		family:  { type: "string", enum: keys(VALID_FAMILIES), default: "any" },
		enabled: { type: "boolean", default: true },
	},
};
