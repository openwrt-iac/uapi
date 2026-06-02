let values = require('values');
let normalize_bool = values.normalize_bool;

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
		download: section.download ?? null,
		upload: section.upload ?? null,
		qdisc: section.qdisc ?? null,
		script: section.script ?? null,
		linklayer: section.linklayer ?? null,
		overhead: section.overhead ?? null,
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

function interface_exists(conn, name) {
	let found = false;
	conn.uci_foreach('network', 'interface', function(s) {
		if (s['.name'] == name) { found = true; return false; }
	});
	return found;
}

function validate(json, conn) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	if (json.interface == null || json.interface == "")
		push(errs, { field: "interface", code: "required", message: "is required" });
	if (conn != null && json.interface != null && json.interface != "") {
		if (!interface_exists(conn, json.interface))
			push(errs, { field: "interface", code: "conflict",
			             message: sprintf("interface %J does not exist", json.interface) });
	}
	return errs;
}

return {
	package: "sqm",
	type: "queue",
	reload: ["sqm"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	id_prefix: "q",
	schema_properties: {
		qdisc:     { type: "string", enum: keys(VALID_QDISCS) },
		script:    { type: "string", enum: keys(VALID_SCRIPTS) },
		linklayer: { type: "string", enum: keys(VALID_LINK) },
		download:  { type: "integer", minimum: 0 },
		upload:    { type: "integer", minimum: 0 },
	},
};
