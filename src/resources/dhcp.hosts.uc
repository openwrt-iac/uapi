let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;
let is_valid_ip = values.is_valid_ip;

const MAC_RE = /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/;
const LEASETIME_RE = /^[0-9]+[smhdwMY]?$/;
const DUID_RE = /^[0-9A-Fa-f]{2}([:]?[0-9A-Fa-f]{2})+$/;
const IPV6_HOSTID_RE = /^[0-9A-Fa-f:]+$/;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	let macs = as_list(section.mac);
	let primary_mac = length(macs) > 0 ? macs[0] : null;
	let extra_macs = length(macs) > 1 ? slice(macs, 1) : [];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		macs: macs,
		mac: primary_mac,
		mac_aliases: extra_macs,
		duid: section.duid ?? null,
		hostid: section.hostid ?? null,
		ip: section.ip ?? null,
		leasetime: section.leasetime ?? null,
		tag: section.tag ?? null,
		dns: normalize_bool(section.dns, false),
		broadcast: (section.broadcast != null) ? normalize_bool(section.broadcast, false) : null,
		instance: section.instance ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;

	// `macs` is the whole uci `list mac`; `mac` and `mac_aliases` are its head and tail,
	// deprecated for v3. `macs` wins when non-empty, which is what makes resolve_for_replace
	// below safe: the resolution changes no uci outcome.
	let aliases = (type(json.mac_aliases) == "array") ? json.mac_aliases : [];
	if (type(json.macs) == "array" && length(json.macs) > 0) {
		out.mac = (length(json.macs) > 1) ? json.macs : json.macs[0];
	} else if (json.mac != null && length(aliases) > 0) {
		let all = [json.mac];
		for (let a in aliases) push(all, a);
		out.mac = all;
	} else if (json.mac != null) {
		out.mac = json.mac;
	}

	if (json.duid != null)      out.duid = json.duid;
	if (json.hostid != null)    out.hostid = json.hostid;
	if (json.ip != null)        out.ip = json.ip;
	if (json.leasetime != null) out.leasetime = json.leasetime;
	if (json.tag != null)       out.tag = json.tag;
	if (json.dns != null)       out.dns = json.dns ? "1" : "0";
	if (json.broadcast != null) out.broadcast = json.broadcast ? "1" : "0";
	if (json.instance != null)  out.instance = json.instance;
	return out;
}

// `dhcp.host.instance` references a dnsmasq instance (the dhcp.dnsmasq section
// name), not a per-interface dhcp.dhcp section. dnsmasq's init reads
// config_get_bool ... "$instance" against `config dnsmasq` entries.
function dnsmasq_instance_exists(conn, name) {
	return values.section_index(conn, 'dhcp', 'dnsmasq', '.name')[name] != null;
}

function equal_list(a, b) {
	if (length(a) != length(b)) return false;
	for (let i = 0; i < length(a); i++)
		if (a[i] != b[i]) return false;
	return true;
}

// The default merge folds the read view into the body, so a PATCH naming only `macs`
// arrived carrying the `mac` and `mac_aliases` that had just been read. Whichever surface
// the caller actually named wins; the other is dropped rather than resurrected from the
// server's own read.
function merge_for_patch(existing_json, body) {
	let merged = { ...existing_json };
	for (let k in body) {
		if (type(merged[k]) == "object" && type(body[k]) == "object")
			merged[k] = { ...merged[k], ...body[k] };
		else
			merged[k] = body[k];
	}
	let sent_list = exists(body, "macs");
	let sent_split = exists(body, "mac") || exists(body, "mac_aliases");
	if (sent_list && !sent_split) { delete merged.mac; delete merged.mac_aliases; }
	else if (sent_split && !sent_list) delete merged.macs;
	return merged;
}

