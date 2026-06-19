let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;

const VALID_TYPES = { "mac80211": true, "broadcom": true };
const VALID_BANDS = { "2g": true, "5g": true, "6g": true, "60g": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		type: section.type ?? null,
		band: section.band ?? null,
		channel: (section.channel == "auto" || section.channel == null)
		         ? section.channel : as_int(section.channel),
		htmode: section.htmode ?? null,
		country: section.country ?? null,
		txpower: as_int(section.txpower),
		disabled: normalize_bool(section.disabled, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.type != null) out.type = json.type;
	if (json.band != null) out.band = json.band;
	if (json.channel != null) out.channel = "" + json.channel;
	if (json.htmode != null) out.htmode = json.htmode;
	if (json.country != null) out.country = json.country;
	if (json.txpower != null) out.txpower = "" + json.txpower;
	if (json.disabled != null) out.disabled = json.disabled ? "1" : "0";
	return out;
}

function validate(json) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type", message: "body must be a JSON object" });
		return errs;
	}

	if (json.type == null || json.type == "")
		push(errs, { field: "type", code: "required", message: "is required" });
	else if (!VALID_TYPES[json.type])
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
		type:     { type: "string", enum: keys(VALID_TYPES) },
		band:     { type: "string", enum: keys(VALID_BANDS) },
		channel:  { type: ["integer", "string"], minimum: 0, maximum: 196,
		            pattern: "^auto$",
		            description: "Channel number (0-196) or the string \"auto\"" },
		htmode:   { type: ["string", "null"],
		            description: "HT/VHT/HE mode label (e.g. HT20, VHT80, HE160)" },
		country:  { type: ["string", "null"], pattern: "^[A-Za-z]{2}$",
		            description: "ISO 3166-1 alpha-2 regulatory country code" },
		txpower:  { type: ["integer", "null"], minimum: 0, maximum: 30,
		            description: "TX power in dBm" },
		disabled: { type: "boolean", default: false,
		            description: "Disable this radio at boot" },
	},
};
