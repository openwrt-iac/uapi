let values = require('values');
let shell_bool = values.shell_bool;
let as_list_or_null = values.as_list_or_null;
let as_int = values.as_int;
let is_valid_ip = values.is_valid_ip;

const VALID_FAMILY = { "ipv4": true, "ipv6": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		// mwan3's init reads this with `config_get_bool enabled $interface 'enabled' '0'`, so an
		// absent option means off. Declaring true here reported an interface mwan3 ignores as
		// enabled, and any PATCH persisted that read view as `enabled='1'`, switching it on.
		enabled:                shell_bool(section.enabled, false),
		family:                 section.family ?? null,
		track_ip:               as_list_or_null(section.track_ip),
		track_method:           section.track_method ?? null,
		reliability:            as_int(section.reliability),
		probe_count:            as_int(section.count),
		size:                   as_int(section.size),
		max_ttl:                as_int(section.max_ttl),
		check_quality:          shell_bool(section.check_quality, false),
		failure_latency:        as_int(section.failure_latency),
		failure_loss:           as_int(section.failure_loss),
		recovery_latency:       as_int(section.recovery_latency),
		recovery_loss:          as_int(section.recovery_loss),
		timeout:                as_int(section.timeout),
		interval:               as_int(section.interval),
		failure_interval:       as_int(section.failure_interval),
		recovery_interval:      as_int(section.recovery_interval),
		keep_failure_interval:  shell_bool(section.keep_failure_interval, false),
		down:                   as_int(section.down),
		up:                     as_int(section.up),
		flush_conntrack:        as_list_or_null(section.flush_conntrack),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.enabled != null)               out.enabled = json.enabled ? "1" : "0";
	if (json.family != null)                out.family = json.family;
	if (json.track_ip != null)              out.track_ip = json.track_ip;
	if (json.track_method != null)          out.track_method = json.track_method;
	if (json.reliability != null)           out.reliability = "" + json.reliability;
	if (json.probe_count != null)           out.count = "" + json.probe_count;
	if (json.size != null)                  out.size = "" + json.size;
	if (json.max_ttl != null)               out.max_ttl = "" + json.max_ttl;
	if (json.check_quality != null)         out.check_quality = json.check_quality ? "1" : "0";
	if (json.failure_latency != null)       out.failure_latency = "" + json.failure_latency;
	if (json.failure_loss != null)          out.failure_loss = "" + json.failure_loss;
	if (json.recovery_latency != null)      out.recovery_latency = "" + json.recovery_latency;
	if (json.recovery_loss != null)         out.recovery_loss = "" + json.recovery_loss;
	if (json.timeout != null)               out.timeout = "" + json.timeout;
	if (json.interval != null)              out.interval = "" + json.interval;
	if (json.failure_interval != null)      out.failure_interval = "" + json.failure_interval;
	if (json.recovery_interval != null)     out.recovery_interval = "" + json.recovery_interval;
	if (json.keep_failure_interval != null) out.keep_failure_interval = json.keep_failure_interval ? "1" : "0";
	if (json.down != null)                  out.down = "" + json.down;
	if (json.up != null)                    out.up = "" + json.up;
	if (json.flush_conntrack != null)       out.flush_conntrack = json.flush_conntrack;
	return out;
}

function validate(json) {
	let errs = [];
	if (type(json.track_ip) == "array") {
		for (let i = 0; i < length(json.track_ip); i++) {
			if (!is_valid_ip(json.track_ip[i]))
				push(errs, { field: sprintf("track_ip[%d]", i), code: "invalid_format",
				             message: "must be a valid IPv4 or IPv6 address" });
		}
	}
	return errs;
}

return {
	package: "mwan3",
	type: "interface",
	reload: ["mwan3"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "mwan3 interface",
	id_prefix: "i",
	openapi_required: ["family"],
	schema_properties: {
		enabled:               { type: "boolean", default: false },
		family:                { type: "string", enum: keys(VALID_FAMILY),
		                         description: "Address family this interface tracks." },
		track_ip:              { type: ["array", "null"], items: { type: "string" },
		                         description: "List of IPs to ping for reachability." },
		track_method:          { type: ["string", "null"], enum: ["ping", "arping", "httping", "nping-tcp", "nping-udp", null] },
		reliability:           { type: ["integer", "null"], minimum: 1,
		                         description: "Min reachable track_ip count to call this interface up." },
		probe_count:           { type: ["integer", "null"], minimum: 1, maximum: 10,
		                         description: "Probes per cycle per track_ip. Maps to the `count` uci option; renamed on the wire because Terraform reserves the top-level `count` attribute." },
		size:                  { type: ["integer", "null"], minimum: 1, maximum: 65507,
		                         description: "Probe payload size in bytes." },
		max_ttl:               { type: ["integer", "null"], minimum: 1, maximum: 255 },
		check_quality:         { type: "boolean", default: false,
		                         description: "Enable failure_latency/failure_loss thresholds." },
		failure_latency:       { type: ["integer", "null"], minimum: 1 },
		failure_loss:          { type: ["integer", "null"], minimum: 1, maximum: 100 },
		recovery_latency:      { type: ["integer", "null"], minimum: 1 },
		recovery_loss:         { type: ["integer", "null"], minimum: 0, maximum: 100 },
		timeout:               { type: ["integer", "null"], minimum: 1, maximum: 60 },
		interval:              { type: ["integer", "null"], minimum: 1, maximum: 3600 },
		failure_interval:      { type: ["integer", "null"], minimum: 1, maximum: 3600 },
		recovery_interval:     { type: ["integer", "null"], minimum: 1, maximum: 3600 },
		keep_failure_interval: { type: "boolean", default: false },
		down:                  { type: ["integer", "null"], minimum: 1,
		                         description: "Consecutive failed probes before marking down." },
		up:                    { type: ["integer", "null"], minimum: 1,
		                         description: "Consecutive successful probes before marking up." },
		flush_conntrack:       { type: ["array", "null"], items: { type: "string", enum: ["ifup", "ifdown", "connected", "disconnected", "never"] },
		                         description: "Events that flush conntrack table." },
	},
};
