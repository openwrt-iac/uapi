let values = require('values');
let platform_bool = values.platform_bool;
let as_int = values.as_int;

const VALID_MODES = {
	"ap": true, "sta": true, "adhoc": true, "wds": true, "monitor": true, "mesh": true,
};
const VALID_ENCRYPTION = {
	"none": true, "wep": true, "owe": true,
	"psk": true, "psk2": true, "psk-mixed": true,
	"sae": true, "sae-mixed": true,
	"wpa": true, "wpa2": true, "wpa3": true, "wpa3-mixed": true,
};
// LuCI appends a forced cipher, as in psk2+ccmp, to these modes of the enum, and
// parse_encryption in wifi-scripts also reads the older aes spellings.
const CIPHER_MODES = [ "psk", "psk2", "psk-mixed", "sae", "wpa", "wpa2", "wpa3", "wpa3-mixed" ];
const CIPHERS = [ "ccmp", "ccmp256", "gcmp", "gcmp256", "tkip", "tkip+ccmp",
                  "aes", "tkip+aes", "aes+tkip", "ccmp+tkip" ];
for (let m in CIPHER_MODES)
	for (let c in CIPHERS)
		VALID_ENCRYPTION[m + "+" + c] = true;
// Encryption modes that take no passphrase. owe (Opportunistic Wireless
// Encryption) is keyless and is the stock default on 6 GHz radios.
const NO_KEY_ENCRYPTION = { "none": true, "wep": true, "owe": true };
const KEY_ENCRYPTION = filter(keys(VALID_ENCRYPTION), (e) => !NO_KEY_ENCRYPTION[e]);
// The modes whose key wifi-scripts passes as a WPA passphrase or PSK. It refuses any other
// length with INVALID_WPA_PSK and the SSID stays down, as LuCI's wpakey check says.
const PASSPHRASE_MODES = { "psk": true, "psk2": true, "psk-mixed": true, "sae": true, "sae-mixed": true };

// wifi-scripts copies key, nasid, r0kh and r1kh into hostapd's config with append(), which does
// not escape, so a newline in one of them starts a hostapd directive of the writer's choice. A
// token scoped to wireless interfaces set a key that ended in `\nssid2="x"`, and hostapd
// broadcast x while every read still showed the old SSID.
//
// hostapd refuses its whole config for one bad key holder entry. wifi-scripts turns the commas
// into the spaces that add_r0kh() and add_r1kh() split on, so an R0KH-ID cannot hold either, and
// add_r0kh() takes at most 47 bytes of it. The key is 64 hex digits, or 32 in the older form.
const MAC = "[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}";
const RKH_KEY = "([0-9A-Fa-f]{32}){1,2}";
const R0KH_PATTERN = "^" + MAC + ",[!-+.-~-]{1,47}," + RKH_KEY + "$";
const R1KH_PATTERN = "^" + MAC + "," + MAC + "," + RKH_KEY + "$";
const KEY_HOLDERS = {
	r0kh: { re: regexp(R0KH_PATTERN),
	        message: "must be <MAC>,<R0KH-ID>,<key>: a MAC address with colons, an R0KH-ID of 1 to 47 printable characters with no space or comma, and 64 or 32 hex digits" },
	r1kh: { re: regexp(R1KH_PATTERN),
	        message: "must be <MAC>,<R1KH-ID>,<key>: two MAC addresses with colons, and 64 or 32 hex digits" },
};
// hostapd refuses a NAS identifier longer than 48 bytes when 802.11r is on.
const NASID_MAX = 48;

function lookup_ifname(conn, section_name) {
	let status = null;
	try { status = conn.call("network.wireless", "status"); }
	catch (e) { return null; }
	if (type(status) != "object") return null;
	// Match on the authoritative i.section field. Two ifaces on different radios
	// can share an SSID (dual-band networks), so SSID is not a safe fallback.
	// An iface that hasn't been provisioned yet has no i.section entry and
	// genuinely has no runtime; returning null and emitting runtime: {} is
	// the correct behavior.
	for (let radio_name in status) {
		let radio = status[radio_name];
		let ifaces = (type(radio) == "object") ? radio.interfaces : null;
		if (type(ifaces) != "array") continue;
		for (let i in ifaces)
			if (i.section == section_name) return i.ifname ?? null;
	}
	return null;
}

