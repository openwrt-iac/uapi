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

// Single-line passthrough validation shared by resources that mirror
// unbound-uci-ext's seam-file generator. The regex pattern uses a literal
// newline in the character class because ucode's regex parser treats `\n`
// inside `[...]` as the two characters `\` and `n`, not as a newline
// escape (see project memory: project-ucode-quirks). The 256-char ceiling
// lives in code below because ucode's regex engine rejects `{m,n}` when
// `n > 255`. MAX_LINE_LEN matches unbound-uci-ext's generator.sh; changing
// here without changing there desyncs validation.
const LINE_RE = "^[^\n]+$";
const MAX_LINE_LEN = 256;

function check_lines(field, value, errs) {
	if (type(value) != "array") return;
	for (let i = 0; i < length(value); i++) {
		if (type(value[i]) == "string" && length(value[i]) > MAX_LINE_LEN)
			push(errs, { field: sprintf("%s[%d]", field, i),
			             code: "invalid_format",
			             message: sprintf("must be 1..%d characters with no newline", MAX_LINE_LEN) });
	}
}

// uci stores everything as strings; the curated layer wants real numeric
// values for fields declared `type: "integer"`. Returns null on missing or
// non-numeric input to avoid the silent int("abc") = 0 trap.
function as_int(v) {
	if (v == null) return null;
	if (type(v) == "int") return v;
	if (type(v) == "string" && v != "" && match(v, /^-?[0-9]+$/))
		return int(v);
	return null;
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

function is_valid_ipv6_cidr(s) {
	if (type(s) != "string" || index(s, "/") == -1) return false;
	let parts = split(s, "/");
	if (length(parts) != 2 || !is_valid_ipv6(parts[0])) return false;
	let prefix = int(parts[1]);
	return prefix >= 0 && prefix <= 128;
}

// is_valid_cidr_any accepts both IPv4 (a.b.c.d/N) and IPv6 (xxxx::/N) CIDR
// notation. Stock OpenWrt configs ship IPv6 CIDRs in several places
// (mwan3 default_rule_v6's `option dest_ip '::/0'` is the forcing case).
function is_valid_cidr_any(s) {
	return is_valid_cidr(s) || is_valid_ipv6_cidr(s);
}

function ipv4_to_int(s) {
	let parts = split(s, ".");
	let n = 0;
	for (let p in parts) n = (n * 256) + int(p);
	return n;
}

function ipv4_in_cidr(addr, cidr) {
	if (!is_valid_ipv4(addr) || !is_valid_cidr(cidr)) return false;
	let parts = split(cidr, "/");
	let net = ipv4_to_int(parts[0]);
	let prefix = int(parts[1]);
	if (prefix == 0) return true;
	let mask = (-1 << (32 - prefix)) & 0xFFFFFFFF;
	return (ipv4_to_int(addr) & mask) == (net & mask);
}

// Strips IPv4-mapped-in-IPv6 prefix when a sockaddr_in6 produced ::ffff:1.2.3.4.
function normalize_addr(addr) {
	if (type(addr) != "string") return null;
	if (substr(addr, 0, 7) == "::ffff:") return substr(addr, 7);
	return addr;
}

function ipv4_in_any_cidr(addr, cidr_list) {
	let a = normalize_addr(addr);
	if (a == null) return false;
	if (type(cidr_list) != "array") return false;
	for (let c in cidr_list) {
		if (ipv4_in_cidr(a, c)) return true;
	}
	return false;
}

// Byte-XOR-accumulate compare; runtime depends on the shorter length only,
// not on where the first mismatching byte sits. Length difference folds into
// the accumulator so unequal-length inputs always differ. Required for
// closing the timing channel in auth's hash compare (see docs/security.md).
function constant_time_equals(a, b) {
	if (type(a) != "string" || type(b) != "string") return false;
	let la = length(a), lb = length(b);
	let n = (la < lb) ? la : lb;
	let acc = la ^ lb;
	for (let i = 0; i < n; i++)
		acc |= ord(substr(a, i, 1)) ^ ord(substr(b, i, 1));
	return acc == 0;
}

// firewall4 accepts a mark as value[/mask] in decimal or 0x-prefixed hex, and
// lets match options negate with a leading '!'. Shared by every resource that
// exposes a mark, so the accepted syntax cannot drift between them.
const MARK_VALUE = '(0[xX][0-9a-fA-F]{1,8}|[0-9]{1,10})';
const MARK_RE = '^' + MARK_VALUE + '(/' + MARK_VALUE + ')?$';
const MARK_MATCH_RE = '^!?' + MARK_VALUE + '(/' + MARK_VALUE + ')?$';
const MARK_MAX = 0xFFFFFFFF;

// The pattern constrains digit count, not magnitude: a 10-digit decimal still
// overflows 32 bits, and a 2-digit DSCP still exceeds 63. Components that are
// not numeric (symbolic DSCP names like EF) coerce to NaN and are ignored.
function masked_value_exceeds(v, max) {
	if (type(v) != "string" || v == "") return false;
	for (let part in split(replace(v, /^!/, ""), "/")) {
		let n = +part;
		if (n != n) continue;
		if (n < 0 || n > max) return true;
	}
	return false;
}

return {
	normalize_bool, as_list, as_int,
	MARK_RE, MARK_MATCH_RE, MARK_MAX, masked_value_exceeds,
	is_valid_ipv4, is_valid_ipv6, is_valid_ip, is_valid_cidr, is_valid_ipv6_cidr, is_valid_cidr_any,
	ipv4_in_cidr, ipv4_in_any_cidr, normalize_addr,
	constant_time_equals,
	LINE_RE, MAX_LINE_LEN, check_lines,
};