// A full-replace caller cannot avoid sending all three names disagreeing: fromUci mirrors
// the list into `mac` and `mac_aliases`, so both are in the caller's state even when it
// only ever wrote `macs`, and a PUT carries every field it knows. `macs` is the documented
// winner and toUci already prefers it, so resolve to it rather than refusing the body.
// PATCH has merge_for_patch to express "did not name", and POST has no prior read to have
// carried a stale split back, so both keep the 422.
function resolve_for_replace(body) {
	if (type(body) != "object" || type(body.macs) != "array" || length(body.macs) == 0)
		return body;

	let aliases = (type(body.mac_aliases) == "array") ? body.mac_aliases : [];
	let head_ok = body.mac == null || body.mac == "" || body.mac == body.macs[0];
	let tail_ok = length(aliases) == 0 || equal_list(aliases, slice(body.macs, 1));
	if (head_ok && tail_ok) return body;

	let out = { ...body };
	delete out.mac;
	delete out.mac_aliases;
	return out;
}

function validate(json, conn) {
	let errs = [];

	let macs = (type(json.macs) == "array") ? json.macs : [];
	let aliases = (type(json.mac_aliases) == "array") ? json.mac_aliases : [];
	let has_macs = length(macs) > 0;
	let has_mac = json.mac != null && json.mac != "";
	let has_duid = json.duid != null && json.duid != "";

	// Reported against `mac` even though `macs` is the preferred name: callers match on
	// the field of an existing error, so moving it would break them for no gain. The
	// message names both.
	if (!has_mac && !has_macs && !has_duid)
		push(errs, { field: "mac", code: "required",
		             message: "either macs (for DHCPv4) or duid (for DHCPv6) is required" });

	if (has_mac && !match(json.mac, MAC_RE))
		push(errs, { field: "mac", code: "invalid_format",
		             message: "must be a MAC address like 00:11:22:33:44:55" });

	for (let i = 0; i < length(macs); i++) {
		if (!match(macs[i], MAC_RE))
			push(errs, { field: sprintf("macs[%d]", i), code: "invalid_format",
			             message: "must be a MAC address like 00:11:22:33:44:55" });
	}

	for (let i = 0; i < length(aliases); i++) {
		if (!match(aliases[i], MAC_RE))
			push(errs, { field: sprintf("mac_aliases[%d]", i),
			             code: "invalid_format",
			             message: "must be a MAC address like 00:11:22:33:44:55" });
	}

	// `macs` is the whole uci `list mac`; `mac` and `mac_aliases` are its head and tail.
	// toUci prefers `macs`, so a body whose names disagree had half of itself discarded on
	// a 200. Agreement is accepted, which is what a faithful GET-then-PUT sends, and PUT
	// resolves the disagreement in resolve_for_replace before reaching here.
	if (has_macs) {
		if (has_mac && json.mac != macs[0])
			push(errs, { field: "mac", code: "conflict",
			             message: sprintf("conflicts with macs[0] (%J): both name the same "
			                              + "uci option, so send one or the other", macs[0]) });
		if (length(aliases) > 0 && !equal_list(aliases, slice(macs, 1)))
			push(errs, { field: "mac_aliases", code: "conflict",
			             message: sprintf("conflicts with the tail of macs (%J): both name "
			                              + "the same uci option, so send one or the other",
			                              slice(macs, 1)) });
	}

	// `mac` and `mac_aliases` are two wire names for one uci `list mac`: the scalar is its
	// first entry and the array is the rest. Aliases without a primary describe a list with
	// no head, which toUci cannot write, so it wrote nothing at all and answered 200 with
	// the MACs discarded. Writing them as the list instead would answer a different request
	// than the one sent, since `mac` would come back non-null.
	//
	// Reported against mac_aliases rather than mac: a second mac/required error would
	// collide with the identifier one above under the field|code dedup in
	// _validate_with_schema, and one of the two would silently disappear.
	if (!has_macs && length(aliases) > 0 && !has_mac)
		push(errs, { field: "mac_aliases", code: "conflict",
		             message: "cannot be sent without mac: both name the same uci list option, and mac is its first entry" });

	if (has_duid && !match(json.duid, DUID_RE))
		push(errs, { field: "duid", code: "invalid_format",
		             message: "must be a hex string (optionally colon-separated)" });

	if (json.hostid != null && json.hostid != ""
	    && !match(json.hostid, IPV6_HOSTID_RE))
		push(errs, { field: "hostid", code: "invalid_format",
		             message: "must be an IPv6 host id like ::42" });

	if (json.ip != null && json.ip != "" && !is_valid_ip(json.ip))
		push(errs, { field: "ip", code: "invalid_format",
		             message: "must be a valid IPv4 or IPv6 address" });

	if (json.leasetime != null && !match(json.leasetime, LEASETIME_RE))
		push(errs, { field: "leasetime", code: "invalid_format",
		             message: "must look like 12h, 30m, 1d, or a plain number of seconds" });

	if (conn != null && json.instance != null && json.instance != "") {
		if (!dnsmasq_instance_exists(conn, json.instance))
			push(errs, { field: "instance", code: "conflict",
			             message: sprintf("no dhcp/dnsmasq section named %J exists",
			                              json.instance) });
	}

	return errs;
}

