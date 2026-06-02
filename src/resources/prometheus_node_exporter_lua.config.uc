let values = require('values');
let normalize_bool = values.normalize_bool;

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
		listen_port: section.listen_port ?? null,
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
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
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
			listen_ipv6:      { type: "boolean",
			                    description: "Listen on IPv6 in addition to IPv4" },
			listen_interface: { type: "string",
			                    description: "Bind to a specific network interface (uci interface name)" },
			listen_port:      { type: "integer", minimum: 1, maximum: 65535,
			                    description: "TCP port for the /metrics endpoint" },
		};
		for (let c in COLLECTOR_FIELDS)
			props[c] = { type: "boolean",
			             description: sprintf("Enable the %s collector", c) };
		return props;
	})(),
};
