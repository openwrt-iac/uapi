let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		domain: section.domain ?? null,
		local: section.local ?? null,
		noresolv: normalize_bool(section.noresolv, false),
		rebind_protection: normalize_bool(section.rebind_protection, true),
		expandhosts: normalize_bool(section.expandhosts, false),
		cachesize: section.cachesize ?? null,
		port: section.port ?? null,
		domainneeded: normalize_bool(section.domainneeded, true),
		boguspriv: normalize_bool(section.boguspriv, true),
		filterwin2k: normalize_bool(section.filterwin2k, false),
		authoritative: normalize_bool(section.authoritative, true),
		readethers: normalize_bool(section.readethers, true),
		leasefile: section.leasefile ?? null,
		resolvfile: section.resolvfile ?? null,
		server: as_list(section.server),
		address: as_list(section.address),
		nonwildcard: normalize_bool(section.nonwildcard, true),
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

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}

	if (json.cachesize != null) {
		let c = int(json.cachesize);
		if (c < 0)
			push(errs, { field: "cachesize", code: "out_of_range",
			             message: "must be non-negative" });
	}
	if (json.port != null) {
		let p = int(json.port);
		if (p < 0 || p > 65535)
			push(errs, { field: "port", code: "out_of_range",
			             message: "must be 0-65535" });
	}

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
		server:  { type: "array", items: { type: "string" } },
		address: { type: "array", items: { type: "string" } },
	},
};
