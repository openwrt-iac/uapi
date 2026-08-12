let values = require('values');
let shell_bool = values.shell_bool;
let as_int = values.as_int;
let as_list_or_null = values.as_list_or_null;

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		domain: section.domain ?? null,
		local: section.local ?? null,
		noresolv: shell_bool(section.noresolv, false),
		rebind_protection: shell_bool(section.rebind_protection, true),
		expandhosts: shell_bool(section.expandhosts, false),
		cachesize: as_int(section.cachesize),
		port: as_int(section.port),
		domainneeded: shell_bool(section.domainneeded, true),
		boguspriv: shell_bool(section.boguspriv, true),
		filterwin2k: shell_bool(section.filterwin2k, false),
		authoritative: shell_bool(section.authoritative, true),
		readethers: shell_bool(section.readethers, true),
		leasefile: section.leasefile ?? null,
		resolvfile: section.resolvfile ?? null,
		server: as_list_or_null(section.server),
		address: as_list_or_null(section.address),
		nonwildcard: shell_bool(section.nonwildcard, true),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.domain != null)              out.domain = json.domain;
	if (json.local != null)               out.local = json.local;
	if (json.noresolv != null)            out.noresolv = json.noresolv ? "1" : "0";
	if (json.rebind_protection != null)   out.rebind_protection = json.rebind_protection ? "1" : "0";
	if (json.expandhosts != null)         out.expandhosts = json.expandhosts ? "1" : "0";
	if (json.cachesize != null)           out.cachesize = "" + json.cachesize;
	if (json.port != null)                out.port = "" + json.port;
	if (json.domainneeded != null)        out.domainneeded = json.domainneeded ? "1" : "0";
	if (json.boguspriv != null)           out.boguspriv = json.boguspriv ? "1" : "0";
	if (json.filterwin2k != null)         out.filterwin2k = json.filterwin2k ? "1" : "0";
	if (json.authoritative != null)       out.authoritative = json.authoritative ? "1" : "0";
	if (json.readethers != null)          out.readethers = json.readethers ? "1" : "0";
	if (json.leasefile != null)           out.leasefile = json.leasefile;
	if (json.resolvfile != null)          out.resolvfile = json.resolvfile;
	if (type(json.server) == "array" && length(json.server) > 0)
		out.server = json.server;
	if (type(json.address) == "array" && length(json.address) > 0)
		out.address = json.address;
	if (json.nonwildcard != null)         out.nonwildcard = json.nonwildcard ? "1" : "0";
	return out;
}

function validate(json) {
	let errs = [];

	return errs;
}

return {
	package: "dhcp",
	type: "dnsmasq",
	reload: ["dnsmasq"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		domain:            { type: ["string", "null"] },
		local:             { type: ["string", "null"],
		                     description: "Local domain pattern (e.g. /lan/) resolved authoritatively" },
		noresolv:          { type: "boolean", default: false },
		rebind_protection: { type: "boolean", default: true },
		expandhosts:       { type: "boolean", default: false },
		cachesize:         { "x-uapi-read-nullable": true, type: "integer", minimum: 0, maximum: 1000000 },
		port:              { "x-uapi-read-nullable": true, type: "integer", minimum: 1, maximum: 65535 },
		domainneeded:      { type: "boolean", default: true },
		boguspriv:         { type: "boolean", default: true },
		filterwin2k:       { type: "boolean", default: false },
		authoritative:     { type: "boolean", default: true },
		readethers:        { type: "boolean", default: true },
		leasefile:         { type: ["string", "null"] },
		resolvfile:        { type: ["string", "null"] },
		server:            { type: ["array", "null"], items: { type: "string" } },
		address:           { type: ["array", "null"], items: { type: "string" } },
		nonwildcard:       { type: "boolean", default: true },
	},
};
