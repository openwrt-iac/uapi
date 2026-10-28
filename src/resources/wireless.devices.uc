let values = require('values');
let platform_bool = values.platform_bool;
let ucode_int = values.ucode_int;

const VALID_TYPES = { "mac80211": true, "broadcom": true };
const VALID_BANDS = { "2g": true, "5g": true, "6g": true, "60g": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		type: section.type ?? null,
		path: section.path ?? null,
		phy: section.phy ?? null,
		macaddr: section.macaddr ?? null,
		// netifd converts a number option with `+v`, and mac80211.sh converts `channel` the same way
		// after `auto`, so these read the number that wifi-scripts uses: see values.ucode_int().
		radio: ucode_int(section.radio),
		band: section.band ?? null,
		channel: (section.channel == "auto" || section.channel == null)
		         ? section.channel : ucode_int(section.channel),
		htmode: section.htmode ?? null,
		// Stock x86 ships country='' (unset); coerce empty to null so the read
		// view is clean and the country pattern check below never sees ''.
		country: (section.country == null || section.country == "") ? null : section.country,
		txpower: ucode_int(section.txpower),
		cell_density: ucode_int(section.cell_density) ?? 0,
		legacy_rates: platform_bool(section.legacy_rates, false),
		disabled: platform_bool(section.disabled, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.type != null) out.type = json.type;
	if (json.path != null) out.path = json.path;
	if (json.phy != null) out.phy = json.phy;
	if (json.macaddr != null) out.macaddr = json.macaddr;
	if (json.radio != null) out.radio = "" + json.radio;
	if (json.band != null) out.band = json.band;
	if (json.channel != null) out.channel = "" + json.channel;
	if (json.htmode != null) out.htmode = json.htmode;
	if (json.country != null) out.country = json.country;
	if (json.txpower != null) out.txpower = "" + json.txpower;
	if (json.cell_density != null) out.cell_density = "" + json.cell_density;
	if (json.legacy_rates != null) out.legacy_rates = json.legacy_rates ? "1" : "0";
	if (json.disabled != null) out.disabled = json.disabled ? "1" : "0";
	return out;
}

// Beside this file: src/resources in the tests, /usr/share/uapi/resources on the router.
const IFACES = sourcepath(0, true) + "/wireless.interfaces.uc";

// wifi-scripts sets up the enabled SSIDs of a radio that a write turns on, so a value that
// wireless/interfaces refuses on one of them goes live with this write. The view masks the
// write-only fields, which the rules check, so they come from uci as on a write. A message never
// quotes a value, because the key and the key holder lists are secrets.
function ssid_errors(conn, radio) {
	// loadfile compiles in the mode of the running program, which is a template under uhttpd.
	let wiface = loadfile(IFACES, { raw_mode: true })();
	let out = [];
	conn.uci_foreach("wireless", "wifi-iface", function(s) {
		if (index(wiface.radios(s.device), radio) < 0) return;
		let view = wiface.fromUci(s, null);
		for (let k, p in wiface.schema_properties)
			if (p.writeOnly && s[k] != null) view[k] = s[k];
		let fields = uniq(map(filter(wiface.rules(view, true), (e) => e.live), (e) => e.field));
		if (length(fields) > 0) push(out, sprintf("%s (%s)", s['.name'], join(", ", fields)));
	});
	return out;
}

function validate(json, conn, id) {
	let errs = [];

	if (values.require_present(errs, json, "type")
	    && !VALID_TYPES[json.type])
		push(errs, { field: "type", code: "not_in_enum",
		             message: "must be one of mac80211, broadcom" });

	if (json.band != null && !VALID_BANDS[json.band])
		push(errs, { field: "band", code: "not_in_enum",
		             message: "must be one of 2g, 5g, 6g, 60g" });

	// netifd sets up no SSID of a radio that is disabled or has no type, so a write that gives a
	// radio its type turns it on as surely as one that enables it.
	let name = id ?? json.id;
	if (conn == null || name == null || json.disabled === true || type(json.type) != "string" || json.type == "") return errs;
	// Validation runs before the write is staged, so uci still holds the radio as it was.
	let was = conn.uci_get("wireless", name);
	// Only a create makes a radio that uci does not hold: a PUT or a PATCH of one answers 404.
	let bad = ((was == null && id == null) || (was != null && (platform_bool(was.disabled, false) || type(was.type) != "string" || was.type == "")))
		? ssid_errors(conn, name) : [];
	if (length(bad) > 0)
		push(errs, { field: "disabled", code: "conflict",
		             message: "must be true while an enabled SSID of the radio holds a value that wifi-scripts or a daemon refuses: " + join(", ", bad) });
	return errs;
}

