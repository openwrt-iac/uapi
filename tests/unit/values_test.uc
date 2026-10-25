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

// netifd takes only these four spellings and drops the option for anything else,
// so a value it ignores has to read back as the daemon's default rather than as
// what the operator wrote. normalize_bool is deliberately looser and stays that
// way for fw4 and the shell helpers, which do accept the wider set.
t.describe('values.platform_bool', () => {
	t.it('honours the spellings netifd accepts', () => {
		for (let s in [true, "1", "true"])
			t.assert_equal(v.platform_bool(s, false), true);
		for (let s in [false, "0", "false"])
			t.assert_equal(v.platform_bool(s, true), false);
	});

	// The divergence that made this helper necessary: `option auto 'no'` had uapi
	// reporting false while netifd dropped the option and autostarted anyway.
	t.it('returns the default for spellings netifd drops', () => {
		for (let s in ["on", "yes", "enabled"])
			t.assert_equal(v.platform_bool(s, false), false);
		for (let s in ["off", "no", "disabled"])
			t.assert_equal(v.platform_bool(s, true), true);
	});

	t.it('returns the default for null and for junk', () => {
		t.assert_equal(v.platform_bool(null, true), true);
		t.assert_equal(v.platform_bool("maybe", false), false);
		t.assert_equal(v.platform_bool(42, "x"), "x");
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

	// inet_pton reads an octet with base 0, so iptoarr returns null for every
	// zero-padded spelling (checked on the router). firewall4 then falls through
	// to a network-name lookup, resolves nothing and discards the section.
	t.it('rejects zero-padded octets, which inet_pton cannot parse', () => {
		for (let s in ["010.0.0.1", "08.0.0.1", "00.0.0.0", "1.2.3.04"])
			t.assert_false(v.is_valid_ipv4(s));
		t.assert_true(v.is_valid_ipv4("0.0.0.0"));
	});
});

t.describe('values.is_valid_ipv6', () => {
	// Checked against iptoarr on a real box: it parses the embedded-IPv4 form,
	// which the old character-class regex refused, and rejects ':::::', which
	// that regex accepted and which then discards the section on the router.
	t.it('accepts every form inet_pton parses', () => {
		for (let s in ['::1', '::', '2001:db8::1', 'fe80::1', '::ffff:192.168.1.1',
		               '2001:0db8:0000:0000:0000:0000:0000:0001', '1:2:3:4:5:6:7:8',
		               '1:2:3:4:5:6:7::', '::ffff:0:0'])
			t.assert_true(v.is_valid_ipv6(s));
	});

	t.it('rejects what inet_pton refuses', () => {
		for (let s in [':::::', ':', '12345::1', '1:2:3:4:5:6:7:8::', '::1::2',
		               '1:2:3:4:5:6:7:8:9', '1:2:3:4:5:6:7', 'fe80:',
		               '::ffff:010.0.0.1', '::ffff:999.0.0.1',
		               '2001:db8::1.2.3.4:5', 'abcd', '10.0.0.1', '', null, 42])
			t.assert_false(v.is_valid_ipv6(s));
	});
});

t.describe('values.has_noncontiguous_mask', () => {
	// fw4 renders a non-contiguous mask on a match address as
	// `saddr & <mask> == <addr>`, so it stays valid there, but discards the
	// section when one reaches an address it rewrites to.
	t.it('reports a mask whose set bits are not one leading run', () => {
		for (let s in ['10.0.0.0/255.0.255.0', '10.0.0.0/0.0.0.1',
		               '!10.0.0.0/255.255.0.255', '2001:db8::/ffff:0:ffff::'])
			t.assert_true(v.has_noncontiguous_mask(s));
	});

	t.it('passes a contiguous mask, a prefix length, and a bare address', () => {
		for (let s in ['10.0.0.0/255.255.0.0', '10.0.0.0/255.255.255.255',
		               '10.0.0.0/0.0.0.0', '10.0.0.0/8', '10.0.0.1', 'lan',
		               '2001:db8::/ffff:ffff::', '', null, 42])
			t.assert_false(v.has_noncontiguous_mask(s));
	});
});

t.describe('values.port_proto_conflict', () => {
	// fw4 assigns src_port/dest_port only inside `case "tcp": case "udp":`, so a
	// port beside anything else is dropped and the rule still emitted, matching
	// the whole protocol. Only `config nat` runs ensure_tcpudp, which rewrites a
	// lone wildcard to tcp+udp before the ports are read.
	t.it('passes protocols that keep their ports', () => {
		for (let p in [['tcp'], ['udp'], ['6'], ['17'], ['tcpudp'], ['TCP'], ['tcp', 'udp']]) {
			t.assert_false(v.port_proto_conflict(p, false));
			t.assert_false(v.port_proto_conflict(p, true));
		}
	});

	t.it('reports a protocol that silently loses its ports', () => {
		for (let p in [['gre'], ['icmp'], ['tcp', 'gre'], ['all', 'gre'], [null]]) {
			t.assert_true(v.port_proto_conflict(p, false));
			t.assert_true(v.port_proto_conflict(p, true));
		}
	});

	t.it('allows a lone wildcard only where ensure_tcpudp rewrites it', () => {
		for (let p in [['all'], ['any'], ['*']]) {
			t.assert_true(v.port_proto_conflict(p, false));
			t.assert_false(v.port_proto_conflict(p, true));
		}
	});

	// An absent proto is [], and fw4 supplies its own default, so there is
	// nothing to conflict with.
	t.it('passes an absent protocol list', () => {
		t.assert_false(v.port_proto_conflict([], false));
		t.assert_false(v.port_proto_conflict([], true));
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

	// int() stops at the first non-digit, so each of these read as a valid prefix, and
	// wg.uc ran the first one through a shell as root.
	t.it('rejects anything after the prefix length', () => {
		for (let s in ["::/0;id>x;", "2001:db8::/48 ; id ;", "::/64 foo", "::/0\n", "fe80::/64\r",
		               "2001:db8::/+48", "2001:db8::/ 48", "::/", "::/1234"])
			t.assert_false(v.is_valid_ipv6_cidr(s), s);
	});
});

// int() read `0x40`, `0.64` and `-0` as 0, so such an allowlist entry matched every IPv6 address.
t.describe('values.addr_in_any_cidr', () => {
	t.it('matches no caller against an IPv6 entry whose prefix length is not digits', () => {
		for (let c in [ "fd00::/0x40", "fd00::/0.64", "fd00::/-0", "fd00::/64x" ])
			t.assert_false(v.addr_in_any_cidr("2001:db8::1", [ c ]), c);
		t.assert_true(v.addr_in_any_cidr("fd00::5", [ "fd00::/64" ]));
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

t.describe('values.as_word_list_or_null', () => {
	t.it('splits a scalar on spaces and tabs, and keeps a list as it is', () => {
		t.assert_deep_equal(v.as_word_list_or_null('local \twan6'), [ 'local', 'wan6' ]);
		t.assert_deep_equal(v.as_word_list_or_null([ 'a b' ]), [ 'a b' ]);
	});
	t.it('returns null for nothing to split', () => {
		t.assert_equal(v.as_word_list_or_null(null), null);
		t.assert_equal(v.as_word_list_or_null('  '), null);
	});
});

t.describe('values.netifd_int', () => {
	t.it('reads hex, octal and decimal as strtol with base 0 does', () => {
		t.assert_equal(v.netifd_int('0x10'), 16);
		t.assert_equal(v.netifd_int('0X578'), 1400);
		t.assert_equal(v.netifd_int('010'), 8);
		t.assert_equal(v.netifd_int('16'), 16);
		t.assert_equal(v.netifd_int('0'), 0);
		t.assert_equal(v.netifd_int(' \t+7'), 7);
		t.assert_equal(v.netifd_int('-0x10'), -16);
		t.assert_equal(v.netifd_int('0x7fffffff'), 2147483647);
		t.assert_equal(v.netifd_int('-2147483648'), -2147483648);
	});
	t.it('reads null for what blob.c drops, and for "" and values past int32', () => {
		for (let s in [ '16 ', '08', '0x', '1e3', 'abc', '', '2147483648', '0xffffffff', '-2147483649' ])
			t.assert_equal(v.netifd_int(s), null, s);
		t.assert_equal(v.netifd_int(null), null);
		t.assert_equal(v.netifd_int([ '16' ]), null);
	});
});

t.describe('values.wg_int', () => {
	t.it('reads a decimal after stripping whitespace, as wg does, and null for anything else', () => {
		t.assert_equal(v.wg_int(' 25 '), 25);
		t.assert_equal(v.wg_int('25'), 25);
		t.assert_equal(v.wg_int('off'), null);
		t.assert_equal(v.wg_int('0;touch /tmp/x'), null);
		t.assert_equal(v.wg_int(''), null);
		t.assert_equal(v.wg_int(null), null);
	});
});

t.describe('values.service_port', () => {
	let file = (text) => () => text;
	let untouched = () => die("the reader ran for a value that needs no file");
	t.it('reads a decimal from 0 to 65535 after stripping whitespace, without the file', () => {
		t.assert_equal(v.service_port('51820', untouched), 51820);
		t.assert_equal(v.service_port(' 51820 ', untouched), 51820);
		t.assert_equal(v.service_port('+443', untouched), 443);
		t.assert_equal(v.service_port('0443', untouched), 443);
		t.assert_equal(v.service_port('65536', untouched), 0);
		t.assert_equal(v.service_port('-1', untouched), 0);
	});
	t.it('looks a name up on a /udp line of /etc/services, as any token of it', () => {
		let svc = file('# comment\nhttps\t443/tcp\nhttps\t443/udp\t# HTTP over TLS\nsyslog\t514/udp\tlogger\nwg 51820/udp #wg\n');
		t.assert_equal(v.service_port('https', svc), 443);
		t.assert_equal(v.service_port('logger', svc), 514);
		t.assert_equal(v.service_port('wg', svc), 51820);
		t.assert_equal(v.service_port('HTTP', svc), 0);
		t.assert_equal(v.service_port('nosuch', svc), 0);
		t.assert_equal(v.service_port('https', file(null)), 0);
	});
	t.it('reads the unresolved value it is given, for a listen port where 0 is valid', () => {
		let svc = file('openvpn\t1194/udp\n');
		for (let s in [ '65536', '-1', 'nosuch', '   ' ])
			t.assert_equal(v.service_port(s, svc, -1), -1, s);
		t.assert_equal(v.service_port('0', svc, -1), 0);
		t.assert_equal(v.service_port('openvpn', svc, -1), 1194);
		t.assert_equal(v.service_port('', svc, -1), null);
	});
	t.it('reads null for nothing set, and 0 for whitespace that wg cannot use', () => {
		t.assert_equal(v.service_port(null, untouched), null);
		t.assert_equal(v.service_port('', untouched), null);
		t.assert_equal(v.service_port('   ', untouched), 0);
	});
});

t.describe('values.rt_table_id', () => {
	let file = (text) => () => text;
	let untouched = () => die("the reader ran for a value that needs no file");
	t.it('reads numbers as strtoul with base 0 does, without the file', () => {
		t.assert_equal(v.rt_table_id('42', untouched), 42);
		t.assert_equal(v.rt_table_id('0x10', untouched), 16);
		t.assert_equal(v.rt_table_id('010', untouched), 8);
		t.assert_equal(v.rt_table_id(' +7', untouched), 7);
		t.assert_equal(v.rt_table_id('-1', untouched), 4294967295);
		t.assert_equal(v.rt_table_id('4294967295', untouched), 4294967295);
	});
	t.it('reads the three aliases without the file', () => {
		t.assert_equal(v.rt_table_id('default', untouched), 253);
		t.assert_equal(v.rt_table_id('main', untouched), 254);
		t.assert_equal(v.rt_table_id('local', untouched), 255);
	});
	t.it('looks other names up in rt_tables, first match winning', () => {
		let rt = file('# comment\n128\tprelocal\n0\tunspec\n4255 vpn\n#4256 off\n10abc odd\n4257 vpn\n');
		t.assert_equal(v.rt_table_id('vpn', rt), 4255);
		t.assert_equal(v.rt_table_id('prelocal', rt), 128);
		t.assert_equal(v.rt_table_id('odd', rt), 10);
		t.assert_equal(v.rt_table_id('off', rt), 0);
	});
	t.it('reads 0 for what netifd cannot resolve, and null when nothing is set', () => {
		let rt = file('0\tunspec\n');
		for (let s in [ '0', '08', '254 ', '', 'unspec', 'nosuch', '4294967296' ])
			t.assert_equal(v.rt_table_id(s, rt), 0, s);
		t.assert_equal(v.rt_table_id('vpn', file(null)), 0);
		t.assert_equal(v.rt_table_id(null, untouched), null);
		t.assert_equal(v.rt_table_id([ '42' ], untouched), null);
	});
});

t.describe('values.ipv6_words', () => {
	t.it('expands to eight 16-bit words', () => {
		t.assert_deep_equal(v.ipv6_words('::1'), [ 0, 0, 0, 0, 0, 0, 0, 1 ]);
		t.assert_deep_equal(v.ipv6_words('2001:db8::1'), [ 0x2001, 0xdb8, 0, 0, 0, 0, 0, 1 ]);
		t.assert_deep_equal(v.ipv6_words('0:0:0:0:1::'), [ 0, 0, 0, 0, 1, 0, 0, 0 ]);
	});
	t.it('returns null for anything that is not an IPv6 address', () => {
		t.assert_equal(v.ipv6_words('eui64'), null);
		t.assert_equal(v.ipv6_words('::1/64'), null);
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

t.describe('values.ipv6_in_cidr', () => {
	t.it('matches inside the prefix and not outside it', () => {
		t.assert_true(v.ipv6_in_cidr("2001:db8::1", "2001:db8::/32"));
		t.assert_true(v.ipv6_in_cidr("2001:db8:ffff:ffff::1", "2001:db8::/32"));
		t.assert_false(v.ipv6_in_cidr("2001:db9::1", "2001:db8::/32"));
	});

	// A prefix that ends mid-word is where a word-at-a-time comparison goes wrong.
	t.it('masks a prefix that does not land on a 16-bit boundary', () => {
		t.assert_true(v.ipv6_in_cidr("2001:db8:0:7f::1", "2001:db8:0:0::/49"));
		t.assert_false(v.ipv6_in_cidr("2001:db8:0:8000::1", "2001:db8:0:0::/49"));
		t.assert_true(v.ipv6_in_cidr("fd00::1", "fd00::/8"));
		t.assert_false(v.ipv6_in_cidr("fe00::1", "fd00::/8"));
	});

	t.it('handles the boundary prefixes', () => {
		t.assert_true(v.ipv6_in_cidr("2001:db8::1", "::/0"));
		t.assert_true(v.ipv6_in_cidr("2001:db8::1", "2001:db8::1/128"));
		t.assert_false(v.ipv6_in_cidr("2001:db8::2", "2001:db8::1/128"));
	});

	// `::` expands to a different number of zero words on each side, and an embedded IPv4
	// tail occupies the last two, so both forms have to reach the same eight words.
	t.it('expands the compressed and IPv4-tailed spellings alike', () => {
		t.assert_true(v.ipv6_in_cidr("::1", "::1/128"));
		t.assert_true(v.ipv6_in_cidr("2001:db8:0:0:0:0:0:1", "2001:db8::1/128"));
		t.assert_true(v.ipv6_in_cidr("::ffff:192.168.1.1", "::ffff:192.168.0.0/112"));
	});

	t.it('refuses a malformed address or prefix rather than matching it', () => {
		t.assert_false(v.ipv6_in_cidr("not-an-address", "2001:db8::/32"));
		t.assert_false(v.ipv6_in_cidr("2001:db8::1", "2001:db8::/129"));
		t.assert_false(v.ipv6_in_cidr("2001:db8::1", "10.0.0.0/8"));
		t.assert_false(v.ipv6_in_cidr("2001:db8::1", null));
	});
});

// The allowlist takes either family, and an entry of the other family must not match. Before
// this the matcher was IPv4-only, so a token carrying an allowlist rejected every IPv6 caller.
t.describe('values.addr_in_any_cidr across families', () => {
	t.it('matches a v6 caller against a v6 entry in a mixed list', () => {
		let list = [ "10.0.0.0/8", "2001:db8::/32" ];
		t.assert_true(v.addr_in_any_cidr("2001:db8::5", list));
		t.assert_true(v.addr_in_any_cidr("10.1.2.3", list));
		t.assert_false(v.addr_in_any_cidr("2001:dead::5", list));
		t.assert_false(v.addr_in_any_cidr("192.168.1.1", list));
	});

	t.it('does not let one family satisfy the other', () => {
		t.assert_false(v.addr_in_any_cidr("2001:db8::1", [ "0.0.0.0/0" ]));
		t.assert_false(v.addr_in_any_cidr("10.0.0.1", [ "::/0" ]));
	});
});

t.describe('values.addr_in_any_cidr', () => {
	t.it('matches when any one CIDR contains the address', () => {
		t.assert_true(v.addr_in_any_cidr("10.0.0.1",
			["192.168.1.0/24", "10.0.0.0/8"]));
		t.assert_false(v.addr_in_any_cidr("172.16.0.1",
			["192.168.1.0/24", "10.0.0.0/8"]));
	});

	t.it('strips IPv4-mapped IPv6 prefix before matching', () => {
		t.assert_true(v.addr_in_any_cidr("::ffff:192.168.1.10",
			["192.168.1.0/24"]));
	});

	t.it('returns false for non-array cidr list', () => {
		t.assert_false(v.addr_in_any_cidr("1.2.3.4", null));
		t.assert_false(v.addr_in_any_cidr("1.2.3.4", "1.2.3.4/32"));
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
		for (let s in [null, 42, [], {}])
			t.assert_equal(v.port_problem(s, true), null);
	});

	// An empty element in a port list is not the same as an absent option: it
	// reaches uci verbatim and fw4 discards the section over it.
	t.it('rejects an empty string rather than treating it as absent', () => {
		t.assert_equal(v.port_problem('', true).code, "invalid_format");
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
		for (let s in [null, 42, []])
			t.assert_equal(v.address_problem(s), null);
	});

	t.it('rejects an empty string rather than treating it as absent', () => {
		t.assert_equal(v.address_problem('').code, "invalid_format");
	});

	// Reachable only since is_valid_ipv6 started accepting the embedded-IPv4
	// form. ipv6_sort_key pads each group to four hex digits, so it has to
	// expand that tail first or the range comparison reads '.3.4' as the key.
	t.it('orders a range of embedded-IPv4 addresses', () => {
		t.assert_equal(v.address_problem('::ffff:1.2.3.4-::ffff:1.2.3.9'), null);
		t.assert_equal(v.address_problem('::ffff:1.2.3.9-::ffff:1.2.3.4').code, "out_of_range");
	});
});

t.describe('values.proto_problem', () => {
	// firewall4 renders the token verbatim as `meta l4proto <token>` and nft
	// resolves it against its own built-in table, which is narrower than
	// /etc/protocols. Since nft -f is atomic, one unresolvable token rejects the
	// entire ruleset, so these lists were checked against nft -c on a real box.
	t.it('accepts every token nft resolves', () => {
		for (let p in ['tcp', 'udp', 'tcpudp', 'icmp', 'ipv6-icmp', 'gre', 'sctp',
		               'dccp', 'udplite', 'ipip', 'ospf', 'pim', 'rsvp',
		               '0', '6', '255', '*', 'any', 'TCP', 'ipencap'])
			t.assert_equal(v.proto_problem(p), null);
	});

	t.it('rejects names present in /etc/protocols that nft cannot resolve', () => {
		for (let p in ['ipcomp', 'l2tp', 'vrrp'])
			t.assert_equal(v.proto_problem(p).code, "invalid_format");
	});

	t.it('bounds protocol numbers at 255', () => {
		t.assert_equal(v.proto_problem('256').code, "out_of_range");
		t.assert_equal(v.proto_problem('999').code, "out_of_range");
	});

	// fw4 parses a leading '!' then discards the invert flag when rendering, so a
	// negated protocol installs a rule matching exactly that protocol.
	t.it('rejects a negated protocol firewall4 cannot express', () => {
		t.assert_equal(v.proto_problem('!tcp').code, "invalid_format");
	});

	t.it('rejects unknown names and empty input', () => {
		t.assert_equal(v.proto_problem('banana').code, "invalid_format");
		t.assert_equal(v.proto_problem('').code, "invalid_format");
		t.assert_equal(v.proto_problem(null), null);
	});
});

t.describe('values.address_problem, fw4 parse ordering', () => {
	// fw4's parse_subnet splits on '/' before '-', so a mask cannot appear inside
	// a range, a range has exactly two endpoints, and both share a family.
	t.it('rejects malformed ranges fw4 returns null for', () => {
		for (let a in ['10.0.0.1-10.0.0.5/24', '10.0.0.1/24-10.0.0.5',
		               '1.1.1.1-2.2.2.2-3.3.3.3', '10.0.0.1-::1',
		               '10.0.0.1/::1', '-'])
			t.assert_equal(v.address_problem(a).code, "invalid_format");
	});

	t.it('still accepts a well-formed same-family range', () => {
		t.assert_equal(v.address_problem('10.0.0.1-10.0.0.9'), null);
		t.assert_equal(v.address_problem('2001:db8::1-2001:db8::9'), null);
	});
});

t.describe('values.proto_problem, numeric spelling', () => {
	// nft parses a protocol number with base 0. A leading zero therefore means
	// octal: 08 and 09 are unresolvable and fail the entire ruleset atomically,
	// while 017 loads as 15 and 077 as 63, silently matching another protocol.
	// Verified against nft -c and nft --debug=netlink on a real box.
	t.it('rejects leading-zero spellings nft reads as octal', () => {
		for (let p in ['08', '09', '019', '099'])
			t.assert_equal(v.proto_problem(p).code, "invalid_format");
		for (let p in ['017', '077', '010'])
			t.assert_equal(v.proto_problem(p).code, "invalid_format");
	});

	t.it('still accepts canonical decimal numbers', () => {
		for (let p in ['0', '6', '8', '17', '255'])
			t.assert_equal(v.proto_problem(p), null);
	});
});

t.describe('values nftables string and range limits', () => {
	// nft rejects a descending range with "Range negative size", caps a comment
	// at 128 bytes (fw4 prefixes every one with "!fw4: ") and an interface name
	// at 15. Each failure is atomic, taking the whole ruleset with it, so all
	// three were measured against nft -c on a real box.
	// Both families behave the same way in nft, so the ordering check cannot be
	// IPv4-only: a descending v6 range fails the load just as hard.
	t.it('rejects a descending address range in either family', () => {
		for (let a in ['10.0.0.9-10.0.0.1', '2001:db8::9-2001:db8::1',
		               'fe80::2-fe80::1', '2001:db8:1::1-2001:db8:0::1'])
			t.assert_equal(v.address_problem(a).code, "out_of_range");
		for (let a in ['10.0.0.1-10.0.0.9', '2001:db8::1-2001:db8::9', '::1-::9'])
			t.assert_equal(v.address_problem(a), null);
	});

	t.it('exposes the comment and interface-name ceilings', () => {
		t.assert_equal(v.NAME_MAX, 122);
		t.assert_equal(v.DEVICE_MAX, 15);
	});
});

t.describe('values.require_present', () => {
	// uci cannot store an empty option value, so "" is a field the daemon never sees.
	// Several resources spelled only the null half of that before this was shared.
	t.it('treats absent and empty as the same missing field', () => {
		for (let body in [ {}, { iface: null }, { iface: "" } ]) {
			let errs = [];
			t.assert_equal(v.require_present(errs, body, "iface"), false);
			t.assert_equal(length(errs), 1);
			t.assert_equal(errs[0].field, "iface");
			t.assert_equal(errs[0].code, "required");
			t.assert_equal(errs[0].message, "is required");
		}
	});

	t.it('pushes nothing and reports true when the field is set', () => {
		let errs = [];
		t.assert_equal(v.require_present(errs, { iface: "lan" }, "iface"), true);
		t.assert_equal(length(errs), 0);
	});

	// The return value is what lets a caller chain a format check that must not run on
	// an absent field, which is how network/routes and wireless/devices read.
	t.it('reports a nested wire name when the field sits under a prefix', () => {
		let errs = [];
		v.require_present(errs, { src_zone: "" }, "src_zone", "match.src_zone");
		t.assert_equal(errs[0].field, "match.src_zone");
	});
});

t.describe('values.section_index', () => {
	function stub(sections) {
		return { uci_foreach: function(pkg, sec_type, cb) {
			for (let s in sections) if (s['.type'] == sec_type) cb(s);
		} };
	}

	t.it('indexes by section name or by an option, whichever identifies it', () => {
		let c = stub([ { '.type': 'zone', '.name': 'cfg01', name: 'lan' },
		               { '.type': 'zone', '.name': 'cfg02', name: 'wan' } ]);
		let by_option = v.section_index(c, 'firewall', 'zone', 'name');
		t.assert_true(by_option.lan && by_option.wan);
		let by_name = v.section_index(c, 'firewall', 'zone', '.name');
		t.assert_true(by_name.cfg01 && by_name.cfg02);
	});

	t.it('applies the filter, so a second option can be required to match', () => {
		let c = stub([ { '.type': 'interface', '.name': 'wg0', proto: 'wireguard' },
		               { '.type': 'interface', '.name': 'lan', proto: 'static' } ]);
		let wg = v.section_index(c, 'network', 'interface', '.name',
		                         function(s) { return s.proto == "wireguard"; });
		t.assert_true(wg.wg0);
		t.assert_equal(wg.lan, null);
	});

	t.it('skips a blank key and tolerates a null conn', () => {
		let c = stub([ { '.type': 'zone', name: '' }, { '.type': 'zone', name: 'lan' } ]);
		let idx = v.section_index(c, 'firewall', 'zone', 'name');
		t.assert_equal(length(keys(idx)), 1);
		t.assert_deep_equal(v.section_index(null, 'firewall', 'zone', 'name'), {});
	});
});

t.describe('values.dnsmasq_value_problem', () => {
	t.it('passes values dnsmasq reads as plain text', () => {
		for (let s in ['ipxe', '!known', 'x y', 'my_tag.1', 'x:y'])
			t.assert_equal(v.dnsmasq_value_problem(s), null, s);
	});

	t.it('flags every character dnsmasq reads as syntax, and blank values', () => {
		for (let s in ['a,b', 'x"y', 'x #y', 'tag#x', 'a\nb', 'a\tb', '', '  '])
			t.assert_true(v.dnsmasq_value_problem(s) != null, s);
	});
});

t.describe('values.unstorable_text_path', () => {
	t.it('names the first key or string that holds a control byte uci drops', () => {
		t.assert_equal(v.unstorable_text_path({ a: "x", b: "y\u0001z" }), "b");
		t.assert_equal(v.unstorable_text_path({ "k\u0002": "x" }), "k\u0002");
		t.assert_equal(v.unstorable_text_path({ l: [ "a", "b\u0008" ] }), "l[1]");
		t.assert_equal(v.unstorable_text_path({ o: { p: [ { q: "\u000b" } ] } }), "o.p[0].q");
		t.assert_equal(v.unstorable_text_path({ c: "\u001f" }), "c");
		t.assert_equal(v.unstorable_text_path([ "ok", "\u000c" ]), "body[1]");
		t.assert_equal(v.unstorable_text_path("\u000e"), "body");
	});

	t.it('passes tab, newline, carriage return, DEL and non-strings, which uci keeps', () => {
		t.assert_equal(v.unstorable_text_path({ a: "x\ty\nz\r", b: "\u007f", n: 5, f: false, z: null, e: [] }), null);
		t.assert_equal(v.unstorable_text_path(null), null);
	});
});

t.describe('values.json_has_nul', () => {
	// json() parses {"k\u0000x": 1} as {"k": 1}, so a key's NUL shows only in the text.
	t.it('finds the NUL escape in a key or a value', () => {
		t.assert_true(v.json_has_nul('{"k\\u0000x": 1}'));
		t.assert_true(v.json_has_nul('{"a": "\\u0000"}'));
		t.assert_true(v.json_has_nul('{"a": "x\\\\\\u0000"}'));
	});

	t.it('ignores an escaped backslash that a plain u0000 follows', () => {
		t.assert_false(v.json_has_nul('{"a": "x\\\\u0000"}'));
		t.assert_false(v.json_has_nul('{"a": "\\u0001"}'));
	});
});
