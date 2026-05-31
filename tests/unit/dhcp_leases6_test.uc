let t = require('harness');
let leases6 = loadfile('src/resources/dhcp.leases6.uc')();

t.describe('dhcp.leases6 contract', () => {
	t.it('declares package, type, id_field', () => {
		t.assert_equal(leases6.package, "dhcp");
		t.assert_equal(leases6.type, "lease6");
		t.assert_equal(leases6.id_field, "ip");
	});
});

t.describe('dhcp.leases6.parse_leases', () => {
	t.it('returns empty array for empty input', () => {
		t.assert_deep_equal(leases6.parse_leases(""), []);
		t.assert_deep_equal(leases6.parse_leases(null), []);
	});

	t.it('skips comment and blank lines', () => {
		let input = "# header line\n\n# another\n";
		t.assert_deep_equal(leases6.parse_leases(input), []);
	});

	t.it('parses a typical IA_NA line', () => {
		let input = "0001000123456789aa 0a0b0c0d laptop 1700000000 lan IA_NA 2001:db8::42\n";
		let r = leases6.parse_leases(input);
		t.assert_equal(length(r), 1);
		t.assert_equal(r[0].duid, "0001000123456789aa");
		t.assert_equal(r[0].iaid, "0a0b0c0d");
		t.assert_equal(r[0].hostname, "laptop");
		t.assert_equal(r[0].expires_at, 1700000000);
		t.assert_equal(r[0].interface, "lan");
		t.assert_equal(r[0].ia_type, "IA_NA");
		t.assert_equal(r[0].ip, "2001:db8::42");
		t.assert_equal(r[0].prefix_length, null);
	});

	t.it('parses an IA_PD line with /64 prefix', () => {
		let input = "0001000199 ff iotbox 1700001234 lan IA_PD 2001:db8:dead::/64\n";
		let r = leases6.parse_leases(input);
		t.assert_equal(length(r), 1);
		t.assert_equal(r[0].ia_type, "IA_PD");
		t.assert_equal(r[0].ip, "2001:db8:dead::");
		t.assert_equal(r[0].prefix_length, 64);
	});

	t.it('returns null hostname when the field is -', () => {
		let input = "00 ff - 1700000000 lan IA_NA 2001:db8::1\n";
		let r = leases6.parse_leases(input);
		t.assert_equal(r[0].hostname, null);
	});

	t.it('emits one entry per assigned address on multi-IP lines', () => {
		let input = "00 ff host 1700000000 lan IA_NA 2001:db8::1 2001:db8::2 2001:db8::3\n";
		let r = leases6.parse_leases(input);
		t.assert_equal(length(r), 3);
		t.assert_equal(r[0].ip, "2001:db8::1");
		t.assert_equal(r[1].ip, "2001:db8::2");
		t.assert_equal(r[2].ip, "2001:db8::3");
	});

	t.it('silently skips malformed (too short) lines', () => {
		let input = "incomplete line\n00 ff host 1700000000 lan IA_NA 2001:db8::1\n";
		let r = leases6.parse_leases(input);
		t.assert_equal(length(r), 1);
		t.assert_equal(r[0].ip, "2001:db8::1");
	});
});
