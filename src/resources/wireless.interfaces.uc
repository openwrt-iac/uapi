const VALID_MODES = {
	"ap": true, "sta": true, "adhoc": true, "wds": true, "monitor": true, "mesh": true,
};
const VALID_ENCRYPTION = {
	"none": true, "wep": true,
	"psk": true, "psk2": true, "psk-mixed": true,
	"sae": true, "sae-mixed": true,
	"wpa": true, "wpa2": true, "wpa3": true, "wpa3-mixed": true,
};

function normalize_bool(v, default_val) {
	if (v == null) return default_val;
	if (v === true || v === "1" || v === "on" || v === "true" || v === "yes")
		return true;
	if (v === false || v === "0" || v === "off" || v === "false" || v === "no")
		return false;
	return default_val;
}

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	let view = {
		id: section['.name'],
		managed: !anonymous,
		device: section.device ?? null,
		network: section.network ?? null,
		mode: section.mode ?? "ap",
		ssid: section.ssid ?? null,
		encryption: section.encryption ?? "none",
		disabled: normalize_bool(section.disabled, false),
		hidden: normalize_bool(section.hidden, false),
		isolate: normalize_bool(section.isolate, false),
		runtime: {},
	};
	if (section.key != null) view.has_key = true;
	return view;
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
	return out;
}

function validate(json) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type", message: "body must be a JSON object" });
		return errs;
	}

	if (json.device == null || json.device == "")
		push(errs, { field: "device", code: "required", message: "is required" });

	if (json.mode != null && !VALID_MODES[json.mode])
		push(errs, { field: "mode", code: "not_in_enum",
		             message: "must be one of ap, sta, adhoc, wds, monitor, mesh" });

	if (json.encryption != null && !VALID_ENCRYPTION[json.encryption])
		push(errs, { field: "encryption", code: "not_in_enum",
		             message: "unknown encryption value" });

	let needs_key = json.encryption != null && json.encryption != "none" && json.encryption != "wep";
	if (needs_key && (json.key == null || json.key == ""))
		push(errs, { field: "key", code: "required",
		             message: sprintf("is required when encryption is %J", json.encryption) });

	return errs;
}

return {
	package: "wireless",
	type: "wifi-iface",
	reload: ["network"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		mode: { type: "string", enum: keys(VALID_MODES) },
		encryption: { type: "string", enum: keys(VALID_ENCRYPTION) },
		key: { type: "string", writeOnly: true,
		       description: "Encryption passphrase; accepted on write, masked on read" },
		has_key: { type: "boolean", readOnly: true,
		           description: "True if a key is configured (cleartext never returned)" },
	},
	merge_for_patch: function(existing_section, existing_json, body) {
		let merged = { ...existing_json };
		for (let k in body) {
			if (type(merged[k]) == "object" && type(body[k]) == "object")
				merged[k] = { ...merged[k], ...body[k] };
			else
				merged[k] = body[k];
		}
		if (body.key == null && existing_section.key != null)
			merged.key = existing_section.key;
		return merged;
	},
};
