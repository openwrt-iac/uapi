let t = require('harness');
let v = require('values');

t.describe('values.normalize_bool', () => {
	t.it('maps uci-true variants to true', () => {
		for (let s in [true, "1", "on", "true", "yes"])
			t.assert_equal(v.normalize_bool(s, false), true);
	});

	t.it('maps uci-false variants to false', () => {
		for (let s in [false, "0", "off", "false", "no"])
			t.assert_equal(v.normalize_bool(s, true), false);
	});

	t.it('returns default for null and unrecognized strings', () => {
		t.assert_equal(v.normalize_bool(null, true), true);
		t.assert_equal(v.normalize_bool(null, false), false);
		t.assert_equal(v.normalize_bool("maybe", true), true);
		t.assert_equal(v.normalize_bool(42, "x"), "x");
	});
});

t.describe('values.as_list', () => {
	t.it('returns the array as-is when already an array', () => {
		t.assert_deep_equal(v.as_list(["a", "b"]), ["a", "b"]);
		t.assert_deep_equal(v.as_list([]), []);
	});

	t.it('wraps a scalar in a one-element list', () => {
		t.assert_deep_equal(v.as_list("x"), ["x"]);
		t.assert_deep_equal(v.as_list(1), [1]);
	});

	t.it('returns an empty list for null', () => {
		t.assert_deep_equal(v.as_list(null), []);
	});
});

t.describe('values.is_valid_ipv4', () => {
	t.it('accepts canonical IPv4', () => {
		for (let s in ["0.0.0.0", "127.0.0.1", "192.168.1.1", "255.255.255.255"])
			t.assert_true(v.is_valid_ipv4(s));
	});

	t.it('rejects out-of-range octets, bad shapes, and non-strings', () => {
		for (let s in ["256.0.0.1", "1.2.3", "1.2.3.4.5", "a.b.c.d", "", null, 1234])
			t.assert_false(v.is_valid_ipv4(s));
	});
});

t.describe('values.is_valid_ip', () => {
	t.it('accepts IPv4 and IPv6', () => {
		t.assert_true(v.is_valid_ip("10.0.0.1"));
		t.assert_true(v.is_valid_ip("fe80::1"));
		t.assert_true(v.is_valid_ip("::1"));
	});

	t.it('rejects garbage', () => {
		t.assert_false(v.is_valid_ip(""));
		t.assert_false(v.is_valid_ip("not-an-ip"));
		t.assert_false(v.is_valid_ip(null));
	});
});

t.describe('values.is_valid_cidr', () => {
	t.it('accepts valid IPv4 CIDR', () => {
		for (let s in ["10.0.0.0/8", "192.168.1.0/24", "0.0.0.0/0", "1.2.3.4/32"])
			t.assert_true(v.is_valid_cidr(s));
	});

	t.it('rejects out-of-range prefix or bad address', () => {
		for (let s in ["10.0.0.0/33", "10.0.0.0/-1", "256.0.0.0/24", "10.0.0.0", "", null])
			t.assert_false(v.is_valid_cidr(s));
	});

	t.it('is IPv4-only (does not accept IPv6 CIDR)', () => {
		t.assert_false(v.is_valid_cidr("::/0"));
		t.assert_false(v.is_valid_cidr("2001:db8::/32"));
	});
});

t.describe('values.is_valid_ipv6_cidr', () => {
	t.it('accepts valid IPv6 CIDR', () => {
		for (let s in ["::/0", "::1/128", "2001:db8::/32", "fe80::/10"])
			t.assert_true(v.is_valid_ipv6_cidr(s));
	});

	t.it('rejects v4, out-of-range prefix, missing slash, and non-strings', () => {
		for (let s in ["10.0.0.0/8", "::/129", "::/-1", "::1", "", null, 1234])
			t.assert_false(v.is_valid_ipv6_cidr(s));
	});
});

t.describe('values.is_valid_cidr_any', () => {
	t.it('accepts both v4 and v6 CIDR (stock mwan3 default_rule_v6 ships ::/0)', () => {
		t.assert_true(v.is_valid_cidr_any("10.0.0.0/8"));
		t.assert_true(v.is_valid_cidr_any("::/0"));
		t.assert_true(v.is_valid_cidr_any("2001:db8::/64"));
	});

	t.it('rejects bare addresses and garbage', () => {
		for (let s in ["10.0.0.0", "::1", "not-a-cidr", "", null])
			t.assert_false(v.is_valid_cidr_any(s));
	});
});

