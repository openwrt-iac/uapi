function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		days: section.days ?? null,
		bits: section.bits ?? null,
		commonname: section.commonname ?? null,
		organization: section.organization ?? null,
		location: section.location ?? null,
		state: section.state ?? null,
		country: section.country ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.days != null)         out.days = "" + json.days;
	if (json.bits != null)         out.bits = "" + json.bits;
	if (json.commonname != null)   out.commonname = json.commonname;
	if (json.organization != null) out.organization = json.organization;
	if (json.location != null)     out.location = json.location;
	if (json.state != null)        out.state = json.state;
	if (json.country != null)      out.country = json.country;
	return out;
}

function validate(json) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	if (json.bits != null) {
		let b = int(json.bits);
		if (b < 1024)
			push(errs, { field: "bits", code: "out_of_range",
			             message: "must be >= 1024" });
	}
	if (json.country != null && length(json.country) != 2)
		push(errs, { field: "country", code: "invalid_format",
		             message: "must be a 2-letter country code" });
	return errs;
}

return {
	package: "uhttpd",
	type: "cert",
	reload: ["uhttpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	id_prefix: "c",
	schema_properties: {},
};
