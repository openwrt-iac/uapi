let values = require('values');
let strict_bool = values.strict_bool;
let as_int = values.as_int;

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		// dnsmasq.init tests `-gt 0` on the option of the section named odhcpd, and odhcpd takes
		// `1` and `true` through uci's blob converter. `1` is the one value both take.
		maindhcp: strict_bool(section.maindhcp) && section['.name'] == "odhcpd",
		leasefile: section.leasefile ?? null,
		leasetrigger: section.leasetrigger ?? null,
		loglevel: as_int(section.loglevel),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.maindhcp != null)     out.maindhcp = json.maindhcp ? "1" : "0";
	if (json.leasefile != null)    out.leasefile = json.leasefile;
	if (json.leasetrigger != null) out.leasetrigger = json.leasetrigger;
	if (json.loglevel != null)     out.loglevel = "" + json.loglevel;
	return out;
}

function validate(json) {
	let errs = [];

	return errs;
}

return {
	package: "dhcp",
	type: "odhcpd",
	reload: ["odhcpd"],
	// dnsmasq.init reads maindhcp to decide whether dnsmasq serves DHCPv4.
	reload_if_running: ["dnsmasq"],
	rewrite_when_named: ["maindhcp"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		maindhcp:     { type: "boolean", default: false,
		                description: "Use odhcpd as the DHCPv4 server in place of dnsmasq. A read gives true only for `1` in the section named `odhcpd`, as dnsmasq.init reads it: dnsmasq stops serving DHCPv4 for a number above 0 there, while odhcpd is installed, unless odhcpd is disabled and dnsmasq has DHCPv6 support. odhcpd takes `1` and `true` from any `config odhcpd` section, and for any other value or no option keeps the value that it has, which is false after a start, because a reload does not reset it. So a stored `true` reads false while odhcpd and dnsmasq both serve DHCPv4, and a stored `2` reads false while dnsmasq stops and odhcpd serves only if it did before. A write of true stores `1` and a write of false stores `0`, also when the read already gives that value, so a write that sends the field makes both daemons agree. null removes the option, and odhcpd then keeps its value until it restarts. In a section that is not named `odhcpd`, a read gives false, and a write of true stores `1` and still reads false. LuCI shows any value other than `1` unchecked, and removes the option when it saves the form." },
		leasefile:    { type: ["string", "null"],
		                description: "Path where odhcpd persists active leases" },
		leasetrigger: { type: ["string", "null"],
		                description: "Script invoked on lease add/update/del" },
		loglevel:     { "x-uapi-read-nullable": true, type: "integer", minimum: 0, maximum: 7,
		                description: "syslog priority (0=emerg .. 7=debug)" },
	},
};
