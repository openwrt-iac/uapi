let values = require('values');
let platform_bool = values.platform_bool;
let as_int = values.as_int;

const VALID_MODES = {
	"ap": true, "sta": true, "adhoc": true, "wds": true, "monitor": true, "mesh": true,
};
// In these modes mac80211.sh can pass the SSID to wdev.uc inside a single-quoted shell
// argument, and the JSON encoding leaves a single quote as it is.
const SHELL_SSID_MODES = { "monitor": true, "adhoc": true, "mesh": true };
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
// wifi-scripts copies key, nasid, the 802.11r options and the key holder lists into the daemon's
// config without escaping, so a newline in one of them starts a directive of the writer's choice.
// A token scoped to wireless interfaces set a key that ended in `\nssid2="x"`, and hostapd
// broadcast x while every read still showed the old SSID.
const ONE_LINE = "must not contain a newline: wifi-scripts writes it into the daemon's config as one line";
// hostapd reads its config 4096 bytes at a time and takes the rest of a longer line as a line of
// its own, which is the same injection without a newline.
const LINE_MAX = 1024;
const TOO_LONG = sprintf("must be at most %d bytes: wifi-scripts writes it as one line of hostapd's config, and hostapd starts a new line after 4095 bytes", LINE_MAX);

// hostapd refuses its whole config for one key holder entry that it cannot parse, and takes any
// entry that it can. wifi-scripts turns the first two commas into the spaces that add_r0kh() and
// add_r1kh() split on, and leaves an entry already in hostapd's own form, with spaces, as it is.
// hwaddr_aton() reads a MAC address and ignores what follows it, add_r0kh() takes an R0KH-ID of at
// most 47 bytes, and rkh_derive_key() reads 64 hex digits, or 32 in the older form, and ignores
// the rest.
const RKH_MAC = values.MAC_PATTERN + "[^ ,]*";
const R0KH_PATTERN = "^" + RKH_MAC + "[ ,][^ ,]{0,47}[ ,][0-9A-Fa-f]{32}";
const R1KH_PATTERN = "^" + RKH_MAC + "[ ,]" + RKH_MAC + "[ ,][0-9A-Fa-f]{32}";
const KEY_HOLDERS = {
	r0kh: { re: regexp(R0KH_PATTERN),
	        message: "must be <MAC>,<R0KH-ID>,<key> as hostapd reads it: a MAC address with colons, an R0KH-ID of at most 47 bytes with no space or comma, and a key that starts with 32 or 64 hex digits" },
	r1kh: { re: regexp(R1KH_PATTERN),
	        message: "must be <MAC>,<R1KH-ID>,<key> as hostapd reads it: two MAC addresses with colons, and a key that starts with 32 or 64 hex digits" },
};
// hostapd refuses a NAS identifier longer than 48 bytes when it runs a fast transition key
// management.
const NASID_MAX = 48;

// The modes whose key wifi-scripts writes as a line: a passphrase or a PSK for hostapd, or a psk or
// sae_password for wpa_supplicant.
const KEY_LINE_MODES = { "psk": true, "psk2": true, "psk-mixed": true, "sae": true, "sae-mixed": true };

function base_encryption(e) {
	return (type(e) == "string") ? split(e, "+")[0] : "none";
}

// iface_roaming() in wifi-scripts runs in mode ap from WPA2 up, and writes the key holder lists
// only when ft_psk_generate_local is off, which is its default for every mode but psk, psk2 and
// psk-mixed. owe gets no fast transition key management, so hostapd does not cap its nasid. A
// section with no mode reads as mode ap, as fromUci() reads it.
const BELOW_WPA2 = { "none": true, "wep": true, "psk": true, "wpa": true };
// With fils, which uapi does not model, ap.uc writes mobility_domain as erp_domain on an EAP SSID.
const EAP = { "wpa": true, "wpa2": true, "wpa3": true, "wpa3-mixed": true };
const LOCAL_FT_KEYS = { "psk": true, "psk2": true, "psk-mixed": true };
const ROAMING_ENCRYPTION = filter(keys(VALID_ENCRYPTION), (e) => !BELOW_WPA2[base_encryption(e)]);
const FT_ENCRYPTION = filter(ROAMING_ENCRYPTION, (e) => base_encryption(e) != "owe");
function roaming(v) {
	let base = base_encryption(v.encryption);
	let on = (v.mode ?? "ap") == "ap" && v.ieee80211r === true && !BELOW_WPA2[base];
	return { roams: on, ft: on && base != "owe",
	         key_holders: on && !(v.ft_psk_generate_local ?? LOCAL_FT_KEYS[base] ?? false) };
}

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

