const VALID_TYPES = {
	"bridge": true, "8021q": true, "8021ad": true, "macvlan": true,
	"veth": true, "tun": true, "tap": true,
};

function normalize_bool(v, default_val) {
	if (v == null) return default_val;
	if (v === true || v === "1" || v === "on" || v === "true" || v === "yes")
		return true;
	if (v === false || v === "0" || v === "off" || v === "false" || v === "no")
		return false;
	return default_val;
}

function as_list(v) {
	if (v == null) return [];
	if (type(v) == "array") return v;
	return [v];
}

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		type: section.type ?? null,
		ports: as_list(section.ports),
		vid: section.vid ?? null,
		ifname: section.ifname ?? null,
		mtu: section.mtu ?? null,
		macaddr: section.macaddr ?? null,
		ipv6: normalize_bool(section.ipv6, true),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;
	if (json.type != null) out.type = json.type;
	if (type(json.ports) == "array" && length(json.ports) > 0) out.ports = json.ports;
	if (json.vid != null) out.vid = "" + json.vid;
	if (json.ifname != null) out.ifname = json.ifname;
	if (json.mtu != null) out.mtu = "" + json.mtu;
	if (json.macaddr != null) out.macaddr = json.macaddr;
	if (json.ipv6 != null) out.ipv6 = json.ipv6 ? "1" : "0";
	return out;
}

function validate(json) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type", message: "body must be a JSON object" });
		return errs;
	}

	if (json.name == null || json.name == "")
		push(errs, { field: "name", code: "required", message: "is required" });

	if (json.type == null || json.type == "")
		push(errs, { field: "type", code: "required", message: "is required" });
	else if (!VALID_TYPES[json.type])
		push(errs, { field: "type", code: "not_in_enum",
		             message: "must be one of bridge, 8021q, 8021ad, macvlan, veth, tun, tap" });

	if (json.type == "bridge" && (type(json.ports) != "array" || length(json.ports) == 0))
		push(errs, { field: "ports", code: "required",
		             message: "is required when type is bridge" });

	if (json.type == "8021q" && (json.vid == null || json.vid == ""))
		push(errs, { field: "vid", code: "required",
		             message: "is required when type is 8021q" });

	return errs;
}

return {
	package: "network",
	type: "device",
	reload: ["network"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
};
