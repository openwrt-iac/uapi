let values = require('values');
let as_int = values.as_int;

const VALID_QDISCS  = { "cake": true, "fq_codel": true, "pie": true, "htb": true, "codel": true, "sfq": true,
                        "fq_pie": true, "ns2_codel": true, "pfifo_fast": true };
const VALID_LINK    = { "none": true, "ethernet": true, "atm": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		// sqm-scripts starts a queue only when `[ "$(config_get "$section" enabled)" -eq 1 ]`
		// holds (src/run-openwrt.sh), so an absent value, or yes, on or true, leaves it off. The
		// `test` of busybox parses the number with strtoll and skips trailing spaces, so ` +01 ` is 1.
		enabled: match(values.config_get(section.enabled) ?? "", /^\s*\+?0*1\s*$/) != null,
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
		enabled:   { type: "boolean", default: false,
		             description: "Whether sqm-scripts starts SQM on this interface. It starts a queue only when `enabled` is 1, so an absent value, or a word such as `yes`, `on` or `true`, reads false." },
		interface: { "x-uapi-read-nullable": true, type: "string",
		             "x-uapi-write": { pattern: "^[^/: \t\n\r\f\v]{1,15}$" },
		             description: "Network device that sqm-scripts shapes, such as `eth1` or `pppoe-wan`: its hotplug starts the queue when this device comes up. The name of a network interface, such as `wan`, matches nothing unless a device has that name. The `runtime.l3_device` of `network/interfaces` gives the device of an interface. A write takes a kernel device name, 1 to 15 characters without `/`, `:` or whitespace, and does not check that the device exists, since a device such as `pppoe-wan` exists only while its interface is up." },
		qdisc:     { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_QDISCS) },
		script:    { "x-uapi-read-nullable": true, type: "string", pattern: "^[A-Za-z0-9_][A-Za-z0-9_.+-]*\\.qos$",
		             description: "A file in /usr/lib/sqm, which LuCI lists and start-sqm sources, such as piece_of_cake.qos, simple.qos, simplest.qos, layer_cake.qos or simplest_tbf.qos." },
		linklayer: { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_LINK) },
		download:  { "x-uapi-read-nullable": true, type: "integer", minimum: 0 },
		upload:    { "x-uapi-read-nullable": true, type: "integer", minimum: 0 },
		overhead:  { "x-uapi-read-nullable": true, type: "integer",
		             description: "Per-packet overhead bytes for link-layer accounting" },
	},
};
