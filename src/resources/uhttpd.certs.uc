function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		days: as_int(section.days),
		bits: as_int(section.bits),
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
	if (json.country != null)      out.country = uc("" + json.country);
	return out;
}

function validate(json) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	if (json.commonname == null || json.commonname == "")
		push(errs, { field: "commonname", code: "required",
		             message: "is required (cert CN)" });
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
	schema_properties: {
		days:         { type: "integer", minimum: 1, maximum: 36500,
		                description: "Certificate validity in days" },
		bits:         { type: "integer", minimum: 1024,
		                description: "RSA key size in bits" },
		commonname:   { type: "string", description: "X.509 CN (required)" },
		organization: { type: "string", description: "X.509 O" },
		location:     { type: "string", description: "X.509 L" },
		state:        { type: "string", description: "X.509 ST" },
		country:      { type: "string", pattern: "^[A-Za-z]{2}$",
		                description: "ISO 3166-1 alpha-2 country code (case-insensitive; normalized to uppercase on write)" },
	},
};
