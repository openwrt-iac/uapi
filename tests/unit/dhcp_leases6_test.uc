let t = require('harness');
let bus = require('bus');
let handler = require('handler');
let leases = loadfile('src/resources/dhcp.leases.uc')();

// v4 (#320): dhcp/leases6 merged into dhcp/leases with ?family=v6.
t.describe('dhcp.leases merged endpoint (#320)', () => {
	function ctx() { return { request_id: "01hx0000000000000000000000" }; }

	t.it('id_field is mac for v4 and ip for v6', () => {
		t.assert_equal(leases.id_field({}), "mac");
		t.assert_equal(leases.id_field(null), "mac");
		t.assert_equal(leases.id_field({ family: "v6" }), "ip");
	});

	t.it('get_one with family=v6 finds an entry by ip', () => {
		let h = handler.make_collection({
			package: "dhcp", type: "lease",
			id_field: (q) => (q != null && q.family == "v6") ? "ip" : "mac",
			list_fn: function(conn, query) {
				return (query != null && query.family == "v6")
					? [ { ip: "2001:db8::1", duid: "aa" } ] : [ { mac: "aa:bb", ip: "192.0.2.1" } ];
			},
		});
		let c = bus.stub();
		let r = h.get_one(c, ctx(), "2001:db8::1", { family: "v6" });
		t.assert_equal(r.status, 200);
		t.assert_equal(r.body.ip, "2001:db8::1");
		t.assert_equal(h.get_one(c, ctx(), "aa:bb", {}).status, 200);
		t.assert_equal(h.get_one(c, ctx(), "2001:db8::1", {}).status, 404);
	});
});

t.describe('dhcp.leases parse_leases6', () => {
	t.it('returns empty array for empty input', () => {
		t.assert_deep_equal(leases.parse_leases6(""), []);
		t.assert_deep_equal(leases.parse_leases6(null), []);
	});

	t.it('skips comment and blank lines', () => {
		let input = "# header line\n\n# another\n";
		t.assert_deep_equal(leases.parse_leases6(input), []);
	});

	t.it('parses a typical IA_NA line', () => {
		let input = "0001000123456789aa 0a0b0c0d laptop 1700000000 lan IA_NA 2001:db8::42\n";
		let r = leases.parse_leases6(input);
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
		let r = leases.parse_leases6(input);
		t.assert_equal(length(r), 1);
		t.assert_equal(r[0].ia_type, "IA_PD");
		t.assert_equal(r[0].ip, "2001:db8:dead::");
		t.assert_equal(r[0].prefix_length, 64);
	});

	t.it('returns null hostname when the field is -', () => {
		let input = "00 ff - 1700000000 lan IA_NA 2001:db8::1\n";
		let r = leases.parse_leases6(input);
		t.assert_equal(r[0].hostname, null);
	});

	t.it('emits one entry per assigned address on multi-IP lines', () => {
		let input = "00 ff host 1700000000 lan IA_NA 2001:db8::1 2001:db8::2 2001:db8::3\n";
		let r = leases.parse_leases6(input);
		t.assert_equal(length(r), 3);
		t.assert_equal(r[0].ip, "2001:db8::1");
		t.assert_equal(r[1].ip, "2001:db8::2");
		t.assert_equal(r[2].ip, "2001:db8::3");
	});

	t.it('silently skips malformed (too short) lines', () => {
		let input = "incomplete line\n00 ff host 1700000000 lan IA_NA 2001:db8::1\n";
		let r = leases.parse_leases6(input);
		t.assert_equal(length(r), 1);
		t.assert_equal(r[0].ip, "2001:db8::1");
	});
});
