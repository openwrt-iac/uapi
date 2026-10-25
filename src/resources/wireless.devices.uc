let values = require('values');
let platform_bool = values.platform_bool;
let as_int = values.as_int;

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
		radio: as_int(section.radio),
		band: section.band ?? null,
		channel: (section.channel == "auto" || section.channel == null)
		         ? section.channel : as_int(section.channel),
		htmode: section.htmode ?? null,
		// Stock x86 ships country='' (unset); coerce empty to null so the read
		// view is clean and the country pattern check below never sees ''.
		country: (section.country == null || section.country == "") ? null : section.country,
		txpower: as_int(section.txpower),
		cell_density: as_int(section.cell_density) ?? 0,
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

function validate(json) {
	let errs = [];

	if (values.require_present(errs, json, "type")
	    && !VALID_TYPES[json.type])
		push(errs, { field: "type", code: "not_in_enum",
		             message: "must be one of mac80211, broadcom" });

	if (json.band != null && !VALID_BANDS[json.band])
		push(errs, { field: "band", code: "not_in_enum",
		             message: "must be one of 2g, 5g, 6g, 60g" });

	return errs;
}

return {
	package: "wireless",
	type: "wifi-device",
	reload: ["network"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "wireless device",
	openapi_required: ["type"],
	schema_properties: {
		type:     { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_TYPES) },
		path:     { type: ["string", "null"],
		            description: "Device path of the phy under /sys/devices, as `wifi config` writes it. With `phy`, what binds this section to its hardware: wifi-scripts brings up no radio that neither one matches" },
		phy:      { type: ["string", "null"],
		            description: "Name of the phy, as in board.json. `wifi config` writes it instead of `path` when the phy is not named phyN" },
		radio:    { type: ["integer", "null"], minimum: 0,
		            description: "Index of the radio on a phy that has several, as `wifi config` writes it" },
		band:     { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_BANDS) },
		channel:  { "x-uapi-read-nullable": true, type: ["integer", "string"], minimum: 0, maximum: 196,
		            pattern: "^auto$",
		            description: "Channel number (0-196) or the string \"auto\"" },
		htmode:   { type: ["string", "null"],
		            description: "HT/VHT/HE mode label (e.g. HT20, VHT80, HE160)" },
		country:  { type: ["string", "null"], pattern: "^([A-Za-z]{2}|00)$",
		            description: "ISO 3166-1 alpha-2 regulatory country code, or \"00\" for the world/global domain (stock 6 GHz default)" },
		txpower:  { type: ["integer", "null"], minimum: 0, maximum: 30,
		            description: "TX power in dBm" },
		cell_density: { type: "integer", minimum: 0, maximum: 3, default: 0,
		            description: "Basic rates by coverage cell density: 0 disabled, 1 normal, 2 high, 3 very high" },
		legacy_rates: { type: "boolean", default: false,
		            description: "Allow the legacy 802.11b rates" },
		disabled: { type: "boolean", default: false,
		            description: "Disable this radio at boot" },
	},
};