return {
	package: "dhcp",
	type: "host",
	reload: ["dnsmasq"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	merge_for_patch: merge_for_patch,
	resolve_for_replace: resolve_for_replace,
	openapi_singular: "DHCP host",
	openapi_conditional: [
		{ anyOf: [
		    { required: ["macs"] },
		    { required: ["mac"] },
		    { required: ["duid"] },
		  ] },
	],
	schema_properties: {
		macs:        { type: "array", items: { type: "string" },
		               description: "MAC addresses for this reservation (the uci list mac). "
		                            + "Wins over mac and mac_aliases when non-empty." },
		mac:         { type: ["string", "null"], pattern: "^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$",
		               deprecated: true,
		               description: "Deprecated, removed in v3: use macs. First entry of the "
		                            + "uci list mac. macs wins when both are sent." },
		mac_aliases: { type: "array", items: { type: "string" },
		               deprecated: true,
		               description: "Deprecated, removed in v3: use macs. Entries of the uci "
		                            + "list mac after the first. macs wins when both are sent." },
		duid:        { type: ["string", "null"],
		               description: "Client DUID for DHCPv6 reservation" },
		hostid:      { type: ["string", "null"],
		               description: "Static IPv6 host id hint (suffix)" },
		ip:          { type: "string", description: "IPv4 or IPv6 address" },
		leasetime:   { type: ["string", "null"],
		               description: "Duration like '12h', '30m', '1d', or plain seconds" },
		broadcast:   { type: "boolean",
		               description: "Force broadcast replies for clients that need it" },
		instance:    { type: ["string", "null"],
		               description: "Pin this reservation to a specific dhcp/dnsmasq instance (section name)" },
		name:          { type: ["string", "null"],
		               description: "Hostname dnsmasq answers for this reservation" },
		// The union is temporary, and it is the honest shape until v3. dnsmasq
		// word-splits whatever it reads, so `option tag 'a b'` and `list tag` are
		// the same configuration to it and uci holds either; a scalar therefore
		// reads back as a string and a list as an array. Writes persist the shape
		// they were given rather than normalizing, so a body written back
		// unchanged stays unchanged. v3 narrows the read to an array by splitting
		// a stored scalar, which is why storage does not have to converge first.
		// See docs/deprecations.md.
		tag:           { type: ["string", "array", "null"], items: { type: "string" },
		               description: "dnsmasq tags for this reservation; a request must match all of them. Send an array. A space-separated string is accepted on write and reads back as one, which v3 removes: the field becomes array-only. Not flagged `deprecated`, because the field survives and only the string form goes away. See docs/deprecations.md" },
		// Untyped until 2.5.0, so `dns: "0"` was a truthy string that wrote dns=1,
		// the inverse of the request. dnsmasq reads this with the shell config_get_bool,
		// which accepts the wide spelling set, so normalize_bool stays the reader.
		dns:           { type: "boolean", default: false,
		               description: "Answer DNS queries for this reservation's hostname" },
	},
};
