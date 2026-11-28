let values = require('values');

function fromUci(section) {
	return {
		id: section['.name'],
		managed: !section['.anonymous'],
		name: section.name ?? null,
		ip: section.ip ?? null,
		instance: section.instance ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null)     out.name = json.name;
	if (json.ip != null)       out.ip = json.ip;
	if (json.instance != null) out.instance = json.instance;
	return out;
}

function validate(json, conn) {
	let errs = [];

	values.require_present(errs, json, "name");
	if (values.require_present(errs, json, "ip") && !values.is_valid_ip(json.ip))
		push(errs, { field: "ip", code: "invalid_format",
		             message: "must be a valid IPv4 or IPv6 address without a prefix length" });

	// dnsmasq.init applies a domain that names an instance only to that instance, so a name
	// that matches no `config dnsmasq` section leaves the record in no hosts file.
	if (conn != null && json.instance != null && json.instance != "") {
		if (values.section_index(conn, 'dhcp', 'dnsmasq', '.name')[json.instance] == null)
			push(errs, { field: "instance", code: "conflict",
			             message: sprintf("no dhcp/dnsmasq section named %J exists", json.instance) });
	}

	return errs;
}

return {
	package: "dhcp",
	type: "domain",
	// dnsmasq.init writes each domain into the hosts file of its instance, and unbound makes A,
	// AAAA and PTR records of them when its add_extra_dns is set. odhcpd does not read them.
	reload_if_running: ["dnsmasq", "unbound"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "DHCP domain",
	openapi_required: ["name", "ip"],
	schema_properties: {
		name:     { "x-uapi-read-nullable": true, type: "string", pattern: "^[^ \t]*$",
		            "x-uapi-write": { pattern: "^([a-zA-Z0-9_]+|[a-zA-Z0-9_][a-zA-Z0-9_.-]*[a-zA-Z0-9]\\.?)$" },
		            description: "Hostname that dnsmasq answers with `ip`, LuCI's Hostname. A write takes letters, digits, underscores, dashes and dots, in the shape that LuCI's `hostname` datatype takes. LuCI also refuses a name of more than 253 characters, and a name with a dot that holds only digits and dots, such as `10.0.0.1`, but a write takes both. A read also gives another single word. A stored value with a space or a tab is an error of the section and blocks every write of it: dnsmasq.init makes each word a name of the address, and unbound takes the whole value as one name." },
		ip:       { "x-uapi-read-nullable": true, type: "string",
		            description: "IPv4 or IPv6 address without a prefix length, LuCI's IP address. dnsmasq skips a domain without one." },
		instance: { type: ["string", "null"],
		            description: "The dhcp/dnsmasq section (instance) whose hosts file gets this record. Unset, every instance gets it. unbound ignores it. LuCI's form does not show it." },
	},
};
