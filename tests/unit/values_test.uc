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