function validate(json, conn, id, delta) {
	let errs = [];

	values.require_present(errs, json, "device");

	if (json.mode != null && !VALID_MODES[json.mode])
		push(errs, { field: "mode", code: "not_in_enum",
		             message: "must be one of ap, sta, adhoc, wds, monitor, mesh" });

	// Only a write that names ssid or mode checks the pair, as the schema checks only what a
	// body sends, so a stored SSID does not block a write that disables its interface.
	let named = delta ?? json;
	if ((exists(named, "ssid") || exists(named, "mode"))
	    && SHELL_SSID_MODES[json.mode] && type(json.ssid) == "string" && index(json.ssid, "'") >= 0)
		push(errs, { field: "ssid", code: "invalid_format",
		             message: sprintf("must not hold a single quote in mode %s", json.mode) });

	if (json.encryption != null && !VALID_ENCRYPTION[json.encryption])
		push(errs, { field: "encryption", code: "not_in_enum",
		             message: "unknown encryption value" });

	let needs_key = json.encryption != null && !NO_KEY_ENCRYPTION[json.encryption];
	if (needs_key && (json.key == null || json.key == ""))
		push(errs, { field: "key", code: "required",
		             message: sprintf("is required when encryption is %J", json.encryption) });

	return errs;
}

// The rules on what wifi-scripts writes into the daemon's config as lines. Another writer, such as
// LuCI, can enable the SSID or change its mode or encryption later, so an error is reported
// whether the daemon reads the value now or not, and marked `live: false` when it does not: the
// SSID is disabled, or its mode or encryption does not use the field. See new_errors() in the
// handler. Only a newline ends a line in hostapd's and wpa_supplicant's config readers, and each
// problem is its own error, so that one cannot hide another.
function validate_new(json) {
	let errs = [];
	let on = json.disabled !== true;
	let mode = json.mode ?? "ap";
	let r = roaming(json);
	let err = (field, code, message, live) => push(errs, { field, code, message, live: !!live });
	// wifi-scripts writes a list that uci holds for a text option as its entries joined by spaces.
	// A list key gets there only on an access point with 8 to 64 entries: ap.uc counts entries as
	// bytes, and supplicant.uc writes a list as JSON, which escapes a newline.
	let text = (v) => (type(v) == "array") ? join(" ", v) : v;
	let n = length(json.key);
	let key = (type(json.key) != "array") ? json.key : (mode == "ap" && n >= 8 && n <= 64) ? text(json.key) : null;
	let nasid = text(json.nasid);
	let md = text(json.mobility_domain), r1 = text(json.r1_key_holder);
	let line = function(field, v, live) {
		if (length(v) > LINE_MAX) err(field, "out_of_range", TOO_LONG, live);
		if (index(v, "\n") >= 0) err(field, "invalid_format", ONE_LINE, live);
	};

	if (type(key) == "string" && index(key, "\n") >= 0)
		err("key", "invalid_format", ONE_LINE,
		    on && KEY_LINE_MODES[base_encryption(json.encryption)] && (mode in [ "ap", "sta", "adhoc", "mesh" ]));

	if (type(md) == "string")
		line("mobility_domain", md, on && (r.roams || (mode == "ap" && EAP[base_encryption(json.encryption)])));
	if (type(r1) == "string") line("r1_key_holder", r1, on && r.key_holders);

	if (type(nasid) == "string") {
		line("nasid", nasid, on && mode == "ap");
		if (r.ft && length(nasid) > NASID_MAX)
			err("nasid", "out_of_range",
			    sprintf("must be at most %d bytes with 802.11r on: hostapd refuses a longer NAS identifier for fast transition", NASID_MAX), on);
	}

	// Each entry ends with the key that the key holders share, so no message names it. uci can
	// hold a list as an option, which netifd splits on every whitespace, a newline included, with
	// no trim, so a leading space gives an empty entry. hostapd reads the lists only with fast
	// transition and ft_psk_generate_local off, so the grammar applies only then.
	for (let field, kh in KEY_HOLDERS) {
		let v = json[field];
		let list = (type(v) == "string") ? split(v, /\s+/) : (type(v) == "array") ? v : [];
		for (let i = 0; i < length(list); i++) {
			let e = list[i], f = sprintf("%s[%d]", field, i);
			if (type(e) != "string") continue;
			line(f, e, on && r.key_holders);
			if (r.key_holders && !match(e, kh.re)) err(f, "invalid_format", kh.message, on);
		}
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
	validate_new: validate_new,
	openapi_singular: "wireless interface",
	openapi_required: ["device"],
	openapi_conditional: [
		{ if:   { properties: { encryption: { enum: KEY_ENCRYPTION } },
		          required: ["encryption"] },
		  then: { required: ["key"] } },
	],
	openapi_write_conditional: [
		{ if:   { properties: { mode: { const: "ap" }, ieee80211r: { const: true }, encryption: { enum: FT_ENCRYPTION } },
		          required: [ "ieee80211r", "encryption" ] },
		  then: { properties: { nasid: { maxLength: NASID_MAX } } } },
		{ if:   { properties: { mode: { const: "ap" }, ieee80211r: { const: true }, encryption: { enum: ROAMING_ENCRYPTION },
		                        ft_psk_generate_local: { const: false } },
		          required: [ "ieee80211r", "encryption", "ft_psk_generate_local" ] },
		  then: { properties: { r0kh: { items: { pattern: R0KH_PATTERN } }, r1kh: { items: { pattern: R1KH_PATTERN } } } } },
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
		              description: "SSID broadcast (or joined in sta mode). In mode monitor, adhoc or mesh, it must not hold a single quote" },
		encryption: { type: "string", enum: keys(VALID_ENCRYPTION), default: "none" },
		key:        { type: "string", writeOnly: true,
		              description: "Encryption passphrase; accepted on write, masked on read. Required when `encryption` is a PSK variant and no key is stored yet, which validate() enforces; it is not a schema conditional because a read-modify-write body cannot carry a masked field. A key with a newline is refused, because wifi-scripts writes it into the daemon's config as one line. A write that leaves the key as it is is refused for the newline only when it enables the SSID or changes its mode or encryption" },
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
		nasid:      { type: ["string", "null"], "x-uapi-write": { maxLength: LINE_MAX },
		              description: sprintf("NAS identifier of this access point, which wifi-scripts passes to hostapd as nas_identifier in mode ap: the 802.11r R0KH-ID, and the RADIUS NAS-Identifier. Unset, hostapd uses the BSSID without colons. A write refuses a newline and more than %d bytes, and more than %d with fast transition, which needs mode ap, ieee80211r and WPA2 or later other than owe. A write that leaves nasid as it is is refused for a problem that nasid already had only when it enables the SSID or changes its mode, encryption or ieee80211r. uapi counts bytes, so a non-ASCII character counts for more than one. Another access point can list it in r0kh only with at most 47 bytes and no space or comma", LINE_MAX, NASID_MAX) },
		reassociation_deadline: { type: ["integer", "null"], minimum: 1000, maximum: 65535,
		              description: "802.11r reassociation deadline in time units of 1.024 ms. Unset, wifi-scripts uses 20000" },
		r0_key_lifetime: { type: ["integer", "null"], minimum: 0,
		              description: "802.11r lifetime of the PMK-R0 in minutes. Unset, hostapd uses 14 days (20160 minutes). 0 turns the timeout off" },
		r1_key_holder: { type: ["string", "null"], pattern: "^[0-9A-Fa-f]{12}$",
		              description: "802.11r R1 key holder id, 12 hex digits. Unset, hostapd derives it from the BSSID" },
		pmk_r1_push: { type: "boolean", default: false,
		              description: "Push the PMK-R1 to the other key holders instead of waiting for them to pull it" },
		r0kh:       { type: "array", items: { type: "string", "x-uapi-write": { maxLength: LINE_MAX } }, writeOnly: true,
		              description: "802.11r R0 key holders as `<MAC>,<NAS id>,<key>` entries; accepted on write, masked on read, and kept by a PUT that leaves it out. An entry takes no newline and at most 1024 bytes, and while hostapd reads the lists, the form that hostapd parses. Unset with ft_psk_generate_local off, wifi-scripts derives one entry from the mobility domain and the key" },
		has_r0kh:   { type: "boolean", readOnly: true,
		              description: "True if r0kh is configured (the entries are never returned)" },
		r1kh:       { type: "array", items: { type: "string", "x-uapi-write": { maxLength: LINE_MAX } }, writeOnly: true,
		              description: "802.11r R1 key holders as `<MAC>,<R1KH id>,<key>` entries; accepted on write, masked on read, and kept by a PUT that leaves it out. An entry takes no newline and at most 1024 bytes, and while hostapd reads the lists, the form that hostapd parses" },
		has_r1kh:   { type: "boolean", readOnly: true,
		              description: "True if r1kh is configured (the entries are never returned)" },
	},
};