t.describe('values.ipv4_in_cidr', () => {
	t.it('returns true for addresses inside the range', () => {
		t.assert_true(v.ipv4_in_cidr("192.168.1.42", "192.168.1.0/24"));
		t.assert_true(v.ipv4_in_cidr("10.255.255.255", "10.0.0.0/8"));
		t.assert_true(v.ipv4_in_cidr("8.8.8.8", "0.0.0.0/0"));
		t.assert_true(v.ipv4_in_cidr("1.2.3.4", "1.2.3.4/32"));
	});

	t.it('returns false for addresses outside the range', () => {
		t.assert_false(v.ipv4_in_cidr("192.168.2.42", "192.168.1.0/24"));
		t.assert_false(v.ipv4_in_cidr("11.0.0.1", "10.0.0.0/8"));
	});

	t.it('returns false for malformed inputs', () => {
		t.assert_false(v.ipv4_in_cidr("not-an-ip", "192.168.1.0/24"));
		t.assert_false(v.ipv4_in_cidr("192.168.1.42", "not-a-cidr"));
		t.assert_false(v.ipv4_in_cidr(null, "192.168.1.0/24"));
	});
});

t.describe('values.ipv4_in_any_cidr', () => {
	t.it('matches when any one CIDR contains the address', () => {
		t.assert_true(v.ipv4_in_any_cidr("10.0.0.1",
			["192.168.1.0/24", "10.0.0.0/8"]));
		t.assert_false(v.ipv4_in_any_cidr("172.16.0.1",
			["192.168.1.0/24", "10.0.0.0/8"]));
	});

	t.it('strips IPv4-mapped IPv6 prefix before matching', () => {
		t.assert_true(v.ipv4_in_any_cidr("::ffff:192.168.1.10",
			["192.168.1.0/24"]));
	});

	t.it('returns false for non-array cidr list', () => {
		t.assert_false(v.ipv4_in_any_cidr("1.2.3.4", null));
		t.assert_false(v.ipv4_in_any_cidr("1.2.3.4", "1.2.3.4/32"));
	});
});

t.describe('values.constant_time_equals', () => {
	t.it('returns true for identical strings', () => {
		t.assert_true(v.constant_time_equals("abc", "abc"));
		t.assert_true(v.constant_time_equals("", ""));
		t.assert_true(v.constant_time_equals(
			"5f495b0384f3cfbd8ca838fc3721d7e0acd00ff7b54e5d9a583af2b4e322f1c8",
			"5f495b0384f3cfbd8ca838fc3721d7e0acd00ff7b54e5d9a583af2b4e322f1c8"));
	});

	t.it('returns false for strings of equal length differing in any byte', () => {
		t.assert_false(v.constant_time_equals("abc", "abd"));
		t.assert_false(v.constant_time_equals("abc", "Xbc"));
		// last-byte difference must be caught (sanity check that the loop runs)
		t.assert_false(v.constant_time_equals(
			"5f495b0384f3cfbd8ca838fc3721d7e0acd00ff7b54e5d9a583af2b4e322f1c8",
			"5f495b0384f3cfbd8ca838fc3721d7e0acd00ff7b54e5d9a583af2b4e322f1c9"));
	});

	t.it('returns false for different-length strings', () => {
		t.assert_false(v.constant_time_equals("abc", "abcd"));
		t.assert_false(v.constant_time_equals("abcd", "abc"));
		t.assert_false(v.constant_time_equals("", "a"));
	});

	t.it('returns false for non-string inputs', () => {
		t.assert_false(v.constant_time_equals(null, "abc"));
		t.assert_false(v.constant_time_equals("abc", null));
		t.assert_false(v.constant_time_equals(123, "123"));
	});
});