// 6 GHz channels go up to 233. Only cell_density has bounds in the wifi-scripts schema, and
// validate.uc stops the radio for a value outside them, so only its error is live: a radio with a
// stored radio index, channel or power outside the range that a write takes still comes up.
const RANGES = { radio: [ 0, null, false ], channel: [ 0, 233, false ], txpower: [ 0, 30, false ],
                 cell_density: [ 0, 3, true ] };

// A read gives what wifi-scripts reads from the stored text, which can be outside the range that a
// write takes, so a write that leaves such a value as it is passes.
function validate_new(json) {
	let errs = [];
	for (let f, r in RANGES) {
		let v = json[f];
		if (type(v) == "int" && (v < r[0] || (r[1] != null && v > r[1])))
			push(errs, { field: f, code: "out_of_range", live: r[2] && json.disabled !== true && type(json.type) == "string" && json.type != "",
			             message: (r[1] != null) ? sprintf("must be from %d to %d", r[0], r[1])
			                                      : sprintf("must be at least %d", r[0]) });
	}
	return errs;
}

return {
	package: "wireless",
	type: "wifi-device",
	reload: ["network"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	validate_new: validate_new,
	openapi_singular: "wireless device",
	openapi_required: ["type"],
	schema_properties: {
		type:     { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_TYPES) },
		path:     { type: ["string", "null"],
		            description: "Device path of the phy under /sys/devices, as `wifi config` writes it. With `macaddr` and `phy`, what binds this section to its hardware: wifi-scripts tries `path`, then `macaddr`, then `phy`, and brings up no radio that none of them matches" },
		phy:      { type: ["string", "null"],
		            description: "Name of the phy, as in board.json. `wifi config` writes it instead of `path` when the phy is not named phyN" },
		macaddr:  { type: ["string", "null"],
		            description: "MAC address of the phy. Older `wifi detect` configurations bind a radio with it instead of `path`" },
		radio:    { type: ["integer", "null"], "x-uapi-write": { minimum: 0 },
		            description: "Index of the radio on a phy that has several, as `wifi config` writes it" },
		band:     { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_BANDS) },
		channel:  { "x-uapi-read-nullable": true, type: ["integer", "string"], "x-uapi-write": { minimum: 0, maximum: 233 },
		            pattern: "^auto$",
		            description: "Channel number (0-233, where 6 GHz uses up to 233) or the string \"auto\". A stored value reads as the number that wifi-scripts takes from it: ` 6` and `0x6` are 6, a fraction is cut, and other text is 0, which is auto. A write refuses a number outside 0 to 233" },
		htmode:   { type: ["string", "null"],
		            description: "HT/VHT/HE mode label (e.g. HT20, VHT80, HE160)" },
		country:  { type: ["string", "null"], pattern: "^([A-Za-z]{2}|00)$",
		            description: "ISO 3166-1 alpha-2 regulatory country code, or \"00\" for the world/global domain (stock 6 GHz default)" },
		txpower:  { type: ["integer", "null"], "x-uapi-write": { minimum: 0, maximum: 30 },
		            description: "TX power in dBm, from 0 to 30 on write. A stored value reads as wifi-scripts reads it, as for `channel`" },
		cell_density: { type: "integer", "x-uapi-write": { minimum: 0, maximum: 3 }, default: 0,
		            description: "Basic rates by coverage cell density: 0 disabled, 1 normal, 2 high, 3 very high" },
		legacy_rates: { type: "boolean", default: false,
		            description: "Allow the legacy 802.11b rates" },
		disabled: { type: "boolean", default: false,
		            description: "Disable this radio at boot. wifi-scripts sets up no SSID of a disabled radio, or of one without a `type`. A write that turns the radio on, such as a create without `disabled: true` or a write that gives the radio its type, is refused with `conflict` while an enabled SSID of the radio holds a value that wifi-scripts or a daemon refuses, as the fields of wireless/interfaces describe. The error names each such SSID and its fields, and `GET /api/v3/diagnostics?validate=1` lists them. Such a write is also refused for a stored `cell_density` outside 0 to 3, for which wifi-scripts stops the radio" },
	},
};
