let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;

const VALID_QDISCS  = { "cake": true, "fq_codel": true, "pie": true, "htb": true };
const VALID_SCRIPTS = { "piece_of_cake.qos": true, "simple.qos": true,
                        "simplest.qos": true, "layer_cake.qos": true };
const VALID_LINK    = { "none": true, "ethernet": true, "atm": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		enabled: normalize_bool(section.enabled, true),
		interface: section.interface ?? null,
		download: as_int(section.download),
		upload: as_int(section.upload),
		qdisc: section.qdisc ?? null,
		script: section.script ?? null,
		linklayer: section.linklayer ?? null,
		overhead: as_int(section.overhead),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.enabled != null)   out.enabled = json.enabled ? "1" : "0";
	if (json.interface != null) out.interface = json.interface;
	if (json.download != null)  out.download = "" + json.download;
	if (json.upload != null)    out.upload = "" + json.upload;
	if (json.qdisc != null)     out.qdisc = json.qdisc;
	if (json.script != null)    out.script = json.script;
	if (json.linklayer != null) out.linklayer = json.linklayer;
	if (json.overhead != null)  out.overhead = "" + json.overhead;
	return out;
}

function validate(json, conn) {
	let errs = [];
	values.require_present(errs, json, "interface");
	if (conn != null && json.interface != null && json.interface != "") {
		if (values.section_index(conn, 'network', 'interface', '.name')[json.interface] == null)
			push(errs, { field: "interface", code: "conflict",
			             message: sprintf("interface %J does not exist", json.interface) });
	}
	return errs;
}

return {
	package: "sqm",
	type: "queue",
	reload: ["sqm"],
	unique_field: "interface",
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "SQM queue",
	id_prefix: "q",
	openapi_required: ["interface"],
	schema_properties: {
		enabled:   { type: "boolean", default: true,
		             description: "Whether SQM is active on this interface" },
		interface: { "x-uapi-read-nullable": true, type: "string",
		             description: "Network interface name SQM applies to" },
		qdisc:     { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_QDISCS) },
		script:    { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_SCRIPTS) },
		linklayer: { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_LINK) },
		download:  { "x-uapi-read-nullable": true, type: "integer", minimum: 0 },
		upload:    { "x-uapi-read-nullable": true, type: "integer", minimum: 0 },
		overhead:  { "x-uapi-read-nullable": true, type: "integer",
		             description: "Per-packet overhead bytes for link-layer accounting" },
	},
};