t.describe('values.masked_value_exceeds', () => {
	t.it('flags either component of a value/mask pair', () => {
		t.assert_true(v.masked_value_exceeds('4294967296', v.MARK_MAX));
		t.assert_true(v.masked_value_exceeds('0x1/4294967296', v.MARK_MAX));
		t.assert_false(v.masked_value_exceeds('0xffffffff/0x1', v.MARK_MAX));
	});

	t.it('ignores negation and non-numeric components', () => {
		t.assert_false(v.masked_value_exceeds('!0x1', v.MARK_MAX));
		t.assert_false(v.masked_value_exceeds('EF', 63));
		t.assert_true(v.masked_value_exceeds('64', 63));
	});

	t.it('returns false for absent or non-string input', () => {
		t.assert_false(v.masked_value_exceeds(null, v.MARK_MAX));
		t.assert_false(v.masked_value_exceeds('', v.MARK_MAX));
		t.assert_false(v.masked_value_exceeds(42, v.MARK_MAX));
	});
});

t.describe('values mark patterns', () => {
	// fw4 accepts decimal and 0x hex with an optional /mask; a bare hex digit
	// string such as "2a" passes fw4's own regex but fails its numeric
	// coercion, so the pattern must reject it up front.
	t.it('accepts the forms fw4 parses and rejects the rest', () => {
		for (let s in ['0x43', '67', '0x43/0xff', '1/2'])
			t.assert_true(match(s, regexp(v.MARK_RE)) != null);
		for (let s in ['2a', '', '!0x1', 'x'])
			t.assert_equal(match(s, regexp(v.MARK_RE)), null);
	});

	t.it('allows a leading negation only on the match variant', () => {
		t.assert_true(match('!0x1', regexp(v.MARK_MATCH_RE)) != null);
		t.assert_true(match('0x1', regexp(v.MARK_MATCH_RE)) != null);
	});
});

t.describe('values.port_problem', () => {
	// Mirrors fw4's parse_port: N or a min-max/min:max range, endpoints within
	// 0..65535 and ordered, negation allowed only on match options.
	t.it('accepts every form fw4 parses', () => {
		for (let s in ['80', '1000-2000', '1000:2000', '65535', '0'])
			t.assert_equal(v.port_problem(s, false), null);
		t.assert_equal(v.port_problem('!80', true), null);
	});

	t.it('rejects negation when the option forbids it', () => {
		t.assert_equal(v.port_problem('!80', false).code, "invalid_format");
	});

	t.it('rejects values fw4 would discard the section for', () => {
		t.assert_equal(v.port_problem('65536', true).code, "out_of_range");
		t.assert_equal(v.port_problem(sprintf("%d", v.PORT_MAX + 1), true).code, "out_of_range");
		t.assert_equal(v.port_problem('2000-1000', true).code, "out_of_range");
		t.assert_equal(v.port_problem('notaport', true).code, "invalid_format");
		t.assert_equal(v.port_problem('80,443', true).code, "invalid_format");
	});

	t.it('ignores absent and non-string input', () => {
		for (let s in [null, '', 42, [], {}])
			t.assert_equal(v.port_problem(s, true), null);
	});

	t.it('exposes patterns usable as schema constraints', () => {
		t.assert_true(match('1000:2000', regexp(v.PORT_RE)) != null);
		t.assert_equal(match('!80', regexp(v.PORT_RE)), null);
		t.assert_true(match('!80', regexp(v.PORT_MATCH_RE)) != null);
	});
});

t.describe('values.address_problem', () => {
	// fw4 types these as networks: a host, a prefix, a netmask, a range, or a
	// uci network name, any of them negatable.
	t.it('accepts every form fw4 resolves', () => {
		for (let s in ['192.168.1.1', '10.0.0.0/8', '192.168.1.0/255.255.255.0',
		               '2001:db8::1', '2001:db8::/32', '10.0.0.1-10.0.0.9',
		               '!10.0.0.1', 'lan', 'wan6'])
			t.assert_equal(v.address_problem(s), null);
	});

	t.it('rejects values fw4 cannot resolve', () => {
		for (let s in ['999.0.0.1', '10.0.0.256', 'not an ip', '10.0.0..1', '!', '10.0.0.1-'])
			t.assert_equal(v.address_problem(s).code, "invalid_format");
	});

	t.it('ignores absent and non-string input', () => {
		for (let s in [null, '', 42, []])
			t.assert_equal(v.address_problem(s), null);
	});
});
