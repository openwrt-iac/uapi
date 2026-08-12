// inet_pton parses an octet with base 0, so a zero-padded one is either octal
// or unparseable: firewall4 fails to read 010.0.0.1, falls through to a uci
// network-name lookup, resolves nothing and discards the whole section. Same
// reasoning as the protocol-number spelling in proto_problem.
const IPV4_RE = /^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$/;
const IPV6_GROUP_RE = /^[0-9a-fA-F]{1,4}$/;
const CIDR_RE = /^[0-9]{1,3}(\.[0-9]{1,3}){3}\/[0-9]{1,2}$/;

function normalize_bool(v, default_val) {
	if (v == null) return default_val;
	if (v === true || v === "1" || v === "on" || v === "true" || v === "yes")
		return true;
	if (v === false || v === "0" || v === "off" || v === "false" || v === "no")
		return false;
	return default_val;
}

// netifd converts uci strings to blob booleans through uci's own converter,
// which accepts only "1"/"true" and "0"/"false" and DROPS the option for
// anything else, so the daemon falls back to its own default. Reading such a
// field with normalize_bool reports the operator's intent instead of what
// netifd will do: `option auto 'no'` read back as false while the interface
// autostarts. The default passed here must therefore be the daemon's default,
// not a uapi-chosen one.
//
// Only for fields netifd parses, which is both the C daemon and its ucode side
// (`parse_bool` in /lib/netifd/utils.uc, which governs wireless). Every other
// reader accepts a wider set; see the table in docs/ucode-quirks.md and pick the
// helper from it rather than defaulting to normalize_bool.
function platform_bool(v, default_val) {
	if (v === true || v === "1" || v === "true") return true;
	if (v === false || v === "0" || v === "false") return false;
	return default_val;
}

// `get_bool` in /lib/functions.sh, which every `config_get_bool` in an init
// script or proto handler goes through. Its set is normalize_bool's plus
// `enabled`/`disabled`, and the two extra spellings are the whole reason this
// exists: reading `option disabled 'enabled'` with the narrower helper reports
// the opposite of what the shell will do.
function shell_bool(v, default_val) {
	if (v === true || v === "1" || v === "on" || v === "true" || v === "yes"
	    || v === "enabled")
		return true;
	if (v === false || v === "0" || v === "off" || v === "false" || v === "no"
	    || v === "disabled")
		return false;
	return default_val;
}

// Options nothing converts, read raw and compared against the literal "1"
// (`[ "$x" != "1" ]`). Everything else, including `true`, is false to that
// reader, so there is no default to pass: absence and `yes` are the same answer.
function strict_bool(v) {
	return v === "1" || v === 1 || v === true;
}

// A value that reaches a line-oriented config file, a shell argument or a stdin prompt cannot
// carry control characters: one embedded newline turns a single value into two lines. That is
// how a feed URL appended a second, attacker-chosen apk repository which every later install
// trusted and no read path showed, since both parsed one line.
function has_control_chars(s) {
	for (let i = 0; i < length(s); i++) {
		let c = ord(substr(s, i, 1));
		if (c < 32 || c == 127) return true;
	}
	return false;
}

function as_list(v) {
	if (v == null) return [];
	if (type(v) == "array") return v;
	return [v];
}

