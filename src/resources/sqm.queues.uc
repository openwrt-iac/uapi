let values = require('values');
let as_int = values.as_int;

const VALID_QDISCS  = { "cake": true, "fq_codel": true, "pie": true, "htb": true, "codel": true, "sfq": true,
                        "fq_pie": true, "ns2_codel": true, "pfifo_fast": true };
const VALID_LINK    = { "none": true, "ethernet": true, "atm": true };
const SHELL_ONE_RE  = /^\s*\+?0*1\s*$/;
// The uci options whose names are not snake case.
const UCI_NAME = { tc_mtu: "tcMTU", tc_tsize: "tcTSIZE", tc_mpu: "tcMPU" };
const LUCI_FLAGS = [ "qdisc_advanced", "qdisc_really_really_advanced", "linklayer_advanced" ];
const SHELL_FLAGS = [ "debug_logging", "use_mq" ];
const INTS = [ "tc_mtu", "tc_tsize", "tc_mpu", "verbosity" ];
const STRINGS = [ "ingress_ecn", "egress_ecn", "linklayer_adaptation_mechanism" ];
// Null leaves these to the qdisc, so they read null when absent.
const CALLER_OWNED = [ "ilimit", "elimit", "itarget", "etarget", "iqdisc_opts", "eqdisc_opts" ];

// defaults.sh of sqm-scripts gives these to an option that is absent or empty.
const SQM_DEFAULTS = { download: 14698, upload: 2302, qdisc: "fq_codel", linklayer: "none", overhead: 0,
                       tc_mtu: 2047, tc_tsize: 512, tc_mpu: 0, verbosity: 5, ingress_ecn: "ECN",
                       egress_ecn: "ECN", linklayer_adaptation_mechanism: "default" };

function sqm_value(section, field) {
	let v = values.config_get(section[UCI_NAME[field] ?? field]);
	return (v == null || v == "") ? null : v;
}

function sqm_int(section, field) {
	let v = sqm_value(section, field);
	return (v == null) ? SQM_DEFAULTS[field] : as_int(v);
}

// The cake scripts test squash_dscp and squash_ingress with `-eq 1`, and simple.qos with `= "1"`.
// defaults.sh gives 1 to an absent or empty one.
function squash(section, field) {
	let v = sqm_value(section, field);
	if (v == null) return true;
	return (section.script == "simple.qos") ? v == "1" : match(v, SHELL_ONE_RE) != null;
}

