const HOSTNAME_RE = /^[a-zA-Z0-9_-]+(\.[a-zA-Z0-9_-]+)*$/;

function fromUci(section) {
	return {
		hostname: section.hostname ?? null,
		description: section.description ?? null,
		notes: section.notes ?? null,
		timezone: section.timezone ?? null,
		zonename: section.zonename ?? null,
		log_size: section.log_size ?? null,
		log_ip: section.log_ip ?? null,
		log_proto: section.log_proto ?? null,
		log_remote: section.log_remote ?? null,
		urandom_seed: section.urandom_seed ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.hostname != null) out.hostname = json.hostname;
	if (json.description != null) out.description = json.description;
	if (json.notes != null) out.notes = json.notes;
	if (json.timezone != null) out.timezone = json.timezone;
	if (json.zonename != null) out.zonename = json.zonename;
	if (json.log_size != null) out.log_size = "" + json.log_size;
	if (json.log_ip != null) out.log_ip = json.log_ip;
	if (json.log_proto != null) out.log_proto = json.log_proto;
	if (json.log_remote != null) out.log_remote = json.log_remote;
	if (json.urandom_seed != null) out.urandom_seed = json.urandom_seed;
	return out;
}

function validate(json) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type", message: "body must be a JSON object" });
		return errs;
	}

	if (json.hostname != null && json.hostname != "" && !match(json.hostname, HOSTNAME_RE))
		push(errs, { field: "hostname", code: "invalid_format",
		             message: "must be a valid hostname (alphanumerics, dashes, underscores, dots)" });

	if (json.log_size != null) {
		let n = int(json.log_size);
		if (n < 0)
			push(errs, { field: "log_size", code: "out_of_range",
			             message: "must be a non-negative number" });
	}

	return errs;
}

return {
	package: "system",
	type: "system",
	reload: [],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
};
