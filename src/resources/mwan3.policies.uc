let values = require('values');
let as_list = values.as_list;

const VALID_LAST_RESORT = {
	"default":     true,
	"unreachable": true,
	"blackhole":   true,
};

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		last_resort: section.last_resort ?? null,
		use_members: as_list(section.use_member),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.last_resort != null) out.last_resort = json.last_resort;
	if (json.use_members != null) out.use_member = json.use_members;
	return out;
}

function _load_member_names(conn) {
	return values.section_index(conn, "mwan3", "member", '.name');
}

function validate(json, conn) {
	let errs = [];
	if (type(json.use_members) != "array" || length(json.use_members) == 0) {
		push(errs, { field: "use_members", code: "required",
		             message: "must list at least one mwan3:members entry" });
	} else if (conn != null) {
		let known = _load_member_names(conn);
		for (let i = 0; i < length(json.use_members); i++) {
			let m = json.use_members[i];
			if (!known[m])
				push(errs, { field: sprintf("use_members[%d]", i), code: "conflict",
				             message: sprintf("no mwan3 member named %J", m) });
		}
	}
	return errs;
}

return {
	package: "mwan3",
	type: "policy",
	reload: ["mwan3"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "mwan3 policy",
	id_prefix: "p",
	openapi_required: ["use_members"],
	schema_properties: {
		last_resort: { type: ["string", "null"], enum: [...keys(VALID_LAST_RESORT), null],
		               description: "Fallback when no member is reachable." },
		use_members: { type: "array", items: { type: "string" },
		               description: "Member section names. Equal metric balances; lower metric is preferred." },
	},
};
