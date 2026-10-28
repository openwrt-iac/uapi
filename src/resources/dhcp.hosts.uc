let values = require('values');
let shell_bool = values.shell_bool;
let is_valid_ip = values.is_valid_ip;

const LEASETIME_RE = /^[0-9]+[smhdwMY]?$/;
const DUID_RE = /^[0-9A-Fa-f]{2}([:]?[0-9A-Fa-f]{2})+$/;
const IPV6_HOSTID_RE = /^[0-9A-Fa-f:]+$/;

// Splitting a stored scalar on read is what settles the wire shape; a read never touches storage.
// A write does converge it, since toUci hands uci the array and uci stores a list, so the
// first write-back turns `option tag 'a b'` into `list tag`. That is safe here only
// because the view is stable across it: dnsmasq treats the two identically, and a body
// read and written back unchanged reads back unchanged, which is what read honesty asks.
// The earlier design refused to normalize on write for that reason and then kept the raw
// shape on read too, which is the part that did not follow.
let split_tags = values.as_word_list_or_null;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		// dnsmasq.init reads `mac` with config_get and splits it into words: see config_get_words().
		macs: values.config_get_words(section.mac),
		duid: section.duid ?? null,
		hostid: section.hostid ?? null,
		ip: section.ip ?? null,
		leasetime: section.leasetime ?? null,
		tag: split_tags(section.tag),
		// dnsmasq's init script reads match_tag with config_list_foreach, which skips a scalar
		// option, so only the list form filters anything (measured: `option match_tag 'x'`
		// compiles to a host line with no tag). Reporting a scalar as a filter would claim a
		// restriction dnsmasq does not apply, and writing that read back would turn it on.
		match_tag: (type(section.match_tag) == "array") ? section.match_tag : null,
		dns: shell_bool(section.dns, false),
		broadcast: (section.broadcast != null) ? shell_bool(section.broadcast, false) : null,
		instance: section.instance ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;

	// uci cannot hold a one-element list distinctly from a scalar, so a single mac is
	// written as a scalar and read back through config_get_words as a one-element array.
	if (type(json.macs) == "array" && length(json.macs) > 0)
		out.mac = (length(json.macs) > 1) ? json.macs : json.macs[0];

	if (json.duid != null)      out.duid = json.duid;
	if (json.hostid != null)    out.hostid = json.hostid;
	if (json.ip != null)        out.ip = json.ip;
	if (json.leasetime != null) out.leasetime = json.leasetime;
	if (type(json.tag) == "array" && length(json.tag) > 0) out.tag = json.tag;
	else if (json.tag != null && type(json.tag) != "array") out.tag = json.tag;
	if (type(json.match_tag) == "array" && length(json.match_tag) > 0) out.match_tag = json.match_tag;
	if (json.dns != null)       out.dns = json.dns ? "1" : "0";
	if (json.broadcast != null) out.broadcast = json.broadcast ? "1" : "0";
	if (json.instance != null)  out.instance = json.instance;
	return out;
}

function validate(json, conn) {
	let errs = [];

	let macs = (type(json.macs) == "array") ? json.macs : [];
	let has_macs = length(macs) > 0;
	let has_duid = json.duid != null && json.duid != "";

	if (!has_macs && !has_duid)
		push(errs, { field: "macs", code: "required",
		             message: "either macs (for DHCPv4) or duid (for DHCPv6) is required" });

	for (let i = 0; i < length(macs); i++) {
		if (!match(macs[i], values.MAC_RE))
			push(errs, { field: sprintf("macs[%d]", i), code: "invalid_format",
			             message: "must be a MAC address like 00:11:22:33:44:55" });
	}

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

	// name, tag and match_tag all land in the one dhcp-host line the init script writes.
	for (let field in ["tag", "match_tag"]) {
		let items = (field == "tag") ? split_tags(json.tag) : json.match_tag;
		if (type(items) != "array") continue;
		for (let i = 0; i < length(items); i++) {
			let p = (type(items[i]) == "string") ? values.dnsmasq_value_problem(items[i]) : null;
			if (p != null)
				push(errs, { field: sprintf("%s[%d]", field, i), code: "invalid_format", message: p });
		}
	}
	if (type(json.name) == "string" && json.name != "") {
		let p = values.dnsmasq_value_problem(json.name);
		if (p != null) push(errs, { field: "name", code: "invalid_format", message: p });
	}

	if (json.leasetime != null && !match(json.leasetime, LEASETIME_RE))
		push(errs, { field: "leasetime", code: "invalid_format",
		             message: "must look like 12h, 30m, 1d, or a plain number of seconds" });

	// `dhcp.host.instance` references a dnsmasq instance (the dhcp.dnsmasq section
	// name), not a per-interface dhcp.dhcp section. dnsmasq's init reads
	// config_get_bool ... "$instance" against `config dnsmasq` entries.
	if (conn != null && json.instance != null && json.instance != "") {
		if (values.section_index(conn, 'dhcp', 'dnsmasq', '.name')[json.instance] == null)
			push(errs, { field: "instance", code: "conflict",
			             message: sprintf("no dhcp/dnsmasq section named %J exists",
			                              json.instance) });
	}

	return errs;
}

