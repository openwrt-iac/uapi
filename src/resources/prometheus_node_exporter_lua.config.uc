let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;

const COLLECTOR_FIELDS = [
	"cpu", "meminfo", "netdev", "loadavg", "filesystem", "diskstats",
	"uname", "netstat", "stat", "vmstat", "boottime", "entropy", "time",
	"hwmon", "textfile", "thermal_zone", "edac",
];

function fromUci(section) {
	let out = {
		id: section['.name'],
		managed: true,
		listen_ipv6: normalize_bool(section.listen_ipv6, false),
		listen_interface: section.listen_interface ?? null,
		listen_port: as_int(section.listen_port),
		runtime: {},
	};
	for (let c in COLLECTOR_FIELDS)
		out[c] = normalize_bool(section[c], false);
	return out;
}

function toUci(json) {
	let out = {};
	if (json.listen_ipv6 != null)      out.listen_ipv6 = json.listen_ipv6 ? "1" : "0";
	if (json.listen_interface != null) out.listen_interface = json.listen_interface;
	if (json.listen_port != null)      out.listen_port = "" + json.listen_port;
	for (let c in COLLECTOR_FIELDS) {
		if (json[c] != null) out[c] = json[c] ? "1" : "0";
	}
	return out;
}

function validate(json) {
	let errs = [];
	return errs;
}

return {
	package: "prometheus-node-exporter-lua",
	type: "prometheus-node-exporter-lua",
	reload: ["prometheus-node-exporter-lua"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: (function() {
		let props = {
			// The init derives the v6 bind from `listen_interface`; nothing reads this
			// option. Flagged for v3 removal so a generator warns, per docs/deprecations.md.
			listen_ipv6:      { type: "boolean", default: false, deprecated: true,
			                    description: "Deprecated, removed in v3: nothing reads this. The IPv6 bind is derived from listen_interface." },
			listen_interface: { type: "string",
			                    description: "Bind to a specific network interface (uci interface name)" },
			listen_port:      { type: "integer", minimum: 1, maximum: 65535,
			                    description: "TCP port for the /metrics endpoint" },
		};
		// Collectors are enumerated from /usr/lib/lua/prometheus-collectors/*.lua at run
		// time; no uci is consulted, and seven of these names match no collector shipped in
		// the package at all. Flagged for v3 removal so a generator warns.
		for (let c in COLLECTOR_FIELDS)
			props[c] = { type: "boolean", default: false, deprecated: true,
			             description: sprintf("Deprecated, removed in v3: nothing reads this. The %s collector is enabled by its .lua file being present, not by uci.", c) };
		return props;
	})(),
};
