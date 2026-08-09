let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;
let as_int = values.as_int;

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		// The init reads this with `uci -q get`, defaults it to 1 when absent, and then
		// compares `[ "$ENABLED" -gt 0 ]`. That is numeric, not a bool parse: `enabled 'true'`
		// makes ash bail with "out of range" and usteer stays down, while `enabled '2'` starts
		// it. normalize_bool called the word spellings true, so the read disagreed with the
		// daemon on exactly the values a hand-written config is likely to carry.
		enabled:                       (section.enabled == null) ? true : (int(section.enabled) > 0),
		network:                       section.network ?? null,
		syslog:                        normalize_bool(section.syslog, true),
		debug_level:                   as_int(section.debug_level),
		ipv6:                          normalize_bool(section.ipv6, false),
		sta_block_timeout:             as_int(section.sta_block_timeout),
		local_sta_timeout:             as_int(section.local_sta_timeout),
		local_sta_update:              as_int(section.local_sta_update),
		max_neighbor_reports:          as_int(section.max_neighbor_reports),
		max_retry_band:                as_int(section.max_retry_band),
		seen_policy_timeout:           as_int(section.seen_policy_timeout),
		measurement_report_timeout:    as_int(section.measurement_report_timeout),
		load_balancing_threshold:      as_int(section.load_balancing_threshold),
		band_steering_threshold:       as_int(section.band_steering_threshold),
		remote_update_interval:        as_int(section.remote_update_interval),
		remote_node_timeout:           as_int(section.remote_node_timeout),
		assoc_steering:                normalize_bool(section.assoc_steering, false),
		max_assoc_sta:                 as_int(section.max_assoc_sta),
		min_connect_snr:               as_int(section.min_connect_snr),
		min_snr:                       as_int(section.min_snr),
		min_snr_kick_delay:            as_int(section.min_snr_kick_delay),
		roam_kick_delay:               as_int(section.roam_kick_delay),
		roam_process_timeout:          as_int(section.roam_process_timeout),
		roam_scan_snr:                 as_int(section.roam_scan_snr),
		roam_scan_tries:               as_int(section.roam_scan_tries),
		roam_scan_interval:            as_int(section.roam_scan_interval),
		roam_trigger_snr:              as_int(section.roam_trigger_snr),
		roam_trigger_interval:         as_int(section.roam_trigger_interval),
		signal_diff_threshold:         as_int(section.signal_diff_threshold),
		node_up_script:                section.node_up_script ?? null,
		event_log_types:               as_list(section.event_log_types),
		ssid_list:                     as_list(section.ssid_list),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.enabled != null)                    out.enabled = json.enabled ? "1" : "0";
	if (json.network != null)                    out.network = json.network;
	if (json.syslog != null)                     out.syslog = json.syslog ? "1" : "0";
	if (json.debug_level != null)                out.debug_level = "" + json.debug_level;
	if (json.ipv6 != null)                       out.ipv6 = json.ipv6 ? "1" : "0";
	if (json.sta_block_timeout != null)          out.sta_block_timeout = "" + json.sta_block_timeout;
	if (json.local_sta_timeout != null)          out.local_sta_timeout = "" + json.local_sta_timeout;
	if (json.local_sta_update != null)           out.local_sta_update = "" + json.local_sta_update;
	if (json.max_neighbor_reports != null)       out.max_neighbor_reports = "" + json.max_neighbor_reports;
	if (json.max_retry_band != null)             out.max_retry_band = "" + json.max_retry_band;
	if (json.seen_policy_timeout != null)        out.seen_policy_timeout = "" + json.seen_policy_timeout;
	if (json.measurement_report_timeout != null) out.measurement_report_timeout = "" + json.measurement_report_timeout;
	if (json.load_balancing_threshold != null)   out.load_balancing_threshold = "" + json.load_balancing_threshold;
	if (json.band_steering_threshold != null)    out.band_steering_threshold = "" + json.band_steering_threshold;
	if (json.remote_update_interval != null)     out.remote_update_interval = "" + json.remote_update_interval;
	if (json.remote_node_timeout != null)        out.remote_node_timeout = "" + json.remote_node_timeout;
	if (json.assoc_steering != null)             out.assoc_steering = json.assoc_steering ? "1" : "0";
	if (json.max_assoc_sta != null)              out.max_assoc_sta = "" + json.max_assoc_sta;
	if (json.min_connect_snr != null)            out.min_connect_snr = "" + json.min_connect_snr;
	if (json.min_snr != null)                    out.min_snr = "" + json.min_snr;
	if (json.min_snr_kick_delay != null)         out.min_snr_kick_delay = "" + json.min_snr_kick_delay;
	if (json.roam_kick_delay != null)            out.roam_kick_delay = "" + json.roam_kick_delay;
	if (json.roam_process_timeout != null)       out.roam_process_timeout = "" + json.roam_process_timeout;
	if (json.roam_scan_snr != null)              out.roam_scan_snr = "" + json.roam_scan_snr;
	if (json.roam_scan_tries != null)            out.roam_scan_tries = "" + json.roam_scan_tries;
	if (json.roam_scan_interval != null)         out.roam_scan_interval = "" + json.roam_scan_interval;
	if (json.roam_trigger_snr != null)           out.roam_trigger_snr = "" + json.roam_trigger_snr;
	if (json.roam_trigger_interval != null)      out.roam_trigger_interval = "" + json.roam_trigger_interval;
	if (json.signal_diff_threshold != null)      out.signal_diff_threshold = "" + json.signal_diff_threshold;
	if (json.node_up_script != null)             out.node_up_script = json.node_up_script;
	if (json.event_log_types != null)            out.event_log_types = json.event_log_types;
	if (json.ssid_list != null)                  out.ssid_list = json.ssid_list;
	return out;
}

