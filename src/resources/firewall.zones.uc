const VALID_POLICIES = { "ACCEPT": true, "REJECT": true, "DROP": true };
const VALID_FAMILIES = { "any": true, "ipv4": true, "ipv6": true };
const NAME_RE = /^[a-zA-Z0-9_-]+$/;

function normalize_bool(v, default_val) {
	if (v == null) return default_val;
	if (v === true || v === "1" || v === "on" || v === "true" || v === "yes")
		return true;
	if (v === false || v === "0" || v === "off" || v === "false" || v === "no")
		return false;
	return default_val;
}

function as_list(v) {
	if (v == null) return [];
	if (type(v) == "array") return v;
	return [v];
}

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		input: section.input ?? "REJECT",
		output: section.output ?? "REJECT",
		forward: section.forward ?? "REJECT",
		network: as_list(section.network),
		masq: normalize_bool(section.masq, false),
		mtu_fix: normalize_bool(section.mtu_fix, false),
		family: section.family ?? "any",
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;
	if (json.input != null) out.input = json.input;
	if (json.output != null) out.output = json.output;
	if (json.forward != null) out.forward = json.forward;
	if (type(json.network) == "array" && length(json.network) > 0) out.network = json.network;
	if (json.masq != null) out.masq = json.masq ? "1" : "0";
	if (json.mtu_fix != null) out.mtu_fix = json.mtu_fix ? "1" : "0";
	if (json.family != null && json.family != "any") out.family = json.family;
	return out;
}

function validate(json) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type", message: "body must be a JSON object" });
		return errs;
	}

	if (json.name == null || json.name == "")
		push(errs, { field: "name", code: "required", message: "is required" });
	else if (!match(json.name, NAME_RE))
		push(errs, { field: "name", code: "invalid_format", message: "must be alphanumeric, _, or -" });

	for (let f in ["input", "output", "forward"]) {
		let v = json[f];
		if (v != null && !VALID_POLICIES[v])
			push(errs, { field: f, code: "not_in_enum",
			             message: "must be one of ACCEPT, REJECT, DROP" });
	}

	if (json.family != null && !VALID_FAMILIES[json.family])
		push(errs, { field: "family", code: "not_in_enum",
		             message: "must be one of any, ipv4, ipv6" });

	return errs;
}

return {
	package: "firewall",
	type: "zone",
	reload: ["firewall"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		input:   { type: "string", enum: keys(VALID_POLICIES) },
		output:  { type: "string", enum: keys(VALID_POLICIES) },
		forward: { type: "string", enum: keys(VALID_POLICIES) },
		family:  { type: "string", enum: keys(VALID_FAMILIES) },
		network: { type: "array", items: { type: "string" } },
	},
};