function fetch_runtime(conn, section_name) {
	if (conn == null) return {};
	let ifname = lookup_ifname(conn, section_name);
	if (ifname == null) return {};
	let info = null, assoc = null;
	try { info = conn.call("iwinfo", "info", { device: ifname }); }
	catch (e) {}
	try { assoc = conn.call("iwinfo", "assoclist", { device: ifname }); }
	catch (e) {}
	let out = { ifname: ifname };
	if (type(info) == "object") {
		out.bssid          = info.bssid ?? null;
		out.channel        = info.channel ?? null;
		out.frequency      = info.frequency ?? null;
		out.signal         = info.signal ?? null;
		out.noise          = info.noise ?? null;
		out.txpower_actual = info.txpower ?? null;
	}
	if (type(assoc) == "object" && type(assoc.results) == "array")
		out.assoclist_count = length(assoc.results);
	return out;
}

function fromUci(section, conn) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		device: section.device ?? null,
		network: section.network ?? null,
		mode: section.mode ?? "ap",
		ssid: section.ssid ?? null,
		encryption: section.encryption ?? "none",
		disabled: platform_bool(section.disabled, false),
		hidden: platform_bool(section.hidden, false),
		isolate: platform_bool(section.isolate, false),
		ieee80211r: platform_bool(section.ieee80211r, false),
		ft_over_ds: platform_bool(section.ft_over_ds, false),
		ft_psk_generate_local: platform_bool(section.ft_psk_generate_local, null),
		mobility_domain: section.mobility_domain ?? null,
		nasid: section.nasid ?? null,
		reassociation_deadline: as_int(section.reassociation_deadline),
		r0_key_lifetime: as_int(section.r0_key_lifetime),
		r1_key_holder: section.r1_key_holder ?? null,
		pmk_r1_push: platform_bool(section.pmk_r1_push, false),
		// Each r0kh and r1kh entry ends with the key that the key holders share, so the
		// lists are write-only like `key`, and a PUT of the read keeps them.
		has_r0kh: section.r0kh != null,
		has_r1kh: section.r1kh != null,
		runtime: fetch_runtime(conn, section['.name']),
		// Always present, and an empty key is not a key. The published schema declares
		// a non-nullable boolean, so the previous absent-or-true form meant a keyless
		// section violated the spec this server ships. Same shape as every sibling
		// write-only flag (openvpn.instances, network.wireguard_peers).
		has_key: (section.key != null && section.key != ""),
	};
}

function toUci(json) {
	let out = {};
	if (json.device != null) out.device = json.device;
	if (json.network != null) out.network = json.network;
	if (json.mode != null) out.mode = json.mode;
	if (json.ssid != null) out.ssid = json.ssid;
	if (json.encryption != null) out.encryption = json.encryption;
	if (json.key != null) out.key = json.key;
	if (json.disabled != null) out.disabled = json.disabled ? "1" : "0";
	if (json.hidden != null) out.hidden = json.hidden ? "1" : "0";
	if (json.isolate != null) out.isolate = json.isolate ? "1" : "0";
	if (json.ieee80211r != null) out.ieee80211r = json.ieee80211r ? "1" : "0";
	if (json.ft_over_ds != null) out.ft_over_ds = json.ft_over_ds ? "1" : "0";
	if (json.ft_psk_generate_local != null)
		out.ft_psk_generate_local = json.ft_psk_generate_local ? "1" : "0";
	if (json.mobility_domain != null) out.mobility_domain = json.mobility_domain;
	if (json.nasid != null) out.nasid = json.nasid;
	if (json.reassociation_deadline != null) out.reassociation_deadline = "" + json.reassociation_deadline;
	if (json.r0_key_lifetime != null) out.r0_key_lifetime = "" + json.r0_key_lifetime;
	if (json.r1_key_holder != null) out.r1_key_holder = json.r1_key_holder;
	if (json.pmk_r1_push != null) out.pmk_r1_push = json.pmk_r1_push ? "1" : "0";
	if (json.r0kh != null) out.r0kh = json.r0kh;
	if (json.r1kh != null) out.r1kh = json.r1kh;
	return out;
}

