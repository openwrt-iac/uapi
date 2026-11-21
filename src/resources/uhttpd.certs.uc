let values = require('values');
let as_int = values.as_int;

// px5g makes a certificate of 0 days, which has expired when it is made.
const WRITE = { days: { minimum: 1 } };

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

function validate(json, conn, id, delta, partial, stored) {
	let errs = [];
	values.write_bounds(errs, delta ?? json, WRITE, stored);
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
	openapi_singular: "uhttpd certificate",
	id_prefix: "c",
	openapi_required: ["commonname"],
	schema_properties: {
		days:         { "x-uapi-read-nullable": true, type: "integer", minimum: 0, maximum: 49710, "x-uapi-write": WRITE.days,
		                description: "Certificate validity in days. A write takes 1 to 49710: px5g makes a certificate that has already expired for 0, and wraps a larger number. A read also gives a stored 0" },
		bits:         { "x-uapi-read-nullable": true, type: "integer", minimum: 1024,
		                description: "RSA key size in bits" },
		commonname:   { "x-uapi-read-nullable": true, type: "string", description: "X.509 CN (required)" },
		organization: { "x-uapi-read-nullable": true, type: "string", description: "X.509 O" },
		location:     { "x-uapi-read-nullable": true, type: "string", description: "X.509 L" },
		state:        { "x-uapi-read-nullable": true, type: "string", description: "X.509 ST" },
		country:      { "x-uapi-read-nullable": true, type: "string", pattern: "^[A-Za-z]{2}$",
		                description: "ISO 3166-1 alpha-2 country code (case-insensitive; normalized to uppercase on write)" },
	},
};
