let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;

const VALID_DHCP_LINK = { "none": true, "odhcpd": true, "dnsmasq": true };
const VALID_RECURSION = { "default": true, "passive": true, "aggressive": true };
const VALID_RESOURCE  = { "default": true, "tiny": true, "small": true, "medium": true,
                          "large": true, "big": true, "huge": true };
const VALID_PROTOCOL  = { "default": true, "mixed": true, "ip4_only": true,
                          "ip6_only": true, "ip6_local": true, "ip6_prefer": true };
const VALID_REBIND    = { "0": true, "1": true, "2": true };
const VALID_DOMAIN_TYPE = {
	"deny": true, "refuse": true, "static": true, "transparent": true,
	"redirect": true, "nodefault": true, "typetransparent": true,
	"inform": true, "inform_deny": true,
};

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		enabled: normalize_bool(section.enabled, true),
		listen_port: as_int(section.listen_port),
		dhcp_link: section.dhcp_link ?? null,
		add_local_fqdn: as_int(section.add_local_fqdn),
		add_wan_fqdn: as_int(section.add_wan_fqdn),
		dnssec_enabled: normalize_bool(section.dnssec_enabled, false),
		recursion: section.recursion ?? null,
		resource_limits: section.resource ?? null,
		protocol: section.protocol ?? null,
		query_minimize: normalize_bool(section.query_minimize, false),
		prefetch: normalize_bool(section.prefetch, false),
		manual_conf: (section.manual_conf != null) ? normalize_bool(section.manual_conf, false) : null,
		extended_stats: (section.extended_stats != null) ? normalize_bool(section.extended_stats, false) : null,
		interface_auto: (section.interface_auto != null) ? normalize_bool(section.interface_auto, true) : null,
		localservice: (section.localservice != null) ? normalize_bool(section.localservice, true) : null,
		hide_binddata: (section.hide_binddata != null) ? normalize_bool(section.hide_binddata, true) : null,
		rebind_protection: section.rebind_protection ?? null,
		num_threads: as_int(section.num_threads),
		ttl_min: as_int(section.ttl_min),
		domain: section.domain ?? null,
		domain_type: section.domain_type ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.enabled != null)           out.enabled = json.enabled ? "1" : "0";
	if (json.listen_port != null)       out.listen_port = "" + json.listen_port;
	if (json.dhcp_link != null)         out.dhcp_link = json.dhcp_link;
	if (json.add_local_fqdn != null)    out.add_local_fqdn = "" + json.add_local_fqdn;
	if (json.add_wan_fqdn != null)      out.add_wan_fqdn = "" + json.add_wan_fqdn;
	if (json.dnssec_enabled != null)    out.dnssec_enabled = json.dnssec_enabled ? "1" : "0";
	if (json.recursion != null)         out.recursion = json.recursion;
	if (json.resource_limits != null)   out.resource = json.resource_limits;
	if (json.protocol != null)          out.protocol = json.protocol;
	if (json.query_minimize != null)    out.query_minimize = json.query_minimize ? "1" : "0";
	if (json.prefetch != null)          out.prefetch = json.prefetch ? "1" : "0";
	if (json.manual_conf != null)       out.manual_conf = json.manual_conf ? "1" : "0";
	if (json.extended_stats != null)    out.extended_stats = json.extended_stats ? "1" : "0";
	if (json.interface_auto != null)    out.interface_auto = json.interface_auto ? "1" : "0";
	if (json.localservice != null)      out.localservice = json.localservice ? "1" : "0";
	if (json.hide_binddata != null)     out.hide_binddata = json.hide_binddata ? "1" : "0";
	if (json.rebind_protection != null) out.rebind_protection = "" + json.rebind_protection;
	if (json.num_threads != null)       out.num_threads = "" + json.num_threads;
	if (json.ttl_min != null)           out.ttl_min = "" + json.ttl_min;
	if (json.domain != null)            out.domain = json.domain;
	if (json.domain_type != null)       out.domain_type = json.domain_type;
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
	if (json.resource_limits != null && !VALID_RESOURCE[json.resource_limits])
		push(errs, { field: "resource_limits", code: "not_in_enum",
		             message: "must be tiny, small, medium, large, big, or huge" });
	if (json.protocol != null && !VALID_PROTOCOL[json.protocol])
		push(errs, { field: "protocol", code: "not_in_enum",
		             message: "must be auto, ip4_only, ip6_only, or mixed" });
	if (json.rebind_protection != null && !VALID_REBIND["" + json.rebind_protection])
		push(errs, { field: "rebind_protection", code: "not_in_enum",
		             message: "must be 0 (off), 1 (private nets), or 2 (all)" });
	if (json.domain_type != null && !VALID_DOMAIN_TYPE[json.domain_type])
		push(errs, { field: "domain_type", code: "not_in_enum",
		             message: "must be one of " + join(", ", keys(VALID_DOMAIN_TYPE)) });
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
		enabled:           { type: "boolean" },
		listen_port:       { type: "integer", minimum: 1, maximum: 65535 },
		dhcp_link:         { type: "string", enum: keys(VALID_DHCP_LINK) },
		add_local_fqdn:    { type: ["integer", "null"], minimum: 0, maximum: 4,
		                     description: "How aggressively to add local FQDNs (0..4)" },
		add_wan_fqdn:      { type: ["integer", "null"], minimum: 0, maximum: 4,
		                     description: "How aggressively to add WAN FQDNs (0..4)" },
		dnssec_enabled:    { type: "boolean" },
		recursion:         { type: "string", enum: keys(VALID_RECURSION) },
		resource_limits:   { type: "string", enum: keys(VALID_RESOURCE),
		                     description: "Memory / cache sizing preset. Renamed on the wire from uci's `resource` (HCL block keyword)." },
		protocol:          { type: "string", enum: keys(VALID_PROTOCOL) },
		query_minimize:    { type: "boolean" },
		prefetch:          { type: "boolean" },
		rebind_protection: { type: "string", enum: keys(VALID_REBIND),
		                     description: "0 = off, 1 = private nets, 2 = all rebind attacks blocked" },
		domain:            { type: ["string", "null"] },
		domain_type:       { type: "string", enum: keys(VALID_DOMAIN_TYPE),
		                     description: "Local-zone type for the configured domain" },
		manual_conf:       { type: "boolean",
		                     description: "Skip uci and use /etc/unbound/unbound.conf hand-written" },
		extended_stats:    { type: "boolean",
		                     description: "Emit extended statistics (stats-extended: yes)" },
		interface_auto:    { type: "boolean",
		                     description: "Bind to all interfaces (interface-automatic: yes). Disable to bind manually via /etc/unbound/unbound_srv.conf." },
		localservice:      { type: "boolean" },
		hide_binddata:     { type: "boolean" },
		num_threads:       { type: "integer", minimum: 1, maximum: 64 },
		ttl_min:           { type: "integer", minimum: 0, maximum: 86400 },
	},
};