// The read-side sibling. uci cannot store an empty list, so an absent key and an empty one are
// the same state, and `[]` distinguished nothing while forcing every list field to be
// non-nullable. Reading absent as `null` is what lets a list carry `x-uapi-clear-on-omit` and
// lets an IaC client model the field as a plain optional.
//
// Separate from as_list rather than a change to it: 14 call sites pass a caller-supplied value
// rather than a uci key, and there `[]` is right because it means the caller sent nothing to
// iterate, not that the device holds nothing.
function as_list_or_null(v) {
	if (v == null) return null;
	if (type(v) == "array") return length(v) > 0 ? v : null;
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

// A character-class check accepted addresses inet_pton rejects, such as
// ':::::', and refused the embedded-IPv4 form '::ffff:192.168.1.1' that it
// parses. Both directions matter: the first reaches the router and discards a
// section, the second rejects an address the box applies. Structural rather
// than a regex because the real grammar is unreadable as one and its
// quantifiers approach the limit ucode's engine accepts.
function is_valid_ipv6(s) {
	if (type(s) != "string" || s == "" || index(s, ":") == -1) return false;

	let halves = split(s, "::");
	if (length(halves) > 2) return false;

	let count = 0;
	for (let i = 0; i < length(halves); i++) {
		if (halves[i] == "") continue;
		let groups = split(halves[i], ":");
		for (let j = 0; j < length(groups); j++) {
			let g = groups[j];
			// The embedded IPv4 form occupies the final 32 bits, so it is only
			// legal as the last group of the whole address.
			if (index(g, ".") != -1) {
				if (i != length(halves) - 1 || j != length(groups) - 1) return false;
				if (!is_valid_ipv4(g)) return false;
				count += 2;
				continue;
			}
			if (!match(g, IPV6_GROUP_RE)) return false;
			count++;
		}
	}

	return (length(halves) == 2) ? (count <= 7) : (count == 8);
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

// Stock OpenWrt configs ship IPv6 CIDRs in several places
// (mwan3 default_rule_v6's `option dest_ip '::/0'` is the forcing case).
function is_valid_cidr_any(s) {
	return is_valid_cidr(s) || is_valid_ipv6_cidr(s);
}

// Expands an IPv6 address to its full 32 hex digits so two addresses can be
// ordered by plain string comparison, which is all the range check needs. The
// embedded-IPv4 tail has to become two hex groups first: padding it as a group
// would yield '.3.4' and silently misorder the range.
function ipv6_sort_key(s) {
	let dot = index(s, ".");
	if (dot != -1) {
		let cut = 0;
		for (let i = 0; i < dot; i++) if (substr(s, i, 1) == ":") cut = i;
		let v4 = substr(s, cut + 1);
		if (is_valid_ipv4(v4)) {
			let o = split(v4, ".");
			s = substr(s, 0, cut + 1)
			    + sprintf("%02x%02x:%02x%02x", int(o[0]), int(o[1]), int(o[2]), int(o[3]));
		}
	}

	let head = s, tail = "";
	let dbl = index(s, "::");
	if (dbl != -1) {
		head = substr(s, 0, dbl);
		tail = substr(s, dbl + 2);
	}
	let parts = [];
	for (let g in split(head, ":")) if (g != "") push(parts, g);
	let tailp = [];
	for (let g in split(tail, ":")) if (g != "") push(tailp, g);
	while (length(parts) + length(tailp) < 8) push(parts, "0");
	for (let g in tailp) push(parts, g);
	let out = "";
	for (let g in parts) out += substr("0000" + lc(g), -4);
	return out;
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

// nft caps a comment at 128 bytes and fw4 prefixes every one with "!fw4: ",
// and it caps an interface name at 15. Exceeding either makes nft reject the
// entire ruleset, so these are hard limits rather than style preferences.
const NAME_MAX = 122;
const DEVICE_MAX = 15;

// firewall4 resolves a protocol name or number and firewall4 then renders it
// verbatim as `meta l4proto <token>`. nft resolves that against its OWN built-in
// table, which is narrower than /etc/protocols: ipcomp, l2tp and vrrp all exist
// in /etc/protocols yet nft answers "Could not resolve protocol name", and since
// `nft -f` is atomic one such token rejects the ENTIRE ruleset rather than one
// section. Protocol numbers stop at 255. fw4 lowercases the value and treats
// '*' as a wildcard, so both are accepted here.
const PROTO_NAMES = {
	"tcp": true, "udp": true, "tcpudp": true, "icmp": true, "icmpv6": true,
	"ipv6-icmp": true, "esp": true, "ah": true, "igmp": true, "gre": true,
	"sctp": true, "dccp": true, "udplite": true, "ipip": true, "ipv6": true,
	"ipv6-route": true, "ipv6-frag": true, "ipv6-nonxt": true, "ipv6-opts": true,
	"ospf": true, "pim": true, "rsvp": true, "ipencap": true,
	"any": true, "all": true, "*": true,
};
const PROTO_MAX = 255;

// Shape only, so the spec documents the field; the authoritative check is
// proto_problem, which fw4's case-insensitivity makes awkward to express as a
// pattern (ucode's regex engine has no inline-flag support).
const PROTO_RE = '^!?[A-Za-z0-9*][A-Za-z0-9-]{0,31}$';

function proto_problem(v) {
	if (type(v) != "string") return null;
	// fw4 parses a leading '!' and then drops the invert flag when rendering, so
	// a negated protocol silently becomes a rule matching exactly that protocol.
	if (substr(v, 0, 1) == "!")
		return { code: "invalid_format",
		         message: "firewall4 cannot express a negated protocol" };
	let s = lc(v);
	if (s == "") return { code: "invalid_format", message: "must not be empty" };
	if (PROTO_NAMES[s]) return null;
	// nft parses a protocol number with base 0, so a leading zero means octal:
	// 08 and 09 are unresolvable and fail the whole ruleset, while 017 quietly
	// becomes 15. Only a canonical decimal spelling is safe.
	if (match(s, /^(0|[1-9][0-9]{0,2})$/)) {
		if (+s <= PROTO_MAX) return null;
		return { code: "out_of_range",
		         message: sprintf("protocol number must not exceed %d", PROTO_MAX) };
	}
	return { code: "invalid_format",
	         message: "must be a protocol name nftables can resolve, or a number 0-255" };
}

// firewall4 parses a port as a single number or a min-max / min:max range,
// each endpoint within 0..65535 and the range ordered; match options may be
// negated with a leading '!', target options such as snat_port may not. Shared
// so the three firewall resources cannot drift from what the router accepts.
const PORT_RE = '^[0-9]{1,5}([-:][0-9]{1,5})?$';
const PORT_MATCH_RE = '^!?[0-9]{1,5}([-:][0-9]{1,5})?$';
const PORT_MAX = 65535;
const PORT_CRE = regexp(PORT_RE);
const PORT_MATCH_CRE = regexp(PORT_MATCH_RE);

// A port fw4 cannot parse makes it discard the whole section, so passing one
// through would be a silent no-op.
function port_problem(v, allow_invert) {
	if (type(v) != "string") return null;
	if (v == "") return { code: "invalid_format", message: "must not be empty" };

	if (!match(v, allow_invert ? PORT_MATCH_CRE : PORT_CRE))
		return { code: "invalid_format",
		         message: allow_invert
		             ? "must be a port or port range (e.g. 80, 1000-2000, 1000:2000), optionally negated with a leading '!'"
		             : "must be a port or port range (e.g. 80, 1000-2000, 1000:2000)" };

	let bounds = [];
	for (let part in split(replace(v, /^!/, ""), /[-:]/)) push(bounds, +part);
	for (let n in bounds) {
		if (n > PORT_MAX)
			return { code: "out_of_range",
			         message: sprintf("port %d exceeds the maximum of %d", n, PORT_MAX) };
	}
	if (length(bounds) == 2 && bounds[0] > bounds[1])
		return { code: "out_of_range", message: "port range start must not exceed its end" };

	return null;
}

// firewall4 types its address options as `network`, resolving a host address,
// addr/prefixlen, addr/netmask, an addr-addr range, or a uci network name, any
// of them optionally negated. Validating these as bare IPv4 rejects working
// configuration; accepting anything lets a typo reach the router, where fw4
// discards the whole section. So check only the forms we can tell apart: a
// value that looks like an address is validated as one, and a bare word is
// left for fw4 to resolve as a network name.
function address_problem(v) {
	let bad = { code: "invalid_format",
	            message: "must be an address, a prefix, an address range, or a uci network name" };

	if (type(v) != "string") return null;
	if (v == "") return bad;

	let s = replace(v, /^!/, "");
	if (s == "") return bad;

	if (index(s, ".") == -1 && index(s, ":") == -1 && index(s, "/") == -1)
		return match(s, /^[A-Za-z0-9][A-Za-z0-9_-]*$/) ? null : bad;

	// fw4's parse_subnet splits on '/' first, so a mask may not appear inside a
	// range, and a range has exactly two endpoints of the same family.
	let ends = split(s, "-");
	if (length(ends) > 2) return bad;
	if (length(ends) == 2) {
		for (let e in ends) if (!is_valid_ip(e)) return bad;
		if (is_valid_ipv4(ends[0]) != is_valid_ipv4(ends[1])) return bad;
		// nft rejects a descending range with "Range negative size", and because
		// nft -f is atomic that takes the whole ruleset with it. Both families
		// behave the same way, so compare v6 as an expanded hex string rather
		// than checking only the v4 case.
		let lo = ends[0], hi = ends[1];
		let descending = is_valid_ipv4(lo)
			? (ipv4_to_int(lo) > ipv4_to_int(hi))
			: (ipv6_sort_key(lo) > ipv6_sort_key(hi));
		if (descending)
			return { code: "out_of_range",
			         message: "address range start must not exceed its end" };
		return null;
	}

	if (is_valid_ip(s) || is_valid_cidr_any(s)) return null;

	// addr/netmask, which fw4 accepts alongside addr/prefixlen
	let seg = split(s, "/");
	if (length(seg) == 2 && is_valid_ip(seg[0]) && is_valid_ip(seg[1])
	    && is_valid_ipv4(seg[0]) == is_valid_ipv4(seg[1]))
		return null;
	return bad;
}

// firewall4 supports a non-contiguous mask on a MATCH address, rendering it as
// `saddr & <mask> == <addr>`, but discards the section outright when one
// appears in an address it has to rewrite to: a DNAT dest_ip, an SNAT src_dip,
// or snat_ip. Mirrors fw4's to_bits returning -1. A prefix length cannot be
// non-contiguous, so only the addr/netmask form is examined.
function has_noncontiguous_mask(v) {
	if (type(v) != "string") return false;

	let seg = split(replace(v, /^!/, ""), "/");
	if (length(seg) != 2) return false;

	let hex;
	if (is_valid_ipv4(seg[1])) {
		hex = "";
		for (let o in split(seg[1], ".")) hex += sprintf("%02x", int(o));
	}
	else if (is_valid_ipv6(seg[1])) hex = ipv6_sort_key(seg[1]);
	else return false;

	let seen_zero = false;
	for (let i = 0; i < length(hex); i++) {
		let n = index("0123456789abcdef", substr(hex, i, 1));
		for (let b = 3; b >= 0; b--) {
			if ((n >> b) & 1) {
				if (seen_zero) return true;
			}
			else seen_zero = true;
		}
	}
	return false;
}

// firewall4 wires src_port and dest_port into a rule only inside its
// `case "tcp": case "udp":` branch, so a port beside any other protocol is
// dropped and the rule is still emitted, matching the whole protocol instead of
// the port asked for. That is a widening rather than a no-op, which is why it
// has to fail validation. `config nat` is the one place a lone wildcard is
// safe: ensure_tcpudp rewrites it to tcp+udp before the ports are read.
const TCPUDP = { "tcp": true, "6": true, "udp": true, "17": true, "tcpudp": true };
const PROTO_WILDCARD = { "any": true, "all": true, "*": true };

function port_proto_conflict(protos, wildcard_rewrites) {
	if (length(protos) == 0) return false;

	let all_tcpudp = true, all_wildcard = true;
	for (let p in protos) {
		let lp = (type(p) == "string") ? lc(p) : null;
		if (lp == null || !TCPUDP[lp]) all_tcpudp = false;
		if (lp == null || !PROTO_WILDCARD[lp]) all_wildcard = false;
	}

	return !(all_tcpudp || (wildcard_rewrites && all_wildcard));
}

// uci cannot store an empty option value, so a field set to "" is a field the daemon
// will never see: absent and empty are the same condition, and every resource spelled
// that out per field. Pushing rather than returning a problem, unlike the value helpers
// above, because the answer is about a field's absence and there is nothing to inspect.
function require_present(errs, obj, field, wire_name) {
	let v = obj[field];
	if (v != null && v != "") return true;
	push(errs, { field: wire_name ?? field, code: "required", message: "is required" });
	return false;
}

// One walk instead of twelve. Resources each had their own uci_foreach to answer "does a
// section with this name exist", differing only in which key identifies it (`.name` for
// the section name, an option name where the daemon keys on a value) and whether a second
// option has to match. Returns a set so a caller checking several values walks once.
function section_index(conn, pkg, sec_type, key, filter) {
	let out = {};
	// Callers reach validate() with a null conn from the unit suite, and several of the
	// walks this replaces carried their own guard for it.
	if (conn == null) return out;
	conn.uci_foreach(pkg, sec_type, function(s) {
		if (filter != null && !filter(s)) return;
		let k = s[key];
		if (k != null && k != "") out[k] = true;
	});
	return out;
}

return {
	normalize_bool, platform_bool,
	shell_bool,
	strict_bool, as_list, as_list_or_null, as_int,
	has_control_chars,
	require_present, section_index,
	MARK_RE, MARK_MATCH_RE, MARK_MAX, masked_value_exceeds,
	PORT_RE, PORT_MATCH_RE, PORT_MAX, port_problem,
	PROTO_RE, PROTO_MAX, proto_problem, port_proto_conflict,
	NAME_MAX, DEVICE_MAX,
	address_problem, has_noncontiguous_mask,
	is_valid_ipv4, is_valid_ipv6, is_valid_ip, is_valid_cidr, is_valid_ipv6_cidr, is_valid_cidr_any,
	ipv4_in_cidr, ipv4_in_any_cidr, normalize_addr,
	constant_time_equals,
	LINE_RE, MAX_LINE_LEN, check_lines,
};
