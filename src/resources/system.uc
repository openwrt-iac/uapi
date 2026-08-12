let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		hostname: section.hostname ?? null,
		description: section.description ?? null,
		notes: section.notes ?? null,
		timezone: section.timezone ?? null,
		zonename: section.zonename ?? null,
		log_size: as_int(section.log_size),
		log_ip: section.log_ip ?? null,
		log_proto: section.log_proto ?? null,
		log_remote: normalize_bool(section.log_remote, false),
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
	if (json.log_remote != null) out.log_remote = json.log_remote ? "1" : "0";
	if (json.urandom_seed != null) out.urandom_seed = json.urandom_seed;
	return out;
}

function validate(json) {
	let errs = [];

	return errs;
}

return {
	package: "system",
	type: "system",
	reload: ["system", "log"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		hostname:     { type: ["string", "null"], pattern: "^[a-zA-Z0-9_-]+(\\.[a-zA-Z0-9_-]+)*$",
		                description: "System hostname (alphanumerics, dashes, underscores, dots)" },
		description:  { type: ["string", "null"],
		                description: "Free-form system description shown in LuCI" },
		notes:        { type: ["string", "null"],
		                description: "Operator-facing notes" },
		timezone:     { type: ["string", "null"],
		                description: "POSIX TZ string (e.g. CET-1CEST,M3.5.0,M10.5.0/3)" },
		zonename:     { type: ["string", "null"],
		                description: "IANA zone name (e.g. Europe/Paris)" },
		log_size:     { "x-uapi-read-nullable": true, type: "integer", minimum: 0 },
		log_ip:       { type: ["string", "null"],
		                description: "Remote syslog collector IP address" },
		log_proto:    { type: ["string", "null"],
		                description: "Remote syslog transport (udp or tcp)" },
		log_remote:   { type: "boolean", default: false },
		// A path, not a flag: /sbin/urandom_seed tests `[ "${SEED:0:1}" = "/" ]` and
		// saves the seed there. It was typed boolean, so any write put "1" or "0" in
		// place of the operator's path and silently turned the feature off.
		urandom_seed: { type: ["string", "null"],
		                description: "Path the entropy seed is saved to and restored from" },
	},
};
