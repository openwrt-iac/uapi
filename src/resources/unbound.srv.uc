let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;
let check_lines = values.check_lines;

const LINE_ITEM = { type: "string", pattern: values.LINE_RE };

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		enabled: normalize_bool(section.enabled, false),
		ip_transparent: (section.ip_transparent != null)
			? normalize_bool(section.ip_transparent, false) : null,
		interface_bind: as_list(section.interface_bind),
		interface_outgoing: as_list(section.interface_outgoing),
		srv_line: as_list(section.srv_line),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.enabled != null)        out.enabled = json.enabled ? "1" : "0";
	if (json.ip_transparent != null) out.ip_transparent = json.ip_transparent ? "1" : "0";
	if (type(json.interface_bind) == "array" && length(json.interface_bind) > 0)
		out.interface_bind = json.interface_bind;
	if (type(json.interface_outgoing) == "array" && length(json.interface_outgoing) > 0)
		out.interface_outgoing = json.interface_outgoing;
	if (type(json.srv_line) == "array" && length(json.srv_line) > 0)
		out.srv_line = json.srv_line;
	return out;
}

function validate(json) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	check_lines("interface_bind", json.interface_bind, errs);
	check_lines("interface_outgoing", json.interface_outgoing, errs);
	check_lines("srv_line", json.srv_line, errs);
	return errs;
}

return {
	package: "unbound_srv",
	type: "unbound_srv",
	reload: ["unbound-uci-ext"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		enabled:            { type: "boolean" },
		ip_transparent:     { type: ["boolean", "null"],
		                      description: "Bind to addresses that are not yet up / VIP / alias addresses." },
		interface_bind:     { type: "array", items: LINE_ITEM,
		                      description: "Addresses unbound binds on (`addr` or `addr@port`). Pair with `unbound.@unbound[0].interface_auto = false` on the main unbound UCI for exclusive binding." },
		interface_outgoing: { type: "array", items: LINE_ITEM,
		                      description: "Source addresses for upstream recursion (multi-WAN egress)." },
		srv_line:           { type: "array", items: LINE_ITEM,
		                      description: "Verbatim passthrough lines inserted inside unbound's `server:` clause. One uci entry per rendered line; `unbound-checkconf` validates grammar after restart." },
	},
};
