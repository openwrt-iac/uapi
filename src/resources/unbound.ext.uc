let values = require('values');
let shell_bool = values.shell_bool;
let as_list = values.as_list;
let check_lines = values.check_lines;

const LINE_ITEM = { type: "string", pattern: values.LINE_RE };

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		enabled: shell_bool(section.enabled, false),
		ext_line: as_list(section.ext_line),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.enabled != null) out.enabled = json.enabled ? "1" : "0";
	if (type(json.ext_line) == "array" && length(json.ext_line) > 0)
		out.ext_line = json.ext_line;
	return out;
}

function validate(json) {
	let errs = [];
	check_lines("ext_line", json.ext_line, errs);
	return errs;
}

return {
	package: "unbound_ext",
	type: "unbound_ext",
	reload: ["unbound-uci-ext"],
	create_if_missing: true,
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		enabled:  { type: "boolean", default: false },
		ext_line: { type: "array", items: LINE_ITEM,
		            description: "Verbatim lines rendered into `/etc/unbound/unbound_ext.conf` (outside the `server:` clause). One uci entry per rendered line; build whole `forward-zone:`, `view:`, `stub:`, or `remote-control:` clauses by listing them in order. `unbound-checkconf` validates grammar after restart." },
	},
};
