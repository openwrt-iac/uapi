let values = require('values');
let normalize_bool = values.normalize_bool;

const VALID_DHCP_LINK = { "none": true, "odhcpd": true, "dnsmasq": true };
const VALID_RECURSION = { "default": true, "passive": true, "aggressive": true };
const VALID_RESOURCE  = { "tiny": true, "small": true, "medium": true,
                          "large": true, "big": true, "huge": true };
const VALID_PROTOCOL  = { "auto": true, "ip4_only": true, "ip6_only": true, "mixed": true };

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		enabled: normalize_bool(section.enabled, true),
		listen_port: section.listen_port ?? null,
		dhcp_link: section.dhcp_link ?? null,
		add_local_fqdn: section.add_local_fqdn ?? null,
		add_wan_fqdn: section.add_wan_fqdn ?? null,
		dnssec_enabled: normalize_bool(section.dnssec_enabled, false),
		recursion: section.recursion ?? null,
		resource: section.resource ?? null,
		protocol: section.protocol ?? null,
		query_minimize: normalize_bool(section.query_minimize, false),
		prefetch: normalize_bool(section.prefetch, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.enabled != null)         out.enabled = json.enabled ? "1" : "0";
	if (json.listen_port != null)     out.listen_port = "" + json.listen_port;
	if (json.dhcp_link != null)       out.dhcp_link = json.dhcp_link;
	if (json.add_local_fqdn != null)  out.add_local_fqdn = "" + json.add_local_fqdn;
	if (json.add_wan_fqdn != null)    out.add_wan_fqdn = "" + json.add_wan_fqdn;
	if (json.dnssec_enabled != null)  out.dnssec_enabled = json.dnssec_enabled ? "1" : "0";
	if (json.recursion != null)       out.recursion = json.recursion;
	if (json.resource != null)        out.resource = json.resource;
	if (json.protocol != null)        out.protocol = json.protocol;
	if (json.query_minimize != null)  out.query_minimize = json.query_minimize ? "1" : "0";
	if (json.prefetch != null)        out.prefetch = json.prefetch ? "1" : "0";
	return out;
}

function validate(json) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	if (json.listen_port != null) {
		let p = int(json.listen_port);
		if (p < 1 || p > 65535)
			push(errs, { field: "listen_port", code: "out_of_range",
			             message: "must be 1-65535" });
	}
	if (json.dhcp_link != null && !VALID_DHCP_LINK[json.dhcp_link])
		push(errs, { field: "dhcp_link", code: "not_in_enum",
		             message: "must be none, odhcpd, or dnsmasq" });
	if (json.recursion != null && !VALID_RECURSION[json.recursion])
		push(errs, { field: "recursion", code: "not_in_enum",
		             message: "must be default, passive, or aggressive" });
	if (json.resource != null && !VALID_RESOURCE[json.resource])
		push(errs, { field: "resource", code: "not_in_enum",
		             message: "must be tiny, small, medium, large, big, or huge" });
	if (json.protocol != null && !VALID_PROTOCOL[json.protocol])
		push(errs, { field: "protocol", code: "not_in_enum",
		             message: "must be auto, ip4_only, ip6_only, or mixed" });
	return errs;
}

return {
	package: "unbound",
	type: "unbound",
	reload: ["unbound"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		dhcp_link: { type: "string", enum: keys(VALID_DHCP_LINK) },
		recursion: { type: "string", enum: keys(VALID_RECURSION) },
		resource:  { type: "string", enum: keys(VALID_RESOURCE) },
		protocol:  { type: "string", enum: keys(VALID_PROTOCOL) },
	},
};