// The key and the key holder lists are write-only, so a PUT carries the stored ones into json.
// Only what the request sent is checked, or a stored value that a write cannot read back would
// refuse every later write of the section.
function validate(json, conn, id, delta) {
	let errs = [];
	let named = delta ?? json;

	values.require_present(errs, json, "device");

	if (json.mode != null && !VALID_MODES[json.mode])
		push(errs, { field: "mode", code: "not_in_enum",
		             message: "must be one of ap, sta, adhoc, wds, monitor, mesh" });

	if (json.encryption != null && !VALID_ENCRYPTION[json.encryption])
		push(errs, { field: "encryption", code: "not_in_enum",
		             message: "unknown encryption value" });

	let needs_key = json.encryption != null && !NO_KEY_ENCRYPTION[json.encryption];
	if (needs_key && (json.key == null || json.key == ""))
		push(errs, { field: "key", code: "required",
		             message: sprintf("is required when encryption is %J", json.encryption) });

	let key = named.key;
	let base_mode = (type(json.encryption) == "string") ? split(json.encryption, "+")[0] : null;
	if (type(key) == "string" && key != "") {
		if (values.has_control_chars(key))
			push(errs, { field: "key", code: "invalid_format",
			             message: "must not contain a control character: wifi-scripts writes it into hostapd's config as one line" });
		else if (PASSPHRASE_MODES[base_mode]
		         && (length(key) < 8 || length(key) > 64
		             || (length(key) == 64 && !match(key, /^[0-9A-Fa-f]+$/))))
			push(errs, { field: "key", code: "invalid_format",
			             message: sprintf("must be 8 to 63 bytes, or 64 hex digits, when encryption is %J", json.encryption) });
	}

	if (type(named.nasid) == "string") {
		if (values.has_control_chars(named.nasid))
			push(errs, { field: "nasid", code: "invalid_format",
			             message: "must not contain a control character: wifi-scripts writes it into hostapd's config as one line" });
		else if (length(named.nasid) > NASID_MAX)
			push(errs, { field: "nasid", code: "out_of_range",
			             message: sprintf("must be at most %d bytes: hostapd refuses a longer NAS identifier for 802.11r", NASID_MAX) });
	}

	// Each entry ends with the key that the key holders share, so no message names it.
	for (let field, kh in KEY_HOLDERS) {
		if (type(named[field]) != "array") continue;
		for (let i = 0; i < length(named[field]); i++)
			if (type(named[field][i]) == "string" && !match(named[field][i], kh.re))
				push(errs, { field: sprintf("%s[%d]", field, i), code: "invalid_format",
				             message: kh.message });
	}

	return errs;
}