function fromUci_luci_options(section) {
	let out = {
		ilimit: as_int(section.ilimit),
		elimit: as_int(section.elimit),
		itarget: section.itarget ?? null,
		etarget: section.etarget ?? null,
		iqdisc_opts: section.iqdisc_opts ?? null,
		eqdisc_opts: section.eqdisc_opts ?? null,
	};
	for (let f in LUCI_FLAGS) out[f] = section[f] == "1";
	for (let f in SHELL_FLAGS) out[f] = match(sqm_value(section, f) ?? "", SHELL_ONE_RE) != null;
	out.squash_dscp = squash(section, "squash_dscp");
	out.squash_ingress = squash(section, "squash_ingress");
	for (let f in INTS) out[f] = sqm_int(section, f);
	for (let f in STRINGS) out[f] = sqm_value(section, f) ?? SQM_DEFAULTS[f];
	return out;
}

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		// sqm-scripts starts a queue only when `[ "$(config_get "$section" enabled)" -eq 1 ]`
		// holds (src/run-openwrt.sh), so an absent value, or yes, on or true, leaves it off. The
		// `test` of busybox parses the number with strtoll and skips trailing spaces, so ` +01 ` is 1.
		enabled: match(values.config_get(section.enabled) ?? "", SHELL_ONE_RE) != null,
		interface: section.interface ?? null,
		download: sqm_int(section, "download"),
		upload: sqm_int(section, "upload"),
		qdisc: sqm_value(section, "qdisc") ?? SQM_DEFAULTS.qdisc,
		script: section.script ?? null,
		linklayer: sqm_value(section, "linklayer") ?? SQM_DEFAULTS.linklayer,
		overhead: sqm_int(section, "overhead"),
		...fromUci_luci_options(section),
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
	for (let f in [ ...LUCI_FLAGS, ...SHELL_FLAGS, "squash_dscp", "squash_ingress" ])
		if (json[f] != null) out[f] = json[f] ? "1" : "0";
	for (let f in [ ...INTS, ...STRINGS, ...CALLER_OWNED ])
		if (json[f] != null) out[UCI_NAME[f] ?? f] = "" + json[f];
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
		qdisc:     { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_QDISCS), default: "fq_codel",
		             description: "Queueing discipline. sqm-scripts uses fq_codel when the option is absent." },
		script:    { "x-uapi-read-nullable": true, type: "string", pattern: "^[A-Za-z0-9_][A-Za-z0-9_.+-]*\\.qos$",
		             description: "A file in /usr/lib/sqm, which LuCI lists and start-sqm sources, such as piece_of_cake.qos, simple.qos, simplest.qos, layer_cake.qos or simplest_tbf.qos." },
		linklayer: { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_LINK), default: "none",
		             description: "Link layer that the shaper accounts for." },
		download:  { "x-uapi-read-nullable": true, type: "integer", minimum: 0, default: 14698,
		             description: "Download (ingress) rate in kbit/s, 0 to shape no ingress. sqm-scripts uses 14698 when the option is absent." },
		upload:    { "x-uapi-read-nullable": true, type: "integer", minimum: 0, default: 2302,
		             description: "Upload (egress) rate in kbit/s, 0 to shape no egress. sqm-scripts uses 2302 when the option is absent." },
		overhead:  { "x-uapi-read-nullable": true, type: "integer", default: 0,
		             description: "Per-packet overhead bytes for link-layer accounting" },
		qdisc_advanced: { type: "boolean", default: false,
		             description: "LuCI's \"Advanced Configuration\" flag. sqm-scripts does not read it and applies squash_dscp, squash_ingress, ingress_ecn and egress_ecn whatever it holds. LuCI shows those fields only while it is true, so set it with them for a LuCI user to see them." },
		qdisc_really_really_advanced: { type: "boolean", default: false,
		             description: "LuCI's \"Dangerous Configuration\" flag. sqm-scripts does not read it and applies ilimit, elimit, itarget, etarget, iqdisc_opts and eqdisc_opts whatever it holds. LuCI shows those fields only while it and qdisc_advanced are true." },
		linklayer_advanced: { type: "boolean", default: false,
		             description: "LuCI's \"Advanced Linklayer Options\" flag. sqm-scripts does not read it and applies tc_mtu, tc_tsize, tc_mpu and linklayer_adaptation_mechanism whatever it holds. LuCI shows those fields only while it is true." },
		squash_dscp: { type: "boolean", default: true,
		             description: "Whether the ingress shaper clears the DSCP marks (LuCI \"Squash DSCP\"). An absent option reads true, as sqm-scripts applies it. The cake scripts take a stored value that `-eq 1` reads as 1, such as `01`, and simple.qos takes only `1`, so the read follows the stored `script`." },
		squash_ingress: { type: "boolean", default: true,
		             description: "Whether the ingress shaper ignores the DSCP marks (LuCI \"Ignore DSCP\"). An absent option reads true, as sqm-scripts applies it. The cake scripts take a stored value that `-eq 1` reads as 1, such as `01`, and simple.qos takes only `1`, so the read follows the stored `script`." },
		ingress_ecn: { type: "string", default: "ECN", "x-uapi-write": { enum: [ "ECN", "NOECN" ] },
		             description: "ECN on the ingress queues of a codel, pie or red qdisc. An absent option applies ECN. Another stored value goes to tc as it is, after a warning of sqm-scripts, and reads as stored." },
		egress_ecn: { type: "string", default: "ECN", "x-uapi-write": { enum: [ "ECN", "NOECN" ] },
		             description: "ECN on the egress queues of a codel, pie or red qdisc. LuCI proposes NOECN, but an absent option applies ECN. Another stored value goes to tc as it is, after a warning of sqm-scripts, and reads as stored." },
		ilimit: { "x-uapi-clear-on-omit": true, type: ["integer", "null"], "x-uapi-write": { minimum: 0 },
		             description: "Hard limit of the ingress queues (LuCI \"Hard queue limit\"). Null uses the default limit of the qdisc." },
		elimit: { "x-uapi-clear-on-omit": true, type: ["integer", "null"], "x-uapi-write": { minimum: 0 },
		             description: "Hard limit of the egress queues (LuCI \"Hard queue limit\"). Null uses the default limit of the qdisc." },
		itarget: { "x-uapi-clear-on-omit": true, type: ["string", "null"], pattern: values.ONE_LINE_RE,
		             description: "Latency target of the ingress queues, such as `5ms`, with the unit s, ms or us. `default` uses the default of the qdisc, and null lets sqm-scripts compute one from the rate." },
		etarget: { "x-uapi-clear-on-omit": true, type: ["string", "null"], pattern: values.ONE_LINE_RE,
		             description: "Latency target of the egress queues, such as `5ms`, with the unit s, ms or us. `default` uses the default of the qdisc, and null lets sqm-scripts compute one from the rate." },
		iqdisc_opts: { "x-uapi-clear-on-omit": true, type: ["string", "null"], pattern: values.ONE_LINE_RE,
		             description: "Words that sqm-scripts appends to each tc qdisc command of the ingress. uapi does not check them. When tc refuses them, sqm-scripts logs the error and the queue is not set up, while the write still answers 2xx." },
		eqdisc_opts: { "x-uapi-clear-on-omit": true, type: ["string", "null"], pattern: values.ONE_LINE_RE,
		             description: "Words that sqm-scripts appends to each tc qdisc command of the egress. uapi does not check them. When tc refuses them, sqm-scripts logs the error and the queue is not set up, while the write still answers 2xx." },
		linklayer_adaptation_mechanism: { type: "string", default: "default",
		             "x-uapi-write": { enum: [ "default", "cake", "htb_private", "tc_stab" ] },
		             description: "How the shaper accounts for the link layer. `default` uses cake's own accounting for qdisc cake and tc_stab for the others. A stored value outside the write enum reads as stored." },
		tc_mtu: { "x-uapi-read-nullable": true, type: "integer", default: 2047, "x-uapi-write": { minimum: 0 },
		             description: "uci option `tcMTU`, LuCI \"Maximum packet size\": the largest size for the size and rate tables, in bytes." },
		tc_tsize: { "x-uapi-read-nullable": true, type: "integer", default: 512, "x-uapi-write": { minimum: 0 },
		             description: "uci option `tcTSIZE`, LuCI \"Rate table size\": the number of entries of the size and rate tables. LuCI proposes 128, but an absent option applies 512." },
		tc_mpu: { "x-uapi-read-nullable": true, type: "integer", default: 0, "x-uapi-write": { minimum: 0 },
		             description: "uci option `tcMPU`, LuCI \"Minimum packet size\", in bytes." },
		debug_logging: { type: "boolean", default: false,
		             description: "Whether sqm-scripts writes a log file of this queue under /var/run/sqm. It is on when `-eq 1` reads the stored value as 1." },
		verbosity: { "x-uapi-read-nullable": true, type: "integer", default: 5,
		             "x-uapi-write": { enum: [ 0, 1, 2, 5, 8, 10 ] },
		             description: "Log level of sqm-scripts in the system log: 0 silent, 1 error, 2 warning, 5 info, 8 debug, 10 trace. A stored integer outside the write enum reads as stored, and sqm-scripts compares it with these levels." },
		use_mq: { type: "boolean", default: false,
		             description: "Whether sqm-scripts sets up one queue for each hardware queue of the device, where the device has several. LuCI does not show it. It is on when `-eq 1` reads the stored value as 1." },
	},
};
