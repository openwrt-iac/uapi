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