return {
	package: "dhcp",
	type: "host",
	// dnsmasq treats two dhcp-host entries sharing an IP as fatal, not as something to
	// ignore: it logs "duplicate dhcp-host IP address" and refuses to start, so the box loses
	// DNS and DHCP until one is removed. Measured on a device, where the second reservation
	// answered 200 and the daemon was gone three seconds later.
	//
	// A host with several NICs is one reservation carrying several `macs`, which dnsmasq
	// accepts and which keeps running, so nothing legitimate needs two reservations on one
	// address. Reservations with no `ip` are untouched: check_unique_field skips a value that
	// is not a non-empty string.
	unique_field: "ip",
	reload: ["dnsmasq"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "DHCP host",
	openapi_conditional: [
		{ anyOf: [
		    { required: ["macs"] },
		    { required: ["duid"] },
		  ] },
	],
	schema_properties: {
		macs:        { type: ["array", "null"], items: { type: "string" },
		               description: "MAC addresses for this reservation, the whole uci `list mac`." },
		duid:        { type: ["string", "null"],
		               description: "Client DUID for DHCPv6 reservation" },
		hostid:      { type: ["string", "null"],
		               description: "Static IPv6 host id hint (suffix)" },
		ip:          { "x-uapi-read-nullable": true, type: "string", description: "IPv4 or IPv6 address" },
		leasetime:   { type: ["string", "null"],
		               description: "Duration like '12h', '30m', '1d', or plain seconds" },
		broadcast:   { "x-uapi-read-nullable": true, type: "boolean",
		               description: "Force broadcast replies for clients that need it" },
		instance:    { type: ["string", "null"],
		               description: "Pin this reservation to a specific dhcp/dnsmasq instance (section name)" },
		name:          { type: ["string", "null"],
		               description: "Hostname dnsmasq answers for this reservation. A comma, a double quote, a `#` or a control character is refused, because the name goes into dnsmasq's config line." },
		tag:           { type: ["array", "null"], items: { type: "string" },
		                 description: "dnsmasq tags set on a request this reservation matches, for other options to match on (LuCI's Set Tag). A stored `option tag 'a b'` reads back as an array, because dnsmasq word-splits it the same way. A comma, a double quote, a `#` or a control character is refused." },
		match_tag:     { type: ["array", "null"], items: { type: "string" },
		                 description: "dnsmasq tags a request must carry for this reservation to apply (LuCI's Match Tag), the uci `list match_tag`; `!` negates. Only a tag dnsmasq sets from the request before it looks up hosts can match, such as one from a `config vendorclass`, `config userclass` or `config mac` rule. `known` and the DHCP range's own tag are set later, so `known` never matches and `!known` always does (measured on dnsmasq 2.93). A scalar `option match_tag` reads as null, because dnsmasq ignores it. A comma, a double quote, a `#`, a control character or a blank value is refused." },
		// Untyped until 2.5.0, so `dns: "0"` was a truthy string that wrote dns=1,
		// the inverse of the request. dnsmasq reads this with the shell config_get_bool,
		// which accepts the wide spelling set, so normalize_bool stays the reader.
		dns:           { type: "boolean", default: false,
		               description: "Answer DNS queries for this reservation's hostname" },
	},
};
