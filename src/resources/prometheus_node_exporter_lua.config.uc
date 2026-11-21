let values = require('values');
let as_int = values.as_int;

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		listen_interface: section.listen_interface ?? null,
		listen_port: as_int(section.listen_port),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.listen_interface != null) out.listen_interface = json.listen_interface;
	if (json.listen_port != null)      out.listen_port = "" + json.listen_port;
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
	schema_properties: {
		listen_interface: { "x-uapi-read-nullable": true, type: "string",
		                    description: "Bind to a specific network interface (uci interface name)" },
		listen_port:      { "x-uapi-read-nullable": true, type: "integer", minimum: 1, maximum: 65535,
		                    description: "TCP port for the /metrics endpoint" },
	},
};