function validate(json) {
	let errs = [];
	return errs;
}

return {
	package: "usteer",
	type: "usteer",
	reload: ["usteer"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		enabled:                       { type: "boolean", default: true },
		network:                       { type: ["string", "null"], description: "Network interface usteer listens on for peer announcements." },
		syslog:                        { type: "boolean", default: true },
		debug_level:                   { type: ["integer", "null"], minimum: 0, maximum: 3 },
		ipv6:                          { type: "boolean", default: false },
		sta_block_timeout:             { type: ["integer", "null"], minimum: 0 },
		local_sta_timeout:             { type: ["integer", "null"], minimum: 0 },
		local_sta_update:              { type: ["integer", "null"], minimum: 0 },
		max_neighbor_reports:          { type: ["integer", "null"], minimum: 0, maximum: 255 },
		max_retry_band:                { type: ["integer", "null"], minimum: 0 },
		seen_policy_timeout:           { type: ["integer", "null"], minimum: 0 },
		measurement_report_timeout:    { type: ["integer", "null"], minimum: 0 },
		load_balancing_threshold:      { type: ["integer", "null"], minimum: 0, maximum: 255 },
		band_steering_threshold:       { type: ["integer", "null"], minimum: 0, maximum: 255 },
		remote_update_interval:        { type: ["integer", "null"], minimum: 0 },
		remote_node_timeout:           { type: ["integer", "null"], minimum: 0 },
		assoc_steering:                { type: "boolean", default: false },
		max_assoc_sta:                 { deprecated: true, type: ["integer", "null"], minimum: 0, maximum: 255,
		                                 description: "Deprecated, removed in v3: nothing reads this. usteer's init forwards a fixed list of uci options to the daemon over ubus and this is not on it; the daemon's own `max_assoc` knob is not bridged from uci at all." },
		min_connect_snr:               { type: ["integer", "null"], description: "Refuse association below this SNR (dBm)." },
		min_snr:                       { type: ["integer", "null"], description: "Disconnect clients below this SNR (dBm)." },
		min_snr_kick_delay:            { type: ["integer", "null"], minimum: 0 },
		roam_kick_delay:               { type: ["integer", "null"], minimum: 0 },
		roam_process_timeout:          { type: ["integer", "null"], minimum: 0 },
		roam_scan_snr:                 { type: ["integer", "null"] },
		roam_scan_tries:               { type: ["integer", "null"], minimum: 0 },
		roam_scan_interval:            { type: ["integer", "null"], minimum: 0 },
		roam_trigger_snr:              { type: ["integer", "null"] },
		roam_trigger_interval:         { type: ["integer", "null"], minimum: 0 },
		signal_diff_threshold:         { type: ["integer", "null"], minimum: 0 },
		node_up_script:                { type: ["string", "null"], description: "Path to a hook script run on peer changes." },
		event_log_types:               { type: "array", items: { type: "string" },
		                                 description: "Log categories: probe_req, beacon, auth, assoc, load_kick, signal_kick, etc." },
		ssid_list:                     { type: "array", items: { type: "string" },
		                                 description: "Filter usteer's action to these SSIDs (empty = all)." },
	},
};
