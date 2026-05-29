const IPV4_RE = /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/;
const IPV6_RE = /^[0-9a-fA-F:]+$/;
const CIDR_RE = /^[0-9]{1,3}(\.[0-9]{1,3}){3}\/[0-9]{1,2}$/;

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

function is_valid_ipv4(s) {
	if (type(s) != "string" || !match(s, IPV4_RE)) return false;
	for (let part in split(s, ".")) {
		let n = int(part);
		if (n < 0 || n > 255) return false;
	}
	return true;
}

function is_valid_ipv6(s) {
	return type(s) == "string" && s != "" && !!match(s, IPV6_RE);
}

function is_valid_ip(s) {
	if (type(s) != "string" || s == "") return false;
	if (index(s, ":") != -1) return is_valid_ipv6(s);
	return is_valid_ipv4(s);
}

function is_valid_cidr(s) {
	if (type(s) != "string" || !match(s, CIDR_RE)) return false;
	let parts = split(s, "/");
	if (!is_valid_ipv4(parts[0])) return false;
	let prefix = int(parts[1]);
	return prefix >= 0 && prefix <= 32;
}

return {
	normalize_bool, as_list,
	is_valid_ipv4, is_valid_ip, is_valid_cidr,
};