return {
	package: "wireless",
	type: "wifi-iface",
	reload: ["network"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "wireless interface",
	openapi_required: ["device"],
	openapi_conditional: [
		{ if:   { properties: { encryption: { enum: KEY_ENCRYPTION } },
		          required: ["encryption"] },
		  then: { required: ["key"] } },
	],
	openapi_runtime: {
		type: "object",
		description: "Populated from ubus iwinfo info/assoclist for the runtime interface that backs this uci section; empty {} when the iface has not been provisioned yet.",
		properties: {
			ifname:          { type: "string" },
			bssid:           { type: ["string", "null"] },
			channel:         { type: ["integer", "null"] },
			frequency:       { type: ["integer", "null"] },
			signal:          { type: ["integer", "null"] },
			noise:           { type: ["integer", "null"] },
			txpower_actual:  { type: ["integer", "null"] },
			assoclist_count: { type: "integer", minimum: 0 },
		},
	},
	schema_properties: {
		device:     { "x-uapi-read-nullable": true, type: "string",
		              description: "Parent radio (wireless/devices id)" },
		network:    { type: ["string", "null"],
		              description: "Network interface this SSID bridges into" },
		mode:       { type: "string", enum: keys(VALID_MODES), default: "ap" },
		ssid:       { type: ["string", "null"],
		              description: "SSID broadcast (or joined in sta mode)" },
		encryption: { type: "string", enum: keys(VALID_ENCRYPTION), default: "none" },
		key:        { type: "string", writeOnly: true,
		              description: "Encryption passphrase; accepted on write, masked on read. Required when `encryption` is a PSK variant and no key is stored yet, which validate() enforces; it is not a schema conditional because a read-modify-write body cannot carry a masked field. A key that a write sends has no control character, and with psk, psk2, psk-mixed, sae or sae-mixed it is 8 to 63 bytes or 64 hex digits, which is what wifi-scripts accepts" },
		has_key:    { type: "boolean", readOnly: true,
		              description: "True if a key is configured (cleartext never returned)" },
		disabled:   { type: "boolean", default: false,
		              description: "Disable this iface at boot" },
		hidden:     { type: "boolean", default: false,
		              description: "Suppress SSID in beacon frames" },
		isolate:    { type: "boolean", default: false,
		              description: "Block station-to-station traffic on this AP" },
		ieee80211r: { type: "boolean", default: false,
		              description: "802.11r fast BSS transition between the access points of one mobility domain" },
		ft_over_ds: { type: "boolean", default: false,
		              description: "802.11r over the distribution system instead of over the air" },
		ft_psk_generate_local: { "x-uapi-read-nullable": true, type: "boolean",
		              description: "Generate the 802.11r keys locally instead of using the R0/R1 key holders. Unset means true when `encryption` is psk2 or psk-mixed, with or without a forced cipher, and false otherwise. 802.11r needs WPA2 or later, so plain psk gets no fast transition at all" },
		mobility_domain: { type: ["string", "null"], pattern: "^[0-9A-Fa-f]{4}$",
		              description: "802.11r mobility domain, 4 hex digits. Unset, wifi-scripts derives it from the SSID" },
		nasid:      { type: ["string", "null"], "x-uapi-write": { maxLength: NASID_MAX },
		              description: sprintf("802.11r NAS identifier of this access point, which wifi-scripts passes to hostapd as nas_identifier. Unset, hostapd uses the BSSID without colons. A write takes at most %d bytes with no control character", NASID_MAX) },
		reassociation_deadline: { type: ["integer", "null"], minimum: 1000, maximum: 65535,
		              description: "802.11r reassociation deadline in time units of 1.024 ms. Unset, wifi-scripts uses 20000" },
		r0_key_lifetime: { type: ["integer", "null"], minimum: 0,
		              description: "802.11r lifetime of the PMK-R0 in minutes. Unset, hostapd uses 14 days (20160 minutes). 0 turns the timeout off" },
		r1_key_holder: { type: ["string", "null"], pattern: "^[0-9A-Fa-f]{12}$",
		              description: "802.11r R1 key holder id, 12 hex digits. Unset, hostapd derives it from the BSSID" },
		pmk_r1_push: { type: "boolean", default: false,
		              description: "Push the PMK-R1 to the other key holders instead of waiting for them to pull it" },
		r0kh:       { type: "array", items: { type: "string", "x-uapi-write": { pattern: R0KH_PATTERN } }, writeOnly: true,
		              description: "802.11r R0 key holders as `<MAC>,<NAS id>,<key>` entries; accepted on write, masked on read, and kept by a PUT that leaves it out. Unset with ft_psk_generate_local off, wifi-scripts derives one entry from the mobility domain and the key" },
		has_r0kh:   { type: "boolean", readOnly: true,
		              description: "True if r0kh is configured (the entries are never returned)" },
		r1kh:       { type: "array", items: { type: "string", "x-uapi-write": { pattern: R1KH_PATTERN } }, writeOnly: true,
		              description: "802.11r R1 key holders as `<MAC>,<R1KH id>,<key>` entries; accepted on write, masked on read, and kept by a PUT that leaves it out" },
		has_r1kh:   { type: "boolean", readOnly: true,
		              description: "True if r1kh is configured (the entries are never returned)" },
	},
};
